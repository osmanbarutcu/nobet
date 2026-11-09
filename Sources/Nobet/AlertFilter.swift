import Foundation

enum ModuleNames {
    static let order = ["dev", "servers", "remote", "secrets", "net", "sbom"]
    private static let titles = ["dev": "Geliştirme", "servers": "Web siteleri", "remote": "SSH sunucuları", "secrets": "Sırlar",
                                 "net": "Ağ", "sbom": "Bağımlılıklar"]

    static func title(_ key: String) -> String { titles[key] ?? key }

    static func symbol(_ key: String) -> String {
        switch key {
        case "dev": return "hammer"
        case "servers": return "globe"
        case "remote": return "server.rack"
        case "secrets": return "key.viewfinder"
        case "net": return "network"
        case "sbom": return "shippingbox"
        default: return "questionmark.circle"
        }
    }

    /// Modülün ayrıntı sayfası. Bilinmeyen modül Genel'de kalır.
    static func section(_ key: String) -> NobetSection {
        switch key {
        case "dev", "sbom": return .development
        case "servers", "remote": return .servers
        case "secrets": return .secrets
        case "net": return .network
        default: return .general
        }
    }
}

enum AlertStatus: String, Codable, CaseIterable {
    case all, open, snoozed, resolved

    var title: String {
        switch self {
        case .all: return "Tümü"
        case .open: return "Açık"
        case .snoozed: return "Ertelenmiş"
        case .resolved: return "Çözülmüş"
        }
    }
}

enum AlertRange: String, Codable, CaseIterable {
    case all, hour, day, week, custom

    var title: String {
        switch self {
        case .all: return "Tümü"
        case .hour: return "Son 1 saat"
        case .day: return "Son 24 saat"
        case .week: return "Son 7 gün"
        case .custom: return "Özel"
        }
    }

    var seconds: TimeInterval? {
        switch self {
        case .hour: return 3600
        case .day: return 86_400
        case .week: return 604_800
        case .all, .custom: return nil
        }
    }
}

struct FilterChip: Equatable, Identifiable {
    enum Dimension { case severity, module, text, status, range }

    let dimension: Dimension
    let title: String
    var id: String { title }
}

/// Sorun ve olay listeleri için ortak süzgeç. Boş küme "hepsi" demektir.
struct AlertFilter: Equatable, Codable {
    var severities: Set<Severity> = []
    var modules: Set<String> = []
    var text = ""
    var status = AlertStatus.all
    var range = AlertRange.all
    var from = Date.distantPast
    var to = Date.distantFuture

    private var query: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var isActive: Bool {
        !severities.isEmpty || !modules.isEmpty || !query.isEmpty || status != .all || range != .all
    }

    /// Küçük harf, aksan ve Türkçe noktasız ı farkını siler.
    static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US"))
            .replacingOccurrences(of: "ı", with: "i")
    }

    private func matchesCommon(_ issue: AlertIssue) -> Bool {
        if !severities.isEmpty, !severities.contains(issue.severity) { return false }
        if !modules.isEmpty, !modules.contains(issue.module) { return false }
        let needle = Self.fold(query)
        guard !needle.isEmpty else { return true }
        return Self.fold(issue.title).contains(needle) || Self.fold(issue.subject).contains(needle)
    }

    func matches(issue: AlertIssue, snoozed: Bool) -> Bool {
        guard matchesCommon(issue) else { return false }
        switch status {
        case .all: return true
        case .open: return !snoozed
        case .snoozed: return snoozed
        case .resolved: return false
        }
    }

    func matches(event: AlertEvent, snoozed: Bool, now: Date) -> Bool {
        guard matchesCommon(event.issue) else { return false }
        switch status {
        case .all: break
        case .open: if event.kind != .started { return false }
        case .resolved: if event.kind != .resolved { return false }
        case .snoozed: if !snoozed { return false }
        }
        switch range {
        case .all: return true
        case .custom: return event.date >= from && event.date <= to
        default: return event.date > now.addingTimeInterval(-(range.seconds ?? 0)) && event.date <= now
        }
    }

    var chips: [FilterChip] {
        var result: [FilterChip] = []
        if !severities.isEmpty {
            let names = severities.sorted(by: >).map(\.label).joined(separator: ", ")
            result.append(FilterChip(dimension: .severity, title: "Önem: \(names)"))
        }
        if !modules.isEmpty {
            let names = modules.sorted().map(ModuleNames.title).joined(separator: ", ")
            result.append(FilterChip(dimension: .module, title: "Modül: \(names)"))
        }
        if !query.isEmpty { result.append(FilterChip(dimension: .text, title: "Ara: \(query)")) }
        if status != .all { result.append(FilterChip(dimension: .status, title: "Durum: \(status.title)")) }
        if range != .all { result.append(FilterChip(dimension: .range, title: "Süre: \(range.title)")) }
        return result
    }

    func removing(_ dimension: FilterChip.Dimension) -> AlertFilter {
        var next = self
        switch dimension {
        case .severity: next.severities = []
        case .module: next.modules = []
        case .text: next.text = ""
        case .status: next.status = .all
        case .range: next.range = .all
        }
        return next
    }

    func cleared() -> AlertFilter { AlertFilter() }
}

protocol AlertSortable {
    var sortSeverity: Severity { get }
    var sortDate: Date { get }
    var sortTitle: String { get }
}

extension AlertIssue: AlertSortable {
    var sortSeverity: Severity { severity }
    var sortDate: Date { .distantPast }
    var sortTitle: String { title }
}

extension AlertEvent: AlertSortable {
    var sortSeverity: Severity { issue.severity }
    var sortDate: Date { date }
    var sortTitle: String { issue.title }
}

enum AlertSort: String, CaseIterable {
    case severity, date, title

    var title: String {
        switch self {
        case .severity: return "Önem"
        case .date: return "Tarih"
        case .title: return "Ad"
        }
    }

    private static func inOrder(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [], range: nil, locale: Locale(identifier: "tr_TR")) == .orderedAscending
    }

    func sorted<T: AlertSortable>(_ items: [T]) -> [T] {
        items.sorted { lhs, rhs in
            switch self {
            case .severity:
                if lhs.sortSeverity != rhs.sortSeverity { return lhs.sortSeverity > rhs.sortSeverity }
                return Self.inOrder(lhs.sortTitle, rhs.sortTitle)
            case .date:
                return lhs.sortDate > rhs.sortDate
            case .title:
                return Self.inOrder(lhs.sortTitle, rhs.sortTitle)
            }
        }
    }
}

enum PageSize: Int, CaseIterable {
    case ten = 10, twenty = 20, fifty = 50, all = 0

    var title: String { self == .all ? "Tümü" : String(rawValue) }

    func pageCount(for total: Int) -> Int {
        guard self != .all, total > 0 else { return 1 }
        return (total + rawValue - 1) / rawValue
    }

    /// Sayfa numarası sıfırdan başlar. Sınır dışı numara son sayfaya iner.
    func slice<T>(_ items: [T], page: Int) -> [T] {
        guard self != .all else { return items }
        let index = min(max(0, page), pageCount(for: items.count) - 1)
        let start = index * rawValue
        return Array(items[start..<min(items.count, start + rawValue)])
    }
}

/// Adlandırılmış süzgeçler. Yalnızca süzgeç ayarı saklanır, sorun verisi saklanmaz.
struct SavedFilters {
    static let key = "alerts.savedFilters"
    static let limit = 10

    struct Entry: Codable, Equatable {
        let name: String
        let filter: AlertFilter
    }

    let defaults: UserDefaults
    let key: String

    /// Her liste kendi anahtarını kullanır. Sorun ve olay süzgeçleri birbirine karışmaz.
    init(defaults: UserDefaults = .standard, key: String = SavedFilters.key) {
        self.defaults = defaults
        self.key = key
    }

    var all: [Entry] {
        defaults.data(forKey: key).flatMap { try? JSONDecoder().decode([Entry].self, from: $0) } ?? []
    }

    /// Aynı ad eskisini değiştirir. Boş ad, etkin olmayan süzgeç ve onuncu kayıttan sonraki yeni ad reddedilir.
    func save(name: String, filter: AlertFilter) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, filter.isActive else { return }
        var entries = all
        if let index = entries.firstIndex(where: { $0.name == trimmed }) {
            entries[index] = Entry(name: trimmed, filter: filter)
        } else if entries.count < Self.limit {
            entries.append(Entry(name: trimmed, filter: filter))
        } else {
            return
        }
        write(entries)
    }

    func delete(name: String) { write(all.filter { $0.name != name }) }

    private func write(_ entries: [Entry]) {
        if let data = try? JSONEncoder().encode(entries) { defaults.set(data, forKey: key) }
    }
}

/// Tek sunucunun olay zaman çizelgesi. Modül ve konu adı eşleşen olayları yeniden eskiye sıralar.
enum ServerTimeline {
    static func events(_ history: [AlertEvent], module: String, subject: String, limit: Int = 5) -> [AlertEvent] {
        let matching = history.filter { $0.issue.module == module && $0.issue.subject == subject }
        return Array(matching.sorted { $0.date > $1.date }.prefix(max(0, limit)))
    }
}

/// Olay listesini gün başlıklarına böler. Yalnızca ardışık aynı gün satırları birleşir, sıra bozulmaz.
enum DayGrouping {
    struct Group: Equatable {
        let title: String
        let events: [AlertEvent]
    }

    static func title(for date: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Bugün" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) { return "Dün" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "tr_TR")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "d MMMM yyyy"
        return formatter.string(from: date)
    }

    static func groups(_ events: [AlertEvent], now: Date, calendar: Calendar = .current) -> [Group] {
        var result: [Group] = []
        for event in events {
            let title = title(for: event.date, now: now, calendar: calendar)
            if let last = result.last, last.title == title {
                result[result.count - 1] = Group(title: title, events: last.events + [event])
            } else {
                result.append(Group(title: title, events: [event]))
            }
        }
        return result
    }
}
