import Foundation
import Testing
@testable import Nobet

struct NetworkBaselineTests {
    @Test func emptyBaselineHasLearnedNothing() {
        #expect(!NetworkBaseline.empty.learned)
        #expect(NetworkBaseline.empty.known.isEmpty)
        #expect(NetworkBaseline.empty.trusted.isEmpty)
    }

    @Test func firstObservationLearnsSilently() {
        let result = NetworkBaseline.empty.observing(["a", "b"])
        #expect(result.newKeys.isEmpty)
        #expect(result.baseline.learned)
        #expect(result.baseline.known == ["a", "b"])
    }

    @Test func laterObservationReportsOnlyUnknownKeys() {
        let learned = NetworkBaseline.empty.observing(["a", "b"]).baseline
        let result = learned.observing(["a", "b", "c"])
        #expect(result.newKeys == ["c"])
    }

    @Test func reportedKeyStaysNewUntilTheUserTrustsIt() {
        let learned = NetworkBaseline.empty.observing(["a"]).baseline
        let first = learned.observing(["a", "c"])
        let second = first.baseline.observing(["a", "c"])
        #expect(first.newKeys == ["c"])
        #expect(second.newKeys == ["c"])
    }

    @Test func trustingRemovesTheKeyFromNew() {
        let learned = NetworkBaseline.empty.observing(["a"]).baseline
        let trusted = learned.trusting("c")
        #expect(trusted.observing(["a", "c"]).newKeys.isEmpty)
        #expect(trusted.isTrusted("c"))
    }

    @Test func untrustingBringsTheKeyBack() {
        let learned = NetworkBaseline.empty.observing(["a"]).baseline
        let back = learned.trusting("c").untrusting("c")
        #expect(back.observing(["a", "c"]).newKeys == ["c"])
        #expect(!back.isTrusted("c"))
    }

    @Test func operationsReturnNewValuesAndLeaveTheOriginalAlone() {
        let original = NetworkBaseline.empty
        _ = original.observing(["a"])
        _ = original.trusting("a")
        #expect(original == NetworkBaseline.empty)
    }

    @Test func goneKeysStayKnown() {
        let learned = NetworkBaseline.empty.observing(["a", "b"]).baseline
        let after = learned.observing(["a"]).baseline
        #expect(after.known == ["a", "b"])
    }

    @Test func resetStartsLearningAgain() {
        let learned = NetworkBaseline.empty.observing(["a"]).baseline.trusting("t")
        let reset = learned.reset()
        #expect(!reset.learned)
        #expect(reset.known.isEmpty)
        #expect(reset.trusted == ["t"])
    }

    private func makeDefaults() -> UserDefaults {
        let name = "nobet-network-test-\(UUID().uuidString)"
        let defaults = TestDefaults.make(name)
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test func storeRoundTripKeepsAllState() {
        let defaults = makeDefaults()
        let baseline = NetworkBaseline.empty.observing(["a", "b"]).baseline.trusting("t")
        NetworkBaselineStore.save(baseline, to: defaults)
        #expect(NetworkBaselineStore.load(from: defaults) == baseline)
    }

    @Test func storeStartsEmptyWhenNothingIsSaved() {
        #expect(NetworkBaselineStore.load(from: makeDefaults()) == NetworkBaseline.empty)
    }
}
