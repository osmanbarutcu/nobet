import Foundation
import UserNotifications

extension AlertIssue {
    /// Bildirim kimliği. `NotificationRoute` bu kimlikten sayfayı bulur.
    var routeIdentifier: String {
        switch module {
        case "secrets": return "nobet.secret"
        case "net": return "nobet.net"
        case "dev", "sbom": return "nobet.dev"
        default: return "nobet.server"
        }
    }
}

extension AlertEvent {
    var notificationTitle: String {
        switch kind {
        case .started: return issue.title
        case .resolved: return "\(issue.title) düzeldi"
        }
    }

    /// Yalnızca konu adı. Yol, anahtar veya sunucu çıktısı taşımaz.
    var notificationBody: String { issue.subject }
}

/// Kararlı kısa özet (FNV-1a). Yol gibi uzun veya özel metni anahtara koymadan kimliğe çevirir.
enum AlertKey {
    static func digest(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
        return String(hash, radix: 16)
    }
}

protocol AlertNotifying {
    func notify(_ event: AlertEvent)
    func notifySummary(title: String, body: String)
}

extension AlertNotifying {
    func notifySummary(title: String, body: String) {}
}

/// Gerçek sistem bildirimi. Birim testlerde kullanılmaz.
struct SystemAlertNotifier: AlertNotifying {
    func requestAuthorization() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(_ event: AlertEvent) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = event.notificationTitle
        content.body = event.notificationBody
        let mode = AlertSoundMode(stored: UserDefaults.standard.string(forKey: AlertSoundMode.storageKey))
        if mode.plays(event.issue.severity) { content.sound = .default }
        content.userInfo = NotificationAction.userInfo(for: event)
        if let category = NotificationAction.category(for: event) { content.categoryIdentifier = category }
        // Aynı modülün bildirimi öncekinin yerine geçer. Kimlik tıklama yönlendirmesini de belirler.
        let request = UNNotificationRequest(identifier: event.issue.routeIdentifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

/// Bildirimdeki "1 saat ertele" düğmesi.
enum NotificationAction {
    static let categoryId = "nobet.issue"
    static let snoozeId = "nobet.snooze1h"
    static let keyField = "alertKey"
    static let snoozeSeconds: TimeInterval = 3600

    static func category(for event: AlertEvent) -> String? { event.kind == .started ? categoryId : nil }

    static func userInfo(for event: AlertEvent) -> [AnyHashable: Any] { [keyField: event.issue.key] }

    static func snoozeKey(action: String, userInfo: [AnyHashable: Any]) -> String? {
        action == snoozeId ? userInfo[keyField] as? String : nil
    }

    /// Sistemin bildirim kategorisi. Uygulama açılışında bir kez kaydedilir.
    static func register() {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let snooze = UNNotificationAction(identifier: snoozeId, title: "1 saat ertele", options: [])
        let category = UNNotificationCategory(identifier: categoryId, actions: [snooze], intentIdentifiers: [], options: [])
        UNUserNotificationCenter.current().setNotificationCategories([category])
    }
}

extension SystemAlertNotifier {
    func notifySummary(title: String, body: String) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: "nobet.summary", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

/// Haftalık özet. Pazartesi 09:00 sonrası bir kez gönderilir.
enum WeeklySummary {
    /// `now` anından önceki en yakın pazartesi 09:00.
    static func latestSlot(now: Date, calendar: Calendar) -> Date {
        let match = DateComponents(hour: 9, minute: 0, weekday: 2)
        return calendar.nextDate(after: now.addingTimeInterval(1), matching: match, matchingPolicy: .nextTime, direction: .backward) ?? now
    }

    static func counts(_ events: [AlertEvent], now: Date) -> (started: Int, resolved: Int) {
        let recent = events.filter { $0.date > now.addingTimeInterval(-7 * 86_400) && $0.date <= now }
        return (recent.filter { $0.kind == .started }.count, recent.filter { $0.kind == .resolved }.count)
    }

    static func body(started: Int, resolved: Int, open: Int) -> String {
        "Son 7 gün: \(started) sorun başladı, \(resolved) sorun düzeldi. Şu an açık: \(open)."
    }
}

/// Modüllerin sorunlarını toplar, farkı bulur, geçmişe yazar ve ayara göre bildirir.
@MainActor
final class AlertCenter: ObservableObject {
    static let notifyKey = "alerts.notify"
    static let quietEnabledKey = "alerts.quiet.enabled"
    static let quietStartKey = "alerts.quiet.start"
    static let quietEndKey = "alerts.quiet.end"
    static let activeKey = "alerts.active"
    static let historyKey = "alerts.history"
    /// Yalnızca `[anahtar: bitiş epoch]`. Başlık ve konu adı diske yazılmaz.
    static let snoozeKey = "alerts.snoozed"
    static let notesKey = "alerts.notes"
    static let noteLimit = 200
    static let weekendCustomKey = "alerts.quiet.weekend.custom"
    static let weekendStartKey = "alerts.quiet.weekend.start"
    static let weekendEndKey = "alerts.quiet.weekend.end"
    static let soundKey = AlertSoundMode.storageKey
    static let weeklyKey = "alerts.weekly"
    static let weeklyLastKey = "alerts.weekly.last"

    static let shared: AlertCenter = {
        DemoMode.prepare()
        return AlertCenter(notifier: DemoMode.notifier, nobet: .shared)
    }()

    @Published private(set) var active: [AlertIssue]
    @Published private(set) var history: [AlertEvent]
    @Published private(set) var snoozes: [String: Date]
    @Published private(set) var notes: [String: String]

    private let defaults: UserDefaults
    private let notifier: AlertNotifying
    private let now: () -> Date
    private let calendar: Calendar
    private let nobet: NobetModel?

    init(defaults: UserDefaults = .standard, notifier: AlertNotifying, now: @escaping () -> Date = Date.init,
         calendar: Calendar = .current, nobet: NobetModel? = nil) {
        self.defaults = defaults
        self.nobet = nobet
        self.notifier = notifier
        self.now = now
        self.calendar = calendar
        self.active = Self.load([AlertIssue].self, key: Self.activeKey, defaults: defaults) ?? []
        self.history = Self.load([AlertEvent].self, key: Self.historyKey, defaults: defaults) ?? []
        let stored = Self.load([String: Date].self, key: Self.snoozeKey, defaults: defaults) ?? [:]
        let current = now()
        self.snoozes = stored.filter { $0.value > current }
        self.notes = Self.load([String: String].self, key: Self.notesKey, defaults: defaults) ?? [:]
    }

    var notificationsEnabled: Bool { defaults.object(forKey: Self.notifyKey) as? Bool ?? true }
    var weeklyEnabled: Bool { defaults.object(forKey: Self.weeklyKey) as? Bool ?? true }
    var quietEnabled: Bool { defaults.object(forKey: Self.quietEnabledKey) as? Bool ?? true }

    var quietHours: QuietHours {
        QuietHours(startMinute: defaults.object(forKey: Self.quietStartKey) as? Int ?? 23 * 60,
                   endMinute: defaults.object(forKey: Self.quietEndKey) as? Int ?? 8 * 60)
    }

    func activeCount(module: String) -> Int { active.filter { $0.module == module }.count }

    func note(for key: String) -> String? { notes[key] }

    /// Kullanıcının kendi notu. Etkin sorun dışına not verilmez. Boş not siler.
    func setNote(_ text: String, for key: String) {
        guard active.contains(where: { $0.key == key }) else { return }
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.noteLimit))
        var next = notes
        next[key] = trimmed.isEmpty ? nil : trimmed
        notes = next
        persistNotes()
    }

    private func persistNotes() {
        if let data = try? JSONEncoder().encode(notes) { defaults.set(data, forKey: Self.notesKey) }
    }

    func isSnoozed(_ key: String) -> Bool { snoozes[key].map { $0 > now() } ?? false }

    /// Kalan süre saniye olarak. Ertelenmemişse `nil`.
    func snoozeRemaining(key: String) -> TimeInterval? {
        guard let until = snoozes[key], until > now() else { return nil }
        return until.timeIntervalSince(now())
    }

    /// Ertelenmemiş etkin sorunlar.
    var visibleActive: [AlertIssue] { active.filter { !isSnoozed($0.key) } }

    /// Ertelenmemiş sorunların en yüksek önemi. Sorun yoksa `nil`.
    var worstVisibleSeverity: Severity? { visibleActive.map(\.severity).max() }

    func visibleCount(module: String) -> Int { visibleActive.filter { $0.module == module }.count }

    /// Etkin bir sorunu erteler. Bilinmeyen anahtar ve süresi sıfır veya negatif olan istek yok sayılır.
    func snooze(key: String, for seconds: TimeInterval) {
        guard seconds > 0, let issue = active.first(where: { $0.key == key }) else { return }
        snoozes = snoozes.merging([key: now().addingTimeInterval(seconds)]) { _, new in new }
        persistSnoozes()
        publishCount(module: issue.module)
    }

    func unsnooze(key: String) {
        guard snoozes[key] != nil else { return }
        let module = active.first(where: { $0.key == key })?.module
        snoozes = snoozes.filter { $0.key != key }
        persistSnoozes()
        if let module { publishCount(module: module) }
    }

    private func publishCount(module: String) {
        nobet?.setAlerts(visibleCount(module: module), for: module)
    }

    private func persistSnoozes() {
        if let data = try? JSONEncoder().encode(snoozes) { defaults.set(data, forKey: Self.snoozeKey) }
    }

    /// Bir modülün güncel sorun listesini işler. Yalnızca fark bildirilir.
    func ingest(module: String, issues: [AlertIssue]) {
        let previous = active.filter { $0.module == module }
        let result = AlertEngine.diff(previous: previous, current: issues)
        let resolvedKeys = Set(result.resolved.map(\.key))
        // Süren sorun en güncel metinle saklanır. Konu biçimi sürümler arasında değişebilir.
        let latest = Dictionary(issues.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let kept = previous.filter { !resolvedKeys.contains($0.key) }.map { latest[$0.key] ?? $0 }
        let nextModule = kept + result.started
        active = active.filter { $0.module != module } + nextModule

        let date = now()
        let events = result.started.map { AlertEvent(kind: .started, issue: $0, date: date) }
            + result.resolved.map { AlertEvent(kind: .resolved, issue: $0, date: date) }
        // Çözülen sorunun ertelemesi biter. Sorun geri gelirse yeniden bildirilir.
        let silenced = Set(snoozes.filter { $0.value > date }.keys)
        let before = snoozes.count
        snoozes = snoozes.filter { $0.value > date && !resolvedKeys.contains($0.key) }
        if snoozes.count != before { persistSnoozes() }
        let beforeNotes = notes.count
        notes = notes.filter { !resolvedKeys.contains($0.key) }
        if notes.count != beforeNotes { persistNotes() }
        publishCount(module: module)
        sendWeeklySummaryIfDue()
        guard !events.isEmpty else { return }
        history = AlertHistory.appending(events, to: history)
        persist()
        guard shouldNotify(at: date) else { return }
        events.filter { !silenced.contains($0.issue.key) }.forEach(notifier.notify)
    }

    /// Pazartesi 09:00 çizgisi geçildiyse özeti bir kez gönderir. İlk çağrı yalnızca sayımı başlatır.
    func sendWeeklySummaryIfDue() {
        guard weeklyEnabled else { return }
        let date = now()
        guard defaults.object(forKey: Self.weeklyLastKey) != nil else {
            defaults.set(date.timeIntervalSince1970, forKey: Self.weeklyLastKey)
            return
        }
        let last = Date(timeIntervalSince1970: defaults.double(forKey: Self.weeklyLastKey))
        guard last < WeeklySummary.latestSlot(now: date, calendar: calendar) else { return }
        defaults.set(date.timeIntervalSince1970, forKey: Self.weeklyLastKey)
        guard shouldNotify(at: date) else { return }
        let counts = WeeklySummary.counts(history, now: date)
        notifier.notifySummary(title: "Nöbet haftalık özet", body: WeeklySummary.body(started: counts.started, resolved: counts.resolved, open: visibleActive.count))
    }

    private func shouldNotify(at date: Date) -> Bool {
        guard notificationsEnabled else { return false }
        return !isQuiet(at: date)
    }

    /// Cumartesi ve pazar için ayrı pencere seçildiyse o kullanılır.
    func isQuiet(at date: Date) -> Bool {
        guard quietEnabled else { return false }
        let weekend = calendar.isDateInWeekend(date)
        guard weekend, defaults.bool(forKey: Self.weekendCustomKey) else { return quietHours.contains(date, calendar: calendar) }
        let hours = QuietHours(startMinute: defaults.object(forKey: Self.weekendStartKey) as? Int ?? 0,
                               endMinute: defaults.object(forKey: Self.weekendEndKey) as? Int ?? 10 * 60)
        return hours.contains(date, calendar: calendar)
    }

    private func persist() {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(active) { defaults.set(data, forKey: Self.activeKey) }
        if let data = try? encoder.encode(history) { defaults.set(data, forKey: Self.historyKey) }
    }

    private static func load<T: Decodable>(_ type: T.Type, key: String, defaults: UserDefaults) -> T? {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(type, from: $0) }
    }
}

/// Erteleme seçenekleri ve kalan süre metni.
enum SnoozeChoice: CaseIterable {
    case hour, day, week

    var seconds: TimeInterval {
        switch self {
        case .hour: return 3600
        case .day: return 86_400
        case .week: return 604_800
        }
    }

    var title: String {
        switch self {
        case .hour: return "1 saat"
        case .day: return "1 gün"
        case .week: return "7 gün"
        }
    }

    static func remainingText(seconds: TimeInterval) -> String {
        if seconds >= 86_400 { return "\(Int(seconds / 86_400)) gün kaldı" }
        if seconds >= 3600 { return "\(Int(seconds / 3600)) sa kaldı" }
        return "\(max(1, Int(seconds / 60))) dk kaldı"
    }
}

/// Hangi önemde bildirim sesi çalar.
enum AlertSoundMode: String, CaseIterable {
    case all, highOnly, off

    static let storageKey = "alerts.sound"

    init(stored: String?) { self = stored.flatMap(Self.init(rawValue:)) ?? .highOnly }

    var title: String {
        switch self {
        case .all: return "Tüm sorunlarda"
        case .highOnly: return "Yalnızca yüksek önemde"
        case .off: return "Kapalı"
        }
    }

    func plays(_ severity: Severity) -> Bool {
        switch self {
        case .all: return true
        case .highOnly: return severity == .high
        case .off: return false
        }
    }
}
