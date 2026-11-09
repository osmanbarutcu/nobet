import Foundation
import Testing
@testable import Nobet

private final class NetRecorder: AlertNotifying {
    private(set) var sent: [AlertEvent] = []
    func notify(_ event: AlertEvent) { sent.append(event) }
}

private func makeDefaults() -> UserDefaults {
    let name = "nobet-network-test-\(UUID().uuidString)"
    let defaults = TestDefaults.make(name)
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@MainActor
private func makeCenter(_ recorder: NetRecorder) -> AlertCenter {
    let name = "nobet-network-center-test-\(UUID().uuidString)"
    let defaults = TestDefaults.make(name)
    defaults.removePersistentDomain(forName: name)
    defaults.set(false, forKey: AlertCenter.quietEnabledKey)
    return AlertCenter(defaults: defaults, notifier: recorder)
}

private func listener(
    _ process: String, pid: Int = 10, port: Int = 9000, scope: ListeningPort.Scope = .local,
    path: String? = nil, signature: SignatureStatus = .developer, project: Bool = false
) -> NetworkListener {
    NetworkListener(
        port: ListeningPort(pid: pid, process: process, address: scope == .all ? "*" : "127.0.0.1", port: port, scope: scope),
        identity: ProcessIdentity(path: path ?? "/opt/x/\(process)", signature: signature, suspiciousLocation: false),
        isProjectPort: project)
}

private func snapshot(_ listeners: [NetworkListener], connections: [NetworkConnection]? = nil) -> NetworkSnapshot {
    NetworkSnapshot(listeners: listeners, connections: connections)
}

struct NetworkModelTests {
    @MainActor
    private func makeModel(
        recorder: NetRecorder? = nil, defaults: UserDefaults? = nil, nobet: NobetModel? = nil
    ) -> (model: NetworkModel, recorder: NetRecorder, nobet: NobetModel, defaults: UserDefaults) {
        let recorder = recorder ?? NetRecorder()
        let defaults = defaults ?? makeDefaults()
        let nobet = nobet ?? NobetModel()
        let model = NetworkModel(nobet: nobet, defaults: defaults, alerts: makeCenter(recorder), home: "/h")
        return (model, recorder, nobet, defaults)
    }

    @Test @MainActor func firstScanLearnsSilently() {
        let env = makeModel()
        env.model.apply(snapshot([listener("a"), listener("b", pid: 11)]))
        #expect(env.recorder.sent.isEmpty)
        #expect(env.model.baseline.learned)
        #expect(env.model.loaded)
    }

    @Test @MainActor func newListenerAfterLearningNotifiesOnceAndKeepsRoute() {
        let env = makeModel()
        env.model.apply(snapshot([listener("a")]))
        env.model.apply(snapshot([listener("a"), listener("b", pid: 11)]))
        env.model.apply(snapshot([listener("a"), listener("b", pid: 11)]))
        #expect(env.recorder.sent.map(\.kind) == [.started])
        #expect(env.recorder.sent.first?.issue.subject == "b")
        #expect(env.recorder.sent.first?.issue.routeIdentifier == "nobet.net")
        #expect(env.nobet.alertCount == 1)
    }

    @Test @MainActor func trustingTheListenerResolvesItsAlert() {
        let env = makeModel()
        env.model.apply(snapshot([listener("a")]))
        let extra = listener("b", pid: 11)
        env.model.apply(snapshot([listener("a"), extra]))
        env.model.trust(extra)
        #expect(env.recorder.sent.map(\.kind) == [.started, .resolved])
        #expect(env.nobet.alertCount == 0)
        #expect(env.model.isTrusted(extra))
    }

    @Test @MainActor func untrustingBringsTheAlertBack() {
        let env = makeModel()
        env.model.apply(snapshot([listener("a")]))
        let extra = listener("b", pid: 11)
        env.model.apply(snapshot([listener("a"), extra]))
        env.model.trust(extra)
        env.model.untrust(extra)
        #expect(env.recorder.sent.map(\.kind) == [.started, .resolved, .started])
    }

    @Test @MainActor func alertCarriesNoPathAndNoPid() {
        let env = makeModel()
        env.model.apply(snapshot([listener("a")]))
        env.model.apply(snapshot([listener("a"), listener("agent", pid: 4242, path: "/Users/h/gizli/agent")]))
        let event = env.recorder.sent.first
        let text = [event?.notificationTitle, event?.notificationBody, event?.issue.key].compactMap { $0 }.joined()
        #expect(!text.contains("/Users"))
        #expect(!text.contains("4242"))
    }

    @Test @MainActor func projectPortsStaySilent() {
        let env = makeModel()
        env.model.apply(snapshot([listener("a")]))
        env.model.apply(snapshot([listener("a"), listener("web", pid: 12, port: 3000, scope: .all, signature: .unsigned, project: true)]))
        #expect(env.recorder.sent.isEmpty)
        #expect(env.nobet.alertCount == 0)
    }

    @Test @MainActor func exposedDeveloperSignedProcessNotifiesEvenOnFirstScan() {
        let env = makeModel()
        env.model.apply(snapshot([listener("sync", scope: .all)]))
        #expect(env.recorder.sent.first?.issue.title == "Sistem portu tüm ağa açık")
    }

    @Test @MainActor func baselineSurvivesARestart() {
        let defaults = makeDefaults()
        let first = makeModel(defaults: defaults)
        first.model.apply(snapshot([listener("a")]))
        let second = makeModel(defaults: defaults)
        second.model.apply(snapshot([listener("a"), listener("b", pid: 11)]))
        #expect(second.recorder.sent.map(\.issue.subject) == ["b"])
    }

    @Test @MainActor func baselineStoresNoNamesOrPaths() {
        let env = makeModel()
        env.model.apply(snapshot([listener("gizliajan", path: "/Users/h/gizli/gizliajan")]))
        let stored = (env.defaults.stringArray(forKey: NetworkBaselineStore.knownKey) ?? []).joined()
        #expect(!stored.contains("gizli"))
        #expect(!stored.contains("/"))
    }

    @Test @MainActor func resetStartsLearningAgainAndStaysQuiet() {
        let env = makeModel()
        env.model.apply(snapshot([listener("a")]))
        env.model.resetBaseline(rescan: false)
        #expect(!env.model.baseline.learned)
        env.model.apply(snapshot([listener("a"), listener("b", pid: 11)]))
        #expect(env.recorder.sent.isEmpty)
    }

    @Test @MainActor func connectionsUpdateOnlyWhenTheSnapshotCarriesThem() {
        let env = makeModel()
        let connection = NetworkConnection(pid: 5, process: "c", localPort: 50000, remoteHost: "192.0.2.10", remotePort: 443)
        env.model.apply(snapshot([listener("a")], connections: [connection]))
        env.model.apply(snapshot([listener("a")], connections: nil))
        #expect(env.model.connections == [connection])
    }

    @Test @MainActor func terminationNeedsConfirmationAndCanBeCancelled() {
        let env = makeModel()
        let target = listener("agent", pid: 4242)
        env.model.request(terminating: target)
        #expect(env.model.pending?.action == .terminate(pid: 4242))
        env.model.cancel()
        #expect(env.model.pending == nil)
    }

    @Test @MainActor func terminationRefusesPidOneAndOwnProcess() {
        let env = makeModel()
        env.model.request(terminating: listener("launchd", pid: 1))
        #expect(env.model.pending == nil)
        #expect(env.model.errorText != nil)
        env.model.request(terminating: listener("nobet", pid: Int(ProcessInfo.processInfo.processIdentifier)))
        #expect(env.model.pending == nil)
    }

    @Test func appleProcessTerminationCarriesAWarning() {
        let apple = NetworkTermination(action: .terminate(pid: 9), process: "rapportd", signature: .apple)
        let other = NetworkTermination(action: .terminate(pid: 9), process: "node", signature: .adHoc)
        #expect(apple.message.contains("Apple sistem süreci"))
        #expect(!other.message.contains("Apple sistem süreci"))
        #expect(apple.title == "Süreç sonlandırılacak: rapportd (PID 9)")
    }
}

struct NetworkSnapshotBuilderTests {
    private func port(_ pid: Int, _ number: Int = 3000) -> ListeningPort {
        ListeningPort(pid: pid, process: "p\(pid)", address: "*", port: number, scope: .all)
    }

    @Test func listenersInsideAProjectAreMarked() {
        let listeners = NetworkListener.build(
            ports: [port(1), port(2), port(3)],
            cwds: [1: "/h/web", 3: "/h"],
            home: "/h",
            identityOf: { _ in ProcessIdentity(path: nil, signature: .unknown, suspiciousLocation: false) },
            exists: { $0 == "/h/web/package.json" })
        #expect(listeners.map(\.isProjectPort) == [true, false, false])
    }

    @Test func buildKeepsPortOrder() {
        let listeners = NetworkListener.build(
            ports: [port(2, 80), port(1, 70)], cwds: [:], home: "/h",
            identityOf: { _ in ProcessIdentity(path: nil, signature: .unknown, suspiciousLocation: false) },
            exists: { _ in false })
        #expect(listeners.map(\.port.port) == [80, 70])
    }
}

struct NetworkHealthTests {
    private func item(scope: ListeningPort.Scope, signature: SignatureStatus = .developer, project: Bool = false) -> NetworkListener {
        listener("x", scope: scope, signature: signature, project: project)
    }

    @Test func countsListenersAndExposedNonProjectPorts() {
        let health = NetworkHealth(
            listeners: [item(scope: .all), item(scope: .local), item(scope: .all, project: true)], newKeys: [], trusted: [])
        #expect(health.listening == 3)
        #expect(health.exposed == 1)
    }

    @Test func healthyWhenNothingNeedsAttention() {
        let health = NetworkHealth(listeners: [item(scope: .local)], newKeys: [], trusted: [])
        #expect(health.level == .ok)
        #expect(health.headline == "Her şey yolunda")
    }

    @Test func warningNamesTheIssueCount() {
        let health = NetworkHealth(listeners: [item(scope: .all, signature: .unsigned)], newKeys: [], trusted: [])
        #expect(health.level == .warning)
        #expect(health.headline == "1 sorun var")
    }
}
