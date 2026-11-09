import Foundation
import Testing
@testable import Nobet

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func issue(_ key: String = "k", module: String = "remote", subject: String = "Üretim sunucusu",
                   title: String = "Disk dolu", severity: Severity = .high) -> AlertIssue {
    AlertIssue(key: key, module: module, subject: subject, title: title, severity: severity)
}

private func event(_ minutesAgo: Double, kind: AlertEvent.Kind = .started, issue: AlertIssue = issue()) -> AlertEvent {
    AlertEvent(kind: kind, issue: issue, date: t0.addingTimeInterval(-minutesAgo * 60))
}

struct AlertFilterMatchTests {
    @Test func emptyFilterMatchesEverythingAndIsInactive() {
        let filter = AlertFilter()
        #expect(!filter.isActive)
        #expect(filter.matches(issue: issue(), snoozed: false))
        #expect(filter.matches(event: event(10), snoozed: false, now: t0))
    }

    @Test func severityFilterKeepsOnlyTheChosenLevels() {
        var filter = AlertFilter()
        filter.severities = [.high]
        #expect(filter.isActive)
        #expect(filter.matches(issue: issue(severity: .high), snoozed: false))
        #expect(!filter.matches(issue: issue(severity: .medium), snoozed: false))
    }

    @Test func moduleFilterKeepsOnlyTheChosenModules() {
        var filter = AlertFilter()
        filter.modules = ["secrets", "dev"]
        #expect(filter.matches(issue: issue(module: "dev"), snoozed: false))
        #expect(!filter.matches(issue: issue(module: "remote"), snoozed: false))
    }

    @Test func textSearchIgnoresCaseAndTurkishDiacritics() {
        var filter = AlertFilter()
        filter.text = "uretim"
        #expect(filter.matches(issue: issue(subject: "Üretim sunucusu"), snoozed: false))
        filter.text = "DISK"
        #expect(filter.matches(issue: issue(title: "Disk dolu"), snoozed: false))
        filter.text = "yok"
        #expect(!filter.matches(issue: issue(), snoozed: false))
    }

    @Test func blankTextIsIgnored() {
        var filter = AlertFilter()
        filter.text = "   "
        #expect(!filter.isActive)
        #expect(filter.matches(issue: issue(), snoozed: false))
    }

    @Test func statusSeparatesOpenAndSnoozedIssues() {
        var filter = AlertFilter()
        filter.status = .open
        #expect(filter.matches(issue: issue(), snoozed: false))
        #expect(!filter.matches(issue: issue(), snoozed: true))
        filter.status = .snoozed
        #expect(filter.matches(issue: issue(), snoozed: true))
        #expect(!filter.matches(issue: issue(), snoozed: false))
        filter.status = .resolved
        #expect(!filter.matches(issue: issue(), snoozed: false))
    }

    @Test func statusSeparatesStartedAndResolvedEvents() {
        var filter = AlertFilter()
        filter.status = .open
        #expect(filter.matches(event: event(5, kind: .started), snoozed: false, now: t0))
        #expect(!filter.matches(event: event(5, kind: .resolved), snoozed: false, now: t0))
        filter.status = .resolved
        #expect(filter.matches(event: event(5, kind: .resolved), snoozed: false, now: t0))
    }

    @Test func rangeLimitsEventsByAge() {
        var filter = AlertFilter()
        filter.range = .hour
        #expect(filter.matches(event: event(30), snoozed: false, now: t0))
        #expect(!filter.matches(event: event(120), snoozed: false, now: t0))
        filter.range = .week
        #expect(filter.matches(event: event(3 * 24 * 60), snoozed: false, now: t0))
        #expect(!filter.matches(event: event(8 * 24 * 60), snoozed: false, now: t0))
    }

    @Test func customRangeUsesTheGivenDates() {
        var filter = AlertFilter()
        filter.range = .custom
        filter.from = t0.addingTimeInterval(-3600)
        filter.to = t0
        #expect(filter.matches(event: event(30), snoozed: false, now: t0))
        #expect(!filter.matches(event: event(90), snoozed: false, now: t0))
    }
}

struct AlertFilterChipTests {
    @Test func everyActiveDimensionMakesOneChip() {
        var filter = AlertFilter()
        filter.severities = [.high]
        filter.modules = ["remote"]
        filter.text = "disk"
        filter.status = .open
        filter.range = .day
        let titles = filter.chips.map(\.title)
        #expect(titles == ["Önem: Yüksek", "Modül: SSH sunucuları", "Ara: disk", "Durum: Açık", "Süre: Son 24 saat"])
    }

    @Test func removingAChipResetsOnlyThatDimension() {
        var filter = AlertFilter()
        filter.severities = [.high]
        filter.text = "disk"
        let chip = filter.chips.first { $0.title.hasPrefix("Önem") }!
        let next = filter.removing(chip.dimension)
        #expect(next.severities.isEmpty)
        #expect(next.text == "disk")
    }

    @Test func clearedFilterIsInactive() {
        var filter = AlertFilter()
        filter.severities = [.high]
        #expect(!filter.cleared().isActive)
    }
}

struct AlertListQueryTests {
    private let items = [
        issue("a", title: "Zeta", severity: .medium),
        issue("b", title: "Alfa", severity: .high),
        issue("c", title: "Beta", severity: .high),
    ]

    @Test func severitySortPutsHighFirstThenTitle() {
        #expect(AlertSort.severity.sorted(items).map(\.key) == ["b", "c", "a"])
    }

    @Test func titleSortIsAlphabeticalInTurkish() {
        #expect(AlertSort.title.sorted(items).map(\.title) == ["Alfa", "Beta", "Zeta"])
    }

    @Test func pagingSlicesAndClampsThePage() {
        let numbers = Array(1...25)
        #expect(PageSize.ten.slice(numbers, page: 0) == Array(1...10))
        #expect(PageSize.ten.slice(numbers, page: 2) == Array(21...25))
        #expect(PageSize.ten.slice(numbers, page: 9) == Array(21...25))
        #expect(PageSize.all.slice(numbers, page: 3) == numbers)
        #expect(PageSize.ten.pageCount(for: 25) == 3)
        #expect(PageSize.all.pageCount(for: 25) == 1)
        #expect(PageSize.ten.pageCount(for: 0) == 1)
    }

    @Test func eventsSortNewestFirst() {
        let events = [event(30), event(5), event(60)]
        #expect(AlertSort.date.sorted(events).map(\.date) == events.map(\.date).sorted(by: >))
    }
}

struct SavedFilterTests {
    private func makeDefaults() -> UserDefaults {
        let name = "nobet-savedfilter-\(UUID().uuidString)"
        let defaults = TestDefaults.make(name)
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func savedFilterIsReadBackAfterARestart() {
        let defaults = makeDefaults()
        var filter = AlertFilter()
        filter.severities = [.high]
        filter.modules = ["remote"]
        SavedFilters(defaults: defaults).save(name: "Üretim, yüksek", filter: filter)
        let loaded = SavedFilters(defaults: defaults).all
        #expect(loaded.map(\.name) == ["Üretim, yüksek"])
        #expect(loaded[0].filter == filter)
    }

    @Test func sameNameReplacesTheOldFilter() {
        let store = SavedFilters(defaults: makeDefaults())
        var first = AlertFilter()
        first.text = "a"
        var second = AlertFilter()
        second.text = "b"
        store.save(name: "x", filter: first)
        store.save(name: "x", filter: second)
        #expect(store.all.count == 1)
        #expect(store.all[0].filter.text == "b")
    }

    @Test func blankNamesAndInactiveFiltersAreRefused() {
        let store = SavedFilters(defaults: makeDefaults())
        var filter = AlertFilter()
        filter.text = "a"
        store.save(name: "   ", filter: filter)
        store.save(name: "boş", filter: AlertFilter())
        #expect(store.all.isEmpty)
    }

    @Test func limitIsTenAndDeleteWorks() {
        let store = SavedFilters(defaults: makeDefaults())
        var filter = AlertFilter()
        filter.text = "a"
        for index in 0..<12 { store.save(name: "f\(index)", filter: filter) }
        #expect(store.all.count == SavedFilters.limit)
        store.delete(name: "f0")
        #expect(!store.all.contains { $0.name == "f0" })
    }
}

struct SavedFilterKeyTests {
    @Test func differentKeysKeepSeparateLists() {
        let name = "nobet-savedkey-\(UUID().uuidString)"
        let defaults = TestDefaults.make(name)
        defaults.removePersistentDomain(forName: name)
        var filter = AlertFilter()
        filter.text = "a"
        SavedFilters(defaults: defaults, key: "one").save(name: "x", filter: filter)
        #expect(SavedFilters(defaults: defaults, key: "two").all.isEmpty)
        #expect(SavedFilters(defaults: defaults, key: "one").all.count == 1)
    }
}

struct ServerTimelineTests {
    private func event(_ kind: AlertEvent.Kind, module: String, subject: String, at seconds: TimeInterval) -> AlertEvent {
        let issue = AlertIssue(key: "\(module)|\(subject)|\(seconds)", module: module, subject: subject, title: "Başlık", severity: .medium)
        return AlertEvent(kind: kind, issue: issue, date: Date(timeIntervalSince1970: seconds))
    }

    @Test func keepsOnlyTheChosenServerNewestFirst() {
        let history = [
            event(.started, module: "remote", subject: "a", at: 10),
            event(.started, module: "remote", subject: "b", at: 20),
            event(.resolved, module: "remote", subject: "a", at: 30),
            event(.started, module: "servers", subject: "a", at: 40),
        ]
        let result = ServerTimeline.events(history, module: "remote", subject: "a")
        #expect(result.map(\.date.timeIntervalSince1970) == [30, 10])
    }

    @Test func limitCutsTheOldest() {
        let history = (1...8).map { event(.started, module: "remote", subject: "a", at: TimeInterval($0)) }
        let result = ServerTimeline.events(history, module: "remote", subject: "a", limit: 3)
        #expect(result.map(\.date.timeIntervalSince1970) == [8, 7, 6])
    }
}

struct ModuleSectionTests {
    @Test func everyModuleOpensItsPage() {
        #expect(ModuleNames.section("dev") == .development)
        #expect(ModuleNames.section("sbom") == .development)
        #expect(ModuleNames.section("servers") == .servers)
        #expect(ModuleNames.section("remote") == .servers)
        #expect(ModuleNames.section("secrets") == .secrets)
        #expect(ModuleNames.section("net") == .network)
    }

    @Test func networkModuleIsListedWithATitle() {
        #expect(ModuleNames.order.contains("net"))
        #expect(ModuleNames.title("net") == "Ağ")
        #expect(ModuleNames.symbol("net") == "network")
    }

    @Test func unknownModuleFallsBackToGeneral() {
        #expect(ModuleNames.section("yok") == .general)
    }

    @Test func allListedModulesHaveAPage() {
        for key in ModuleNames.order { #expect(ModuleNames.section(key) != .general) }
    }
}

struct ModuleSymbolTests {
    @Test func everyListedModuleHasADistinctSymbol() {
        let symbols = ModuleNames.order.map(ModuleNames.symbol)
        #expect(Set(symbols).count == symbols.count)
        #expect(!symbols.contains("questionmark.circle"))
    }

    @Test func unknownModuleGetsAFallbackSymbol() {
        #expect(ModuleNames.symbol("yok") == "questionmark.circle")
    }
}

struct DayGroupingTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func date(_ day: Int, hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour))!
    }

    private func event(_ id: String, _ date: Date) -> AlertEvent {
        AlertEvent(kind: .started, issue: AlertIssue(key: id, module: "dev", subject: "s", title: "t", severity: .info), date: date)
    }

    @Test func titlesNameTodayAndYesterday() {
        let now = date(7, hour: 15)
        #expect(DayGrouping.title(for: date(7, hour: 1), now: now, calendar: calendar) == "Bugün")
        #expect(DayGrouping.title(for: date(6, hour: 23), now: now, calendar: calendar) == "Dün")
        #expect(DayGrouping.title(for: date(3, hour: 9), now: now, calendar: calendar) == "3 Kasım 2026")
    }

    @Test func groupsKeepOrderAndSplitOnDayChange() {
        let now = date(7, hour: 15)
        let events = [event("a", date(7, hour: 14)), event("b", date(7, hour: 2)), event("c", date(6, hour: 22)), event("d", date(3, hour: 1))]
        let groups = DayGrouping.groups(events, now: now, calendar: calendar)
        #expect(groups.map(\.title) == ["Bugün", "Dün", "3 Kasım 2026"])
        #expect(groups.map { $0.events.map(\.issue.key) } == [["a", "b"], ["c"], ["d"]])
    }

    @Test func emptyInputGivesNoGroups() {
        #expect(DayGrouping.groups([], now: Date(), calendar: calendar).isEmpty)
    }
}
