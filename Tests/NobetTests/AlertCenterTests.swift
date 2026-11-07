import Foundation
import Testing
@testable import Nobet

/// Sistem bildirimi göndermeyen sahte gönderici.
private final class FakeNotifier: AlertNotifying {
    private(set) var sent: [AlertEvent] = []
    private(set) var summaries: [(title: String, body: String)] = []
    func notify(_ event: AlertEvent) { sent.append(event) }
    func notifySummary(title: String, body: String) { summaries.append((title, body)) }
}

private func issue(_ key: String, module: String = "servers", severity: Severity = .high) -> AlertIssue {
    AlertIssue(key: key, module: module, subject: "a.com", title: "Sorun \(key)", severity: severity)
}

@MainActor
struct AlertCenterTests {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func makeDefaults() -> UserDefaults {
        let name = "nobet-alert-test-\(UUID().uuidString)"
        let defaults = TestDefaults.make(name)
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func noon() -> Date {
        utc.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 12))!
    }

    private func makeCenter(defaults: UserDefaults? = nil, notifier: AlertNotifying? = nil, now: Date? = nil) -> AlertCenter {
        let fixed = now ?? noon()
        return AlertCenter(defaults: defaults ?? makeDefaults(), notifier: notifier ?? FakeNotifier(), now: { fixed }, calendar: utc)
    }

    @Test func startedIssueNotifiesOnceAndStaysSilentAfterwards() {
        let notifier = FakeNotifier()
        let center = makeCenter(notifier: notifier)
        center.ingest(module: "servers", issues: [issue("a")])
        center.ingest(module: "servers", issues: [issue("a")])
        #expect(notifier.sent.map(\.kind) == [.started])
        #expect(center.active.map(\.key) == ["a"])
    }

    @Test func continuingIssueTakesTheLatestSubjectWithoutNotifyingAgain() {
        let notifier = FakeNotifier()
        let center = makeCenter(notifier: notifier)
        center.ingest(module: "secrets", issues: [AlertIssue(key: "k", module: "secrets", subject: ".env", title: "T", severity: .high)])
        center.ingest(module: "secrets", issues: [AlertIssue(key: "k", module: "secrets", subject: "api/.env", title: "T", severity: .high)])
        #expect(center.active.map(\.subject) == ["api/.env"])
        #expect(notifier.sent.count == 1)
    }

    @Test func resolvedIssueNotifiesAndLeavesTheActiveList() {
        let notifier = FakeNotifier()
        let center = makeCenter(notifier: notifier)
        center.ingest(module: "servers", issues: [issue("a")])
        center.ingest(module: "servers", issues: [])
        #expect(notifier.sent.map(\.kind) == [.started, .resolved])
        #expect(center.active.isEmpty)
    }

    @Test func modulesAreIndependent() {
        let center = makeCenter()
        center.ingest(module: "servers", issues: [issue("a")])
        center.ingest(module: "secrets", issues: [])
        #expect(center.active.map(\.key) == ["a"])
        #expect(center.activeCount(module: "servers") == 1)
        #expect(center.activeCount(module: "secrets") == 0)
    }

    @Test func infoIssuesAreIgnored() {
        let notifier = FakeNotifier()
        let center = makeCenter(notifier: notifier)
        center.ingest(module: "servers", issues: [issue("a", severity: .info)])
        #expect(notifier.sent.isEmpty)
        #expect(center.active.isEmpty)
    }

    @Test func disabledNotificationsStillRecordHistory() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AlertCenter.notifyKey)
        let notifier = FakeNotifier()
        let center = makeCenter(defaults: defaults, notifier: notifier)
        center.ingest(module: "servers", issues: [issue("a")])
        #expect(notifier.sent.isEmpty)
        #expect(center.history.count == 1)
    }

    @Test func quietHoursSuppressNotificationsButNotHistory() {
        let night = utc.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 2))!
        let notifier = FakeNotifier()
        let center = makeCenter(notifier: notifier, now: night)
        center.ingest(module: "servers", issues: [issue("a")])
        #expect(notifier.sent.isEmpty)
        #expect(center.history.count == 1)
    }

    @Test func quietHoursCanBeTurnedOff() {
        let night = utc.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: 2))!
        let defaults = makeDefaults()
        defaults.set(false, forKey: AlertCenter.quietEnabledKey)
        let notifier = FakeNotifier()
        let center = makeCenter(defaults: defaults, notifier: notifier, now: night)
        center.ingest(module: "servers", issues: [issue("a")])
        #expect(notifier.sent.count == 1)
    }

    @Test func restartDoesNotRepeatAKnownAlert() {
        let defaults = makeDefaults()
        makeCenter(defaults: defaults).ingest(module: "servers", issues: [issue("a")])
        let notifier = FakeNotifier()
        let restarted = makeCenter(defaults: defaults, notifier: notifier)
        #expect(restarted.active.map(\.key) == ["a"])
        restarted.ingest(module: "servers", issues: [issue("a")])
        #expect(notifier.sent.isEmpty)
    }

    @Test func storedHistoryHasNoDetailText() {
        let defaults = makeDefaults()
        makeCenter(defaults: defaults).ingest(module: "servers", issues: [issue("a")])
        let saved = String(decoding: defaults.data(forKey: AlertCenter.historyKey) ?? Data(), as: UTF8.self)
        #expect(saved.contains("Sorun a"))
        #expect(!saved.contains("detail"))
    }

    @Test func routeIdentifiersMatchTheNotificationRoutes() {
        #expect(issue("a", module: "servers").routeIdentifier == "nobet.server")
        #expect(issue("a", module: "remote").routeIdentifier == "nobet.server")
        #expect(issue("a", module: "secrets").routeIdentifier == "nobet.secret")
        #expect(issue("a", module: "dev").routeIdentifier == "nobet.dev")
        #expect(NotificationRoute.section(for: issue("a", module: "remote").routeIdentifier) == .servers)
    }

    @Test func notificationTextIsShortAndSecretFree() {
        let started = AlertEvent(kind: .started, issue: issue("a"), date: noon())
        let resolved = AlertEvent(kind: .resolved, issue: issue("a"), date: noon())
        #expect(started.notificationTitle.contains("Sorun a"))
        #expect(resolved.notificationTitle.contains("düzeldi"))
        #expect(started.notificationBody == "a.com")
    }
}

@MainActor
struct WeeklySummaryTests {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ month: Int, _ day: Int, _ hour: Int) -> Date {
        utc.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    private func makeDefaults() -> UserDefaults {
        let name = "nobet-weekly-test-\(UUID().uuidString)"
        let defaults = TestDefaults.make(name)
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func slotIsTheMostRecentMondayNineAm() {
        #expect(WeeklySummary.latestSlot(now: date(11, 7, 12), calendar: utc) == date(11, 2, 9))
        #expect(WeeklySummary.latestSlot(now: date(11, 9, 9), calendar: utc) == date(11, 9, 9))
        #expect(WeeklySummary.latestSlot(now: date(11, 9, 8), calendar: utc) == date(11, 2, 9))
    }

    @Test func countsOnlyTheLastSevenDays() {
        let now = date(11, 9, 9)
        func event(_ kind: AlertEvent.Kind, daysAgo: Double) -> AlertEvent {
            AlertEvent(kind: kind, issue: issue("k\(daysAgo)"), date: now.addingTimeInterval(-daysAgo * 86_400))
        }
        let events = [event(.started, daysAgo: 1), event(.started, daysAgo: 6), event(.resolved, daysAgo: 2), event(.started, daysAgo: 8)]
        let counts = WeeklySummary.counts(events, now: now)
        #expect(counts.started == 2)
        #expect(counts.resolved == 1)
    }

    @Test func bodyIsConcrete() {
        #expect(WeeklySummary.body(started: 3, resolved: 2, open: 1) == "Son 7 gün: 3 sorun başladı, 2 sorun düzeldi. Şu an açık: 1.")
    }

    @Test func firstRunOnlyStartsTheCountAndSendsNothing() {
        let notifier = FakeNotifier()
        let center = AlertCenter(defaults: makeDefaults(), notifier: notifier, now: { date(11, 9, 10) }, calendar: utc)
        center.sendWeeklySummaryIfDue()
        #expect(notifier.summaries.isEmpty)
    }

    @Test func sendsOnceAfterTheMondaySlot() {
        let defaults = makeDefaults()
        defaults.set(date(11, 2, 10).timeIntervalSince1970, forKey: AlertCenter.weeklyLastKey)
        let notifier = FakeNotifier()
        let center = AlertCenter(defaults: defaults, notifier: notifier, now: { date(11, 9, 10) }, calendar: utc)
        defaults.set(false, forKey: AlertCenter.quietEnabledKey)
        center.sendWeeklySummaryIfDue()
        center.sendWeeklySummaryIfDue()
        #expect(notifier.summaries.count == 1)
        #expect(notifier.summaries[0].title == "Nöbet haftalık özet")
    }

    @Test func staysSilentBeforeTheSlot() {
        let defaults = makeDefaults()
        defaults.set(date(11, 2, 10).timeIntervalSince1970, forKey: AlertCenter.weeklyLastKey)
        let notifier = FakeNotifier()
        let center = AlertCenter(defaults: defaults, notifier: notifier, now: { date(11, 5, 10) }, calendar: utc)
        center.sendWeeklySummaryIfDue()
        #expect(notifier.summaries.isEmpty)
    }

    @Test func switchedOffSendsNothing() {
        let defaults = makeDefaults()
        defaults.set(date(11, 2, 10).timeIntervalSince1970, forKey: AlertCenter.weeklyLastKey)
        defaults.set(false, forKey: AlertCenter.weeklyKey)
        let notifier = FakeNotifier()
        let center = AlertCenter(defaults: defaults, notifier: notifier, now: { date(11, 9, 10) }, calendar: utc)
        center.sendWeeklySummaryIfDue()
        #expect(notifier.summaries.isEmpty)
    }
}

@MainActor
struct WeekendQuietTests {
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ day: Int, _ hour: Int) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    private func center(defaults: UserDefaults, now: Date, notifier: FakeNotifier) -> AlertCenter {
        AlertCenter(defaults: defaults, notifier: notifier, now: { now }, calendar: utc)
    }

    private func makeDefaults() -> UserDefaults {
        let name = "nobet-weekend-test-\(UUID().uuidString)"
        let defaults = TestDefaults.make(name)
        defaults.removePersistentDomain(forName: name)
        defaults.set(true, forKey: AlertCenter.quietEnabledKey)
        defaults.set(23 * 60, forKey: AlertCenter.quietStartKey)
        defaults.set(8 * 60, forKey: AlertCenter.quietEndKey)
        return defaults
    }

    @Test func weekendUsesItsOwnWindowWhenSet() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AlertCenter.weekendCustomKey)
        defaults.set(0, forKey: AlertCenter.weekendStartKey)
        defaults.set(10 * 60, forKey: AlertCenter.weekendEndKey)
        // 7 Kasım 2026 cumartesi, 9 Kasım pazartesi.
        #expect(center(defaults: defaults, now: date(7, 9), notifier: FakeNotifier()).isQuiet(at: date(7, 9)))
        #expect(!center(defaults: defaults, now: date(9, 9), notifier: FakeNotifier()).isQuiet(at: date(9, 9)))
    }

    @Test func weekdayWindowStillAppliesOnWeekdays() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: AlertCenter.weekendCustomKey)
        let current = center(defaults: defaults, now: date(9, 23), notifier: FakeNotifier())
        #expect(current.isQuiet(at: date(9, 23)))
        #expect(!current.isQuiet(at: date(9, 12)))
    }

    @Test func withoutACustomWeekendTheSameWindowApplies() {
        let defaults = makeDefaults()
        let current = center(defaults: defaults, now: date(7, 23), notifier: FakeNotifier())
        #expect(current.isQuiet(at: date(7, 23)))
        #expect(!current.isQuiet(at: date(7, 12)))
    }
}

struct AlertSoundTests {
    @Test func modesDecideWhichSeverityPlaysASound() {
        #expect(AlertSoundMode.all.plays(.medium))
        #expect(AlertSoundMode.all.plays(.high))
        #expect(!AlertSoundMode.highOnly.plays(.medium))
        #expect(AlertSoundMode.highOnly.plays(.high))
        #expect(!AlertSoundMode.off.plays(.high))
    }

    @Test func unknownStoredValueMeansHighOnly() {
        #expect(AlertSoundMode(stored: "yok") == .highOnly)
        #expect(AlertSoundMode(stored: nil) == .highOnly)
        #expect(AlertSoundMode(stored: "off") == .off)
    }
}

struct NotificationActionTests {
    private func event(_ kind: AlertEvent.Kind) -> AlertEvent {
        AlertEvent(kind: kind, issue: AlertIssue(key: "remote|1|Disk dolu", module: "remote", subject: "s", title: "t", severity: .high),
                   date: Date(timeIntervalSince1970: 1_800_000_000))
    }

    @Test func startedEventCarriesTheKeyAndTheSnoozeCategory() {
        let info = NotificationAction.userInfo(for: event(.started))
        #expect(info[NotificationAction.keyField] as? String == "remote|1|Disk dolu")
        #expect(NotificationAction.category(for: event(.started)) == NotificationAction.categoryId)
    }

    @Test func resolvedEventHasNoSnoozeButton() {
        #expect(NotificationAction.category(for: event(.resolved)) == nil)
    }

    @Test func snoozeKeyIsReadOnlyForTheSnoozeAction() {
        let info: [AnyHashable: Any] = [NotificationAction.keyField: "k"]
        #expect(NotificationAction.snoozeKey(action: NotificationAction.snoozeId, userInfo: info) == "k")
        #expect(NotificationAction.snoozeKey(action: "com.apple.UNNotificationDefaultActionIdentifier", userInfo: info) == nil)
        #expect(NotificationAction.snoozeKey(action: NotificationAction.snoozeId, userInfo: [:]) == nil)
    }

    @Test func snoozeLastsOneHour() {
        #expect(NotificationAction.snoozeSeconds == 3600)
    }
}
