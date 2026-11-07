import Foundation
import Testing
@testable import Nobet

private final class Recorder: AlertNotifying {
    private(set) var sent: [AlertEvent] = []
    func notify(_ event: AlertEvent) { sent.append(event) }
}

private struct StubProber: ServerProbing {
    var result: ProbeResult
    func probe(_ site: ServerSite) async -> ProbeResult { result }
}

private let reachable = ProbeResult(reachable: true, httpStatus: 200, latencyMs: 100, certExpiry: nil, error: nil)
private let unreachable = ProbeResult(reachable: false, httpStatus: nil, latencyMs: nil, certExpiry: nil, error: "zaman aşımı")

@MainActor
private func makeCenter(_ recorder: Recorder) -> AlertCenter {
    let name = "nobet-wiring-test-\(UUID().uuidString)"
    let defaults = TestDefaults.make(name)
    defaults.removePersistentDomain(forName: name)
    defaults.set(false, forKey: AlertCenter.quietEnabledKey)
    return AlertCenter(defaults: defaults, notifier: recorder)
}

private func makeDefaults() -> UserDefaults {
    let name = "nobet-wiring-model-\(UUID().uuidString)"
    let defaults = TestDefaults.make(name)
    defaults.removePersistentDomain(forName: name)
    return defaults
}

struct AlertWiringTests {
    @Test @MainActor func siteGoingDownNotifiesOnceThenRecovers() async {
        let recorder = Recorder()
        let center = makeCenter(recorder)
        let model = ServerModel(nobet: NobetModel(), defaults: makeDefaults(), prober: StubProber(result: unreachable), alerts: center)
        model.addSite(name: "Ana", host: "a.com", port: 443)
        await model.checkAll()
        await model.checkAll()
        #expect(recorder.sent.map(\.kind) == [.started])
        #expect(recorder.sent.first?.issue.subject == "a.com")
        #expect(recorder.sent.first?.issue.routeIdentifier == "nobet.server")
    }

    @Test @MainActor func removingADownSiteResolvesItsAlert() async {
        let recorder = Recorder()
        let center = makeCenter(recorder)
        let model = ServerModel(nobet: NobetModel(), defaults: makeDefaults(), prober: StubProber(result: unreachable), alerts: center)
        model.addSite(name: "Ana", host: "a.com", port: 443)
        await model.checkAll()
        model.removeSite(model.sites[0])
        #expect(recorder.sent.map(\.kind) == [.started, .resolved])
        #expect(center.active.isEmpty)
    }

    @Test @MainActor func healthySiteStaysSilent() async {
        let recorder = Recorder()
        let model = ServerModel(nobet: NobetModel(), defaults: makeDefaults(), prober: StubProber(result: reachable), alerts: makeCenter(recorder))
        model.addSite(name: "Ana", host: "a.com", port: 443)
        await model.checkAll()
        #expect(recorder.sent.isEmpty)
    }

    @Test @MainActor func secretFindingAlertCarriesNoPath() {
        let recorder = Recorder()
        let model = SecretsModel(nobet: NobetModel(), defaults: makeDefaults(), home: "/h", alerts: makeCenter(recorder))
        model.apply([SecretFinding(kind: .envTracked, severity: .high, path: "/h/proje/.env", detail: "x")])
        let event = recorder.sent.first
        #expect(event?.issue.routeIdentifier == "nobet.secret")
        #expect(event?.issue.subject == "proje/.env")
        let text = [event?.notificationTitle, event?.notificationBody, event?.issue.key].compactMap { $0 }.joined()
        #expect(!text.contains("/h/proje"))
    }

    @Test @MainActor func infoSecretFindingStaysSilent() {
        let recorder = Recorder()
        let model = SecretsModel(nobet: NobetModel(), defaults: makeDefaults(), home: "/h", alerts: makeCenter(recorder))
        model.apply([SecretFinding(kind: .credentialFile, severity: .info, path: "/h/a", detail: "x")])
        #expect(recorder.sent.isEmpty)
    }

    @Test @MainActor func exposedDevPortNotifiesAndClosingResolves() {
        let recorder = Recorder()
        let model = DevModel(nobet: NobetModel(), alerts: makeCenter(recorder))
        let port = ListeningPort(pid: 1, process: "node", address: "*", port: 3000, scope: .all)
        let project = DevProject(name: "web", root: "/h/web", ports: [port], containers: [])
        model.apply(DevOverview(projects: [project], otherPorts: []))
        model.apply(DevOverview(projects: [DevProject(name: "web", root: "/h/web", ports: [], containers: [])], otherPorts: []))
        #expect(recorder.sent.map(\.kind) == [.started, .resolved])
        #expect(recorder.sent.first?.issue.subject == "web :3000")
    }
}
