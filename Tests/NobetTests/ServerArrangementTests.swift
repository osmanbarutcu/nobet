import Foundation
import Testing
@testable import Nobet

struct ServerArrangementTests {
    private func store() -> UserDefaults {
        let name = "nobet-arrange-test-\(UUID().uuidString)"
        let defaults = TestDefaults.make(name)
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func profile(_ id: String) -> SSHProfile {
        SSHProfile.make(name: id, host: "\(id).example.com", port: 22, user: "root", auth: .key, services: [], id: id)!
    }

    @Test func withoutSavedOrderKeepsTheInputOrder() {
        let arrangement = ServerArrangement(defaults: store())
        let list = [profile("a"), profile("b"), profile("c")]
        #expect(arrangement.sorted(list).map(\.id) == ["a", "b", "c"])
    }

    @Test func moveDownAndUpSwapNeighbours() {
        var arrangement = ServerArrangement(defaults: store())
        let list = [profile("a"), profile("b"), profile("c")]
        arrangement.move("a", by: 1, in: list)
        #expect(arrangement.sorted(list).map(\.id) == ["b", "a", "c"])
        arrangement.move("c", by: -1, in: list)
        #expect(arrangement.sorted(list).map(\.id) == ["b", "c", "a"])
    }

    @Test func moveAtTheEdgeDoesNothing() {
        var arrangement = ServerArrangement(defaults: store())
        let list = [profile("a"), profile("b")]
        arrangement.move("a", by: -1, in: list)
        arrangement.move("b", by: 1, in: list)
        #expect(arrangement.sorted(list).map(\.id) == ["a", "b"])
    }

    @Test func newProfilesGoToTheEndAndRemovedOnesVanish() {
        var arrangement = ServerArrangement(defaults: store())
        arrangement.move("a", by: 1, in: [profile("a"), profile("b")])
        #expect(arrangement.sorted([profile("a"), profile("b"), profile("c")]).map(\.id) == ["b", "a", "c"])
        #expect(arrangement.sorted([profile("a"), profile("c")]).map(\.id) == ["a", "c"])
    }

    @Test func groupsAreTrimmedLimitedAndClearable() {
        var arrangement = ServerArrangement(defaults: store())
        arrangement.setGroup("  Üretim  ", for: "a")
        #expect(arrangement.group(for: "a") == "Üretim")
        arrangement.setGroup(String(repeating: "x", count: 100), for: "b")
        #expect(arrangement.group(for: "b")?.count == ServerArrangement.groupLimit)
        arrangement.setGroup("   ", for: "a")
        #expect(arrangement.group(for: "a") == nil)
    }

    @Test func sectionsGroupInOrderWithUngroupedLast() {
        var arrangement = ServerArrangement(defaults: store())
        arrangement.setGroup("Üretim", for: "a")
        arrangement.setGroup("Test", for: "b")
        arrangement.setGroup("Üretim", for: "d")
        let sections = arrangement.sections([profile("a"), profile("b"), profile("c"), profile("d")])
        #expect(sections.map(\.title) == ["Üretim", "Test", ""])
        #expect(sections[0].profiles.map(\.id) == ["a", "d"])
        #expect(sections[2].profiles.map(\.id) == ["c"])
    }

    @Test func settingsSurviveAReload() {
        let defaults = store()
        var first = ServerArrangement(defaults: defaults)
        first.setGroup("Üretim", for: "a")
        first.move("a", by: 1, in: [profile("a"), profile("b")])
        let second = ServerArrangement(defaults: defaults)
        #expect(second.group(for: "a") == "Üretim")
        #expect(second.sorted([profile("a"), profile("b")]).map(\.id) == ["b", "a"])
    }
}
