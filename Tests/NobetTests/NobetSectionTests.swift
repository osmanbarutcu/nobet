import AppKit
import Foundation
import Testing
@testable import Nobet

struct NobetSectionTests {
    @Test func sectionsAreInSidebarOrder() {
        let names = NobetSection.allCases.map(\.rawValue)
        #expect(names == ["Genel", "Geliştirme", "Sunucular", "Sırlar", "Ayarlar", "Hakkında"])
    }

    @Test func shortcutsAreUnique() {
        let keys = NobetSection.allCases.compactMap { $0.shortcut?.character }
        #expect(Set(keys).count == keys.count)
    }

    @Test func settingsUsesZeroAndOthersUseDigits() {
        #expect(NobetSection.settings.shortcut?.character == "0")
        #expect(NobetSection.general.shortcut?.character == "1")
        #expect(NobetSection.secrets.shortcut?.character == "4")
    }

    @Test func notificationIdentifiersRouteToSections() {
        #expect(NotificationRoute.section(for: "nobet.server") == .servers)
        #expect(NotificationRoute.section(for: "nobet.secret") == .secrets)
        #expect(NotificationRoute.section(for: "bilinmeyen") == nil)
    }
}

struct StatusLabelTests {
    @Test func noTitleWhenThereIsNoAlert() {
        #expect(StatusLabel.title(alertCount: 0) == "")
    }

    @Test func titleShowsTheCount() {
        #expect(StatusLabel.title(alertCount: 3) == "3")
    }

    @Test func titleCapsAtNinePlus() {
        #expect(StatusLabel.title(alertCount: 10) == "9+")
        #expect(StatusLabel.title(alertCount: 250) == "9+")
    }

    @Test func accessibilityTextNamesTheAlerts() {
        #expect(StatusLabel.accessibility(alertCount: 0) == "Nöbet, uyarı yok")
        #expect(StatusLabel.accessibility(alertCount: 2) == "Nöbet, 2 uyarı")
    }

    @Test func negativeCountIsTreatedAsZero() {
        #expect(StatusLabel.title(alertCount: -4) == "")
    }
}

struct NobetModelTests {
    @Test @MainActor func alertCountSumsAllModules() {
        let model = NobetModel()
        model.setAlerts(2, for: "server")
        model.setAlerts(3, for: "secret")
        #expect(model.alertCount == 5)
    }

    @Test @MainActor func settingAgainReplacesTheModulesCount() {
        let model = NobetModel()
        model.setAlerts(4, for: "server")
        model.setAlerts(1, for: "server")
        #expect(model.alertCount == 1)
    }

    @Test @MainActor func negativeCountBecomesZero() {
        let model = NobetModel()
        model.setAlerts(-3, for: "server")
        #expect(model.alertCount == 0)
    }
}

struct AppLifecycleTests {
    @Test @MainActor func appStaysInMenuBarAfterLastWindowCloses() {
        let delegate = AppDelegate()
        let terminates = delegate.applicationShouldTerminateAfterLastWindowClosed(NSApplication.shared)
        #expect(!terminates)
    }
}

struct StatusTintTests {
    @Test func noIssuesMeansNoTint() {
        #expect(StatusLabel.tint(worst: nil) == .none)
    }

    @Test func mediumIsWarningAndHighIsCritical() {
        #expect(StatusLabel.tint(worst: .medium) == .warning)
        #expect(StatusLabel.tint(worst: .high) == .critical)
    }

    @Test func infoDoesNotColorTheIcon() {
        #expect(StatusLabel.tint(worst: .info) == .none)
    }

    @Test @MainActor func worstSeverityIgnoresSnoozedIssues() {
        let defaults = TestDefaults.make("nobet-tint-test-\(UUID().uuidString)")
        let center = AlertCenter(defaults: defaults, notifier: NullNotifier())
        center.ingest(module: "remote", issues: [
            AlertIssue(key: "a", module: "remote", subject: "s", title: "t", severity: .high),
            AlertIssue(key: "b", module: "remote", subject: "s", title: "t", severity: .medium),
        ])
        #expect(center.worstVisibleSeverity == .high)
        center.snooze(key: "a", for: 3600)
        #expect(center.worstVisibleSeverity == .medium)
        center.snooze(key: "b", for: 3600)
        #expect(center.worstVisibleSeverity == nil)
    }
}

private struct NullNotifier: AlertNotifying {
    func notify(_ event: AlertEvent) {}
}

struct StatusHeroTests {
    @Test func noIssuesIsAllClear() {
        #expect(StatusLabel.hero(openCount: 0, worst: nil) == "Her şey yolunda")
    }

    @Test func issuesAreCountedAndNamedBySeverity() {
        #expect(StatusLabel.hero(openCount: 1, worst: .medium) == "1 sorun var")
        #expect(StatusLabel.hero(openCount: 3, worst: .high) == "3 sorun var, en az biri yüksek önemde")
    }

    @Test func eachSeverityHasItsOwnShapeSymbol() {
        let symbols = [Severity.info, .medium, .high].map(\.symbol)
        #expect(Set(symbols).count == 3)
    }
}

struct CardCollapseTests {
    private func makeDefaults() -> UserDefaults {
        let name = "nobet-collapse-test-\(UUID().uuidString)"
        let defaults = TestDefaults.make(name)
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test @MainActor func cardsStartExpanded() {
        #expect(!CardCollapse(defaults: makeDefaults()).isCollapsed("timeline"))
    }

    @Test @MainActor func toggleCollapsesAndExpandsAgain() {
        let store = CardCollapse(defaults: makeDefaults())
        store.toggle("timeline")
        #expect(store.isCollapsed("timeline"))
        store.toggle("timeline")
        #expect(!store.isCollapsed("timeline"))
    }

    @Test @MainActor func stateSurvivesARestart() {
        let defaults = makeDefaults()
        CardCollapse(defaults: defaults).toggle("history")
        #expect(CardCollapse(defaults: defaults).isCollapsed("history"))
    }

    @Test @MainActor func cardsAreIndependent() {
        let store = CardCollapse(defaults: makeDefaults())
        store.toggle("a")
        #expect(!store.isCollapsed("b"))
    }
}

struct WindowSubtitleTests {
    @Test func subtitleShowsTheIssueCountOnlyWhenThereAreIssues() {
        #expect(StatusLabel.subtitle(alertCount: 0) == "Nöbet")
        #expect(StatusLabel.subtitle(alertCount: 1) == "Nöbet · 1 sorun")
        #expect(StatusLabel.subtitle(alertCount: 12) == "Nöbet · 12 sorun")
    }
}
