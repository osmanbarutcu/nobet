import Foundation
import Testing
@testable import Nobet

/// Ağa çıkmayan sahte kontrolcü. Site başına hazır sonuç verir.
private struct FakeProber: ServerProbing {
    var results: [String: ProbeResult]
    func probe(_ site: ServerSite) async -> ProbeResult {
        results[site.host] ?? ProbeResult(reachable: false, httpStatus: nil, latencyMs: nil, certExpiry: nil, error: "sahte")
    }
}

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let ok = ProbeResult(reachable: true, httpStatus: 200, latencyMs: 100, certExpiry: now.addingTimeInterval(90 * 86_400), error: nil)
private let down = ProbeResult(reachable: false, httpStatus: nil, latencyMs: nil, certExpiry: nil, error: "zaman aşımı")

struct ServerModelTests {
    private func makeDefaults() -> UserDefaults {
        let name = "nobet-server-test-\(UUID().uuidString)"
        let defaults = TestDefaults.make(name)
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @MainActor
    private func makeModel(nobet: NobetModel? = nil, defaults: UserDefaults? = nil, results: [String: ProbeResult] = [:]) -> ServerModel {
        ServerModel(nobet: nobet ?? NobetModel(), defaults: defaults ?? makeDefaults(), prober: FakeProber(results: results), now: { now })
    }

    @Test @MainActor func addedSiteIsPersistedAndReloaded() {
        let defaults = makeDefaults()
        let model = makeModel(defaults: defaults)
        model.addSite(name: "Ana", host: "example.com", port: 443)
        #expect(model.sites.map(\.host) == ["example.com"])
        #expect(makeModel(defaults: defaults).sites.map(\.host) == ["example.com"])
    }

    @Test @MainActor func invalidSiteIsRefusedWithAMessage() {
        let model = makeModel()
        model.addSite(name: "x", host: "https://example.com", port: 443)
        #expect(model.sites.isEmpty)
        #expect(model.errorText != nil)
    }

    @Test @MainActor func duplicateHostAndPortIsRefused() {
        let model = makeModel()
        model.addSite(name: "a", host: "example.com", port: 443)
        model.addSite(name: "b", host: "Example.com", port: 443)
        #expect(model.sites.count == 1)
        #expect(model.errorText != nil)
        model.addSite(name: "c", host: "example.com", port: 8443)
        #expect(model.sites.count == 2)
    }

    @Test @MainActor func checkAllStoresIssuesPerSiteAndPublishesAlerts() async {
        let nobet = NobetModel()
        let model = makeModel(nobet: nobet, results: ["good.com": ok, "bad.com": down])
        model.addSite(name: "iyi", host: "good.com", port: 443)
        model.addSite(name: "kötü", host: "bad.com", port: 443)
        await model.checkAll()
        #expect(model.checked)
        #expect(model.issues(for: model.sites[0]).isEmpty)
        #expect(model.issues(for: model.sites[1]).map(\.kind) == [.down])
        #expect(nobet.alerts["servers"] == 1)
    }

    @Test @MainActor func removingASiteDropsItsAlert() async {
        let nobet = NobetModel()
        let model = makeModel(nobet: nobet, results: ["bad.com": down])
        model.addSite(name: "kötü", host: "bad.com", port: 443)
        await model.checkAll()
        #expect(nobet.alertCount == 1)
        model.removeSite(model.sites[0])
        #expect(model.sites.isEmpty)
        #expect(nobet.alertCount == 0)
    }

    @Test @MainActor func recoveryClearsTheAlert() async {
        let nobet = NobetModel()
        var model = makeModel(nobet: nobet, results: ["a.com": down])
        model.addSite(name: "a", host: "a.com", port: 443)
        await model.checkAll()
        #expect(nobet.alertCount == 1)
        let defaults = makeDefaults()
        model = makeModel(nobet: nobet, defaults: defaults, results: ["a.com": ok])
        model.addSite(name: "a", host: "a.com", port: 443)
        await model.checkAll()
        #expect(nobet.alertCount == 0)
    }

    @Test @MainActor func siteLimitIsEnforced() {
        let model = makeModel()
        for index in 0..<ServerModel.maxSites { model.addSite(name: "", host: "h\(index).com", port: 443) }
        model.addSite(name: "", host: "fazla.com", port: 443)
        #expect(model.sites.count == ServerModel.maxSites)
        #expect(model.errorText != nil)
    }

    @Test @MainActor func editedSiteKeepsItsIdAndOrder() {
        let model = makeModel()
        model.addSite(name: "a", host: "a.com", port: 443)
        model.addSite(name: "b", host: "b.com", port: 443)
        let first = model.sites[0]
        #expect(model.updateSite(id: first.id, name: "Yeni", host: "c.com", port: 8443))
        #expect(model.sites.map(\.id) == [first.id, model.sites[1].id])
        #expect(model.sites[0].host == "c.com")
        #expect(model.sites[0].port == 8443)
        #expect(model.errorText == nil)
    }

    @Test @MainActor func editIntoAnExistingSiteIsRefused() {
        let model = makeModel()
        model.addSite(name: "a", host: "a.com", port: 443)
        model.addSite(name: "b", host: "b.com", port: 443)
        #expect(!model.updateSite(id: model.sites[0].id, name: "a", host: "B.com", port: 443))
        #expect(model.sites[0].host == "a.com")
        #expect(model.errorText != nil)
    }

    @Test @MainActor func editWithoutChangingHostIsNotADuplicate() {
        let model = makeModel()
        model.addSite(name: "a", host: "a.com", port: 443)
        #expect(model.updateSite(id: model.sites[0].id, name: "Yeni ad", host: "a.com", port: 443))
        #expect(model.sites[0].name == "Yeni ad")
    }

    @Test @MainActor func invalidEditLeavesTheSiteUnchanged() {
        let model = makeModel()
        model.addSite(name: "a", host: "a.com", port: 443)
        #expect(!model.updateSite(id: model.sites[0].id, name: "a", host: "https://x.com", port: 443))
        #expect(!model.updateSite(id: "yok", name: "a", host: "x.com", port: 443))
        #expect(model.sites[0].host == "a.com")
    }

    @Test @MainActor func editedSiteIsPersisted() {
        let defaults = makeDefaults()
        let model = makeModel(defaults: defaults)
        model.addSite(name: "a", host: "a.com", port: 443)
        _ = model.updateSite(id: model.sites[0].id, name: "a", host: "z.com", port: 443)
        #expect(makeModel(defaults: defaults).sites.map(\.host) == ["z.com"])
    }
}

struct NetworkProberTests {
    @Test func closedLocalPortIsReportedAsUnreachable() async {
        let site = ServerSite.make(name: "yerel", host: "localhost", port: 9)!
        let result = await NetworkProber(timeout: 3).probe(site)
        #expect(!result.reachable)
        #expect(result.error != nil)
        #expect(result.httpStatus == nil)
    }
}
