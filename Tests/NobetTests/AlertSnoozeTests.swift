import Foundation
import Testing
@testable import Nobet

private final class Recorder: AlertNotifying {
    private(set) var sent: [AlertEvent] = []
    func notify(_ event: AlertEvent) { sent.append(event) }
}

/// Testte ilerletilebilen saat.
private final class Clock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func issue(_ key: String, module: String = "remote", severity: Severity = .high) -> AlertIssue {
    AlertIssue(key: key, module: module, subject: "sunucu", title: "Sorun \(key)", severity: severity)
}

@MainActor
private struct Rig {
    let center: AlertCenter
    let recorder: Recorder
    let clock: Clock
    let nobet: NobetModel
    let defaults: UserDefaults

    init(defaults: UserDefaults? = nil, clock: Clock = Clock(t0)) {
        let name = "nobet-snooze-test-\(UUID().uuidString)"
        let store = defaults ?? TestDefaults.make(name)
        if defaults == nil { store.removePersistentDomain(forName: name) }
        store.set(false, forKey: AlertCenter.quietEnabledKey)
        let recorder = Recorder()
        let nobet = NobetModel()
        self.defaults = store
        self.recorder = recorder
        self.clock = clock
        self.nobet = nobet
        self.center = AlertCenter(defaults: store, notifier: recorder, now: { clock.date }, nobet: nobet)
    }
}

struct AlertSnoozeTests {
    @Test @MainActor func snoozedIssueDoesNotCountAnymore() {
        let rig = Rig()
        rig.center.ingest(module: "remote", issues: [issue("a"), issue("b")])
        #expect(rig.nobet.alerts["remote"] == 2)
        rig.center.snooze(key: "a", for: 3600)
        #expect(rig.center.isSnoozed("a"))
        #expect(rig.center.visibleCount(module: "remote") == 1)
        #expect(rig.nobet.alerts["remote"] == 1)
        #expect(rig.center.active.count == 2)
    }

    @Test @MainActor func snoozeExpiresByTheClock() {
        let rig = Rig()
        rig.center.ingest(module: "remote", issues: [issue("a")])
        rig.center.snooze(key: "a", for: 3600)
        rig.clock.date = t0.addingTimeInterval(3601)
        #expect(!rig.center.isSnoozed("a"))
        #expect(rig.center.snoozeRemaining(key: "a") == nil)
        rig.center.ingest(module: "remote", issues: [issue("a")])
        #expect(rig.nobet.alerts["remote"] == 1)
    }

    @Test @MainActor func remainingTimeIsReported() {
        let rig = Rig()
        rig.center.ingest(module: "remote", issues: [issue("a")])
        rig.center.snooze(key: "a", for: 3600)
        rig.clock.date = t0.addingTimeInterval(600)
        #expect(rig.center.snoozeRemaining(key: "a") == 3000)
    }

    @Test @MainActor func unsnoozeBringsTheIssueBack() {
        let rig = Rig()
        rig.center.ingest(module: "remote", issues: [issue("a")])
        rig.center.snooze(key: "a", for: 3600)
        rig.center.unsnooze(key: "a")
        #expect(!rig.center.isSnoozed("a"))
        #expect(rig.nobet.alerts["remote"] == 1)
    }

    @Test @MainActor func unknownKeyCannotBeSnoozed() {
        let rig = Rig()
        rig.center.snooze(key: "yok", for: 3600)
        #expect(!rig.center.isSnoozed("yok"))
    }

    @Test @MainActor func nonPositiveDurationIsIgnored() {
        let rig = Rig()
        rig.center.ingest(module: "remote", issues: [issue("a")])
        rig.center.snooze(key: "a", for: 0)
        rig.center.snooze(key: "a", for: -5)
        #expect(!rig.center.isSnoozed("a"))
    }

    @Test @MainActor func snoozedIssueResolvingIsSilentButRecorded() {
        let rig = Rig()
        rig.center.ingest(module: "remote", issues: [issue("a")])
        rig.center.snooze(key: "a", for: 3600)
        let before = rig.recorder.sent.count
        rig.center.ingest(module: "remote", issues: [])
        #expect(rig.recorder.sent.count == before)
        #expect(rig.center.history.first?.kind == .resolved)
        #expect(!rig.center.isSnoozed("a"))
    }

    @Test @MainActor func recurrenceAfterResolutionNotifiesAgain() {
        let rig = Rig()
        rig.center.ingest(module: "remote", issues: [issue("a")])
        rig.center.snooze(key: "a", for: 3600)
        rig.center.ingest(module: "remote", issues: [])
        rig.center.ingest(module: "remote", issues: [issue("a")])
        #expect(rig.recorder.sent.map(\.kind) == [.started, .started])
        #expect(!rig.center.isSnoozed("a"))
    }

    @Test @MainActor func snoozedIssueStaysSilentWhileItIsStillActive() {
        let rig = Rig()
        rig.center.ingest(module: "remote", issues: [issue("a")])
        rig.center.snooze(key: "a", for: 3600)
        rig.center.ingest(module: "remote", issues: [issue("a")])
        #expect(rig.recorder.sent.count == 1)
    }

    @Test @MainActor func snoozeSurvivesARestart() {
        let rig = Rig()
        rig.center.ingest(module: "remote", issues: [issue("a")])
        rig.center.snooze(key: "a", for: 3600)
        let restarted = Rig(defaults: rig.defaults, clock: rig.clock)
        #expect(restarted.center.isSnoozed("a"))
        restarted.center.ingest(module: "remote", issues: [issue("a")])
        #expect(restarted.nobet.alerts["remote"] == 0)
    }

    @Test @MainActor func expiredSnoozeIsDroppedOnLoad() {
        let rig = Rig()
        rig.center.ingest(module: "remote", issues: [issue("a")])
        rig.center.snooze(key: "a", for: 60)
        rig.clock.date = t0.addingTimeInterval(120)
        let restarted = Rig(defaults: rig.defaults, clock: rig.clock)
        #expect(restarted.center.snoozes.isEmpty)
    }

    @Test @MainActor func storedSnoozeHasNoTitleOrSubject() {
        let rig = Rig()
        rig.center.ingest(module: "remote", issues: [issue("a")])
        rig.center.snooze(key: "a", for: 3600)
        let saved = String(decoding: rig.defaults.data(forKey: AlertCenter.snoozeKey) ?? Data(), as: UTF8.self)
        #expect(saved.contains("\"a\""))
        #expect(!saved.contains("Sorun"))
        #expect(!saved.contains("sunucu"))
    }

    @Test @MainActor func otherModulesAreNotAffected() {
        let rig = Rig()
        rig.center.ingest(module: "remote", issues: [issue("a")])
        rig.center.ingest(module: "secrets", issues: [issue("s", module: "secrets")])
        rig.center.snooze(key: "a", for: 3600)
        #expect(rig.nobet.alerts["secrets"] == 1)
    }

    @Test func snoozeChoicesAreOneHourOneDayAndOneWeek() {
        #expect(SnoozeChoice.allCases.map(\.seconds) == [3600, 86_400, 604_800])
        #expect(SnoozeChoice.allCases.map(\.title) == ["1 saat", "1 gün", "7 gün"])
    }

    @Test func remainingTextIsShortAndConcrete() {
        #expect(SnoozeChoice.remainingText(seconds: 3000) == "50 dk kaldı")
        #expect(SnoozeChoice.remainingText(seconds: 7300) == "2 sa kaldı")
        #expect(SnoozeChoice.remainingText(seconds: 90_000) == "1 gün kaldı")
        #expect(SnoozeChoice.remainingText(seconds: 30) == "1 dk kaldı")
    }

    @Test @MainActor func noteIsStoredTrimmedAndLimited() {
        let rig = Rig()
        rig.center.ingest(module: "remote", issues: [issue("a")])
        rig.center.setNote("  bakım penceresi  ", for: "a")
        #expect(rig.center.note(for: "a") == "bakım penceresi")
        rig.center.setNote(String(repeating: "x", count: 500), for: "a")
        #expect(rig.center.note(for: "a")?.count == AlertCenter.noteLimit)
    }

    @Test @MainActor func emptyNoteRemovesIt() {
        let rig = Rig()
        rig.center.ingest(module: "remote", issues: [issue("a")])
        rig.center.setNote("not", for: "a")
        rig.center.setNote("   ", for: "a")
        #expect(rig.center.note(for: "a") == nil)
    }

    @Test @MainActor func unknownKeyGetsNoNote() {
        let rig = Rig()
        rig.center.setNote("not", for: "yok")
        #expect(rig.center.note(for: "yok") == nil)
    }

    @Test @MainActor func noteSurvivesARestartAndDiesWithTheIssue() {
        let rig = Rig()
        rig.center.ingest(module: "remote", issues: [issue("a")])
        rig.center.setNote("not", for: "a")
        let restarted = Rig(defaults: rig.defaults, clock: rig.clock)
        #expect(restarted.center.note(for: "a") == "not")
        restarted.center.ingest(module: "remote", issues: [])
        #expect(restarted.center.note(for: "a") == nil)
    }
}
