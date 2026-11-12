import Foundation
import Testing
@testable import Nobet

struct PollBackoffTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)
    private let network = SSHFailure(message: "Zaman aşımı.")
    private let auth = SSHFailure(message: "Kimlik doğrulama başarısız.", authentication: true)

    @Test func freshStateNeverSkips() {
        #expect(!PollBackoff().shouldSkip(now: t0))
    }

    @Test func networkFailuresWaitFiveTenTwentyAndFortyMinutes() {
        var state = PollBackoff()
        let expected: [TimeInterval] = [300, 600, 1200, 2400, 2400]
        for delay in expected {
            state.recordFailure(network, now: t0)
            #expect(state.retryAt == t0.addingTimeInterval(delay))
        }
    }

    @Test func skipsOnlyUntilTheRetryTime() {
        var state = PollBackoff()
        state.recordFailure(network, now: t0)
        state.recordFailure(network, now: t0)
        #expect(state.shouldSkip(now: t0.addingTimeInterval(599)))
        #expect(!state.shouldSkip(now: t0.addingTimeInterval(600)))
    }

    @Test func authenticationFailureBlocksUntilReset() {
        var state = PollBackoff()
        state.recordFailure(auth, now: t0)
        #expect(state.blocked)
        #expect(state.shouldSkip(now: t0.addingTimeInterval(86_400 * 30)))
        state = PollBackoff()
        #expect(!state.shouldSkip(now: t0))
    }

    @Test func successClearsEverything() {
        var state = PollBackoff()
        state.recordFailure(network, now: t0)
        state.recordFailure(auth, now: t0)
        state.recordSuccess()
        #expect(state == PollBackoff())
    }

    @Test func permissionDeniedIsAnAuthenticationFailure() {
        guard case .failure(let failure) = SSHRunner.interpret(status: 255, stdout: "", stderr: "root@a: Permission denied (publickey).") else {
            Issue.record("Hata bekleniyordu"); return
        }
        #expect(failure.authentication)
    }

    @Test func timeoutAndRefusalAreNotAuthenticationFailures() {
        for text in ["Connection timed out", "Connection refused", "Could not resolve hostname"] {
            guard case .failure(let failure) = SSHRunner.interpret(status: 255, stdout: "", stderr: text) else {
                Issue.record("Hata bekleniyordu"); return
            }
            #expect(!failure.authentication)
        }
    }
}

/// Çağrı sayısını sayan sahte toplayıcı.
private final class CountingCollector: RemoteCollecting, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var stored: Result<RemoteMetrics, SSHFailure>

    init(_ result: Result<RemoteMetrics, SSHFailure>) { stored = result }

    var calls: Int { lock.withLock { count } }

    func resetCalls() { lock.withLock { count = 0 } }

    var result: Result<RemoteMetrics, SSHFailure> {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }

    func collect(_ profile: SSHProfile, password: String?) async -> Result<RemoteMetrics, SSHFailure> {
        lock.withLock {
            count += 1
            return stored
        }
    }
}

/// Zamanı elle ilerleten saat.
private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date(timeIntervalSince1970: 1_000_000)

    var now: Date { lock.withLock { current } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

struct RemoteBackoffModelTests {
    private let okMetrics = RemoteMetrics(disks: [DiskUsage(mount: "/", usedPercent: 10)], memory: nil, load: nil, cores: nil,
                                          uptimeSeconds: nil, services: [:], failedUnits: [])
    private let authFailure = SSHFailure(message: "Kimlik doğrulama başarısız.", authentication: true)
    private let timeout = SSHFailure(message: "Zaman aşımı.")

    /// `addProfile` kendiliğinden bir yoklama başlatır. Bu yoklama bitene kadar beklenir ve sayaç sıfırlanır.
    /// Toplayıcı başta başarılı yanıt verir, böylece ilk yoklama bekleme durumu bırakmaz.
    @MainActor
    private func makeModel(_ collector: CountingCollector, clock: TestClock = TestClock()) async -> RemoteModel {
        let name = "nobet-backoff-\(UUID().uuidString)"
        let defaults = TestDefaults.make(name)
        defaults.removePersistentDomain(forName: name)
        let model = RemoteModel(nobet: NobetModel(), defaults: defaults, secrets: FakeSecrets(), collector: collector, now: { clock.now })
        model.addProfile(name: "", host: "a.example.com", port: 22, user: "deploy", auth: .key, services: [], password: "")
        while model.checking || !model.checked { await Task.yield() }
        collector.resetCalls()
        return model
    }

    @Test @MainActor func pollingStopsAfterAnAuthenticationFailure() async {
        let collector = CountingCollector(.success(okMetrics))
        let model = await makeModel(collector)
        collector.result = .failure(authFailure)
        await model.checkAll(respectingBackoff: true)
        await model.checkAll(respectingBackoff: true)
        await model.checkAll(respectingBackoff: true)
        #expect(collector.calls == 1)
    }

    @Test @MainActor func blockedServerKeepsItsFailureVisible() async throws {
        let collector = CountingCollector(.success(okMetrics))
        let model = await makeModel(collector)
        collector.result = .failure(authFailure)
        await model.checkAll(respectingBackoff: true)
        await model.checkAll(respectingBackoff: true)
        let profile = try #require(model.profiles.first)
        let issue = try #require(model.issues(for: profile).first)
        #expect(issue.detail.contains("Yoklama durdu"))
    }

    @Test @MainActor func manualCheckRetriesABlockedServer() async {
        let collector = CountingCollector(.success(okMetrics))
        let model = await makeModel(collector)
        collector.result = .failure(authFailure)
        await model.checkAll(respectingBackoff: true)
        collector.result = .success(okMetrics)
        await model.checkAll()
        #expect(collector.calls == 2)
        await model.checkAll(respectingBackoff: true)
        #expect(collector.calls == 3)
    }

    @Test @MainActor func networkFailureWaitsBeforeTheNextAutomaticTry() async {
        let collector = CountingCollector(.success(okMetrics))
        let clock = TestClock()
        let model = await makeModel(collector, clock: clock)
        collector.result = .failure(timeout)
        await model.checkAll(respectingBackoff: true)
        clock.advance(120)
        await model.checkAll(respectingBackoff: true)
        #expect(collector.calls == 1)
        clock.advance(200)
        await model.checkAll(respectingBackoff: true)
        #expect(collector.calls == 2)
    }

    @Test @MainActor func successResetsTheWait() async {
        let collector = CountingCollector(.success(okMetrics))
        let clock = TestClock()
        let model = await makeModel(collector, clock: clock)
        collector.result = .failure(timeout)
        await model.checkAll(respectingBackoff: true)
        clock.advance(400)
        collector.result = .success(okMetrics)
        await model.checkAll(respectingBackoff: true)
        await model.checkAll(respectingBackoff: true)
        #expect(collector.calls == 3)
    }

    @Test @MainActor func editingAProfileClearsItsBlock() async throws {
        let collector = CountingCollector(.success(okMetrics))
        let model = await makeModel(collector)
        collector.result = .failure(authFailure)
        await model.checkAll(respectingBackoff: true)
        let profile = try #require(model.profiles.first)
        collector.result = .success(okMetrics)
        model.updateProfile(id: profile.id, name: "", host: profile.host, port: 22, user: "deploy", auth: .key, services: [],
                            thresholds: nil, password: "")
        while model.checking { await Task.yield() }
        let before = collector.calls
        await model.checkAll(respectingBackoff: true)
        #expect(collector.calls == before + 1)
    }
}
