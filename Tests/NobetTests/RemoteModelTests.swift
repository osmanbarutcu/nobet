import Foundation
import Testing
@testable import Nobet

/// Gerçek Anahtar Zinciri'ne dokunmayan bellek içi depo.
final class FakeSecrets: SecretStoring, @unchecked Sendable {
    var items: [String: Data] = [:]
    var failOnSet = false

    func set(_ secret: Data, account: String) throws {
        if failOnSet { throw KeychainError.status(-25293) }
        items[account] = secret
    }

    func get(account: String) throws -> Data? { items[account] }
    func delete(account: String) throws { items[account] = nil }
}

/// Ağa çıkmayan sahte toplayıcı. Gelen parolayı kaydeder.
final class FakeCollector: RemoteCollecting, @unchecked Sendable {
    var results: [String: Result<RemoteMetrics, SSHFailure>]
    private let lock = NSLock()
    private var received: [String: String?] = [:]

    var passwords: [String: String?] {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    init(results: [String: Result<RemoteMetrics, SSHFailure>]) { self.results = results }

    func collect(_ profile: SSHProfile, password: String?) async -> Result<RemoteMetrics, SSHFailure> {
        lock.lock()
        received[profile.host] = password
        lock.unlock()
        return results[profile.host] ?? .failure(SSHFailure(message: "sahte"))
    }
}

private let healthy = RemoteMetrics(disks: [DiskUsage(mount: "/", usedPercent: 40)], memory: nil, load: nil, cores: nil,
                                    uptimeSeconds: nil, services: [:], failedUnits: [])
private let diskFull = RemoteMetrics(disks: [DiskUsage(mount: "/", usedPercent: 95)], memory: nil, load: nil, cores: nil,
                                     uptimeSeconds: nil, services: [:], failedUnits: [])

struct RemoteModelTests {
    private func makeDefaults() -> UserDefaults {
        let name = "nobet-remote-test-\(UUID().uuidString)"
        let defaults = TestDefaults.make(name)
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @MainActor
    private func makeModel(nobet: NobetModel? = nil, defaults: UserDefaults? = nil, secrets: SecretStoring? = nil,
                           collector: RemoteCollecting? = nil) -> RemoteModel {
        RemoteModel(nobet: nobet ?? NobetModel(), defaults: defaults ?? makeDefaults(), secrets: secrets ?? FakeSecrets(),
                    collector: collector ?? FakeCollector(results: [:]))
    }

    @Test @MainActor func passwordProfileStoresThePasswordInTheKeychainOnly() throws {
        let secrets = FakeSecrets()
        let defaults = makeDefaults()
        let model = makeModel(defaults: defaults, secrets: secrets)
        model.addProfile(name: "Üretim", host: "a.com", port: 22, user: "root", auth: .password, services: ["nginx"], password: "gizli-parola-1")
        let profile = try #require(model.profiles.first)
        #expect(String(decoding: try #require(secrets.items[profile.id]), as: UTF8.self) == "gizli-parola-1")
        let saved = String(decoding: defaults.data(forKey: RemoteModel.profilesKey) ?? Data(), as: UTF8.self)
        #expect(!saved.contains("gizli-parola-1"))
        #expect(model.errorText == nil)
    }

    @Test @MainActor func passwordProfileWithoutPasswordIsRefused() {
        let model = makeModel()
        model.addProfile(name: "", host: "a.com", port: 22, user: "root", auth: .password, services: [], password: "")
        #expect(model.profiles.isEmpty)
        #expect(model.errorText != nil)
    }

    @Test @MainActor func keychainFailureLeavesNoProfileBehind() {
        let secrets = FakeSecrets()
        secrets.failOnSet = true
        let model = makeModel(secrets: secrets)
        model.addProfile(name: "", host: "a.com", port: 22, user: "root", auth: .password, services: [], password: "x")
        #expect(model.profiles.isEmpty)
        #expect(model.errorText != nil)
    }

    @Test @MainActor func keyProfileNeedsNoPassword() {
        let model = makeModel()
        model.addProfile(name: "", host: "a.com", port: 22, user: "deploy", auth: .key, services: [], password: "")
        #expect(model.profiles.count == 1)
    }

    @Test @MainActor func invalidInputIsRefused() {
        let model = makeModel()
        model.addProfile(name: "", host: "ssh://a.com", port: 22, user: "root", auth: .key, services: [], password: "")
        #expect(model.profiles.isEmpty)
        #expect(model.errorText != nil)
    }

    @Test @MainActor func duplicateHostUserPortIsRefused() {
        let model = makeModel()
        model.addProfile(name: "a", host: "a.com", port: 22, user: "root", auth: .key, services: [], password: "")
        model.addProfile(name: "b", host: "A.com", port: 22, user: "root", auth: .key, services: [], password: "")
        #expect(model.profiles.count == 1)
        #expect(model.errorText != nil)
    }

    @Test @MainActor func profilesSurviveReload() {
        let defaults = makeDefaults()
        makeModel(defaults: defaults).addProfile(name: "a", host: "a.com", port: 22, user: "root", auth: .key, services: ["nginx"], password: "")
        #expect(makeModel(defaults: defaults).profiles.first?.services == ["nginx"])
    }

    @Test @MainActor func checkAllPassesThePasswordAndPublishesAlerts() async throws {
        let nobet = NobetModel()
        let secrets = FakeSecrets()
        let collector = FakeCollector(results: ["a.com": .success(diskFull), "b.com": .success(healthy)])
        let model = makeModel(nobet: nobet, secrets: secrets, collector: collector)
        model.addProfile(name: "a", host: "a.com", port: 22, user: "root", auth: .password, services: [], password: "pw-a")
        model.addProfile(name: "b", host: "b.com", port: 22, user: "deploy", auth: .key, services: [], password: "")
        await model.checkAll()
        #expect(collector.passwords["a.com"] == "pw-a")
        #expect(collector.passwords["b.com"] == .some(nil))
        #expect(nobet.alerts["remote"] == 1)
        #expect(model.issues(for: model.profiles[0]).first?.severity == .high)
        #expect(model.issues(for: model.profiles[1]).isEmpty)
    }

    @Test @MainActor func connectionFailureIsAHighAlert() async {
        let nobet = NobetModel()
        let collector = FakeCollector(results: ["a.com": .failure(SSHFailure(message: "Zaman aşımı."))])
        let model = makeModel(nobet: nobet, collector: collector)
        model.addProfile(name: "a", host: "a.com", port: 22, user: "root", auth: .key, services: [], password: "")
        await model.checkAll()
        let issue = model.issues(for: model.profiles[0]).first
        #expect(issue?.severity == .high)
        #expect(issue?.detail == "Zaman aşımı.")
        #expect(nobet.alerts["remote"] == 1)
    }

    @Test @MainActor func missingKeychainPasswordIsReportedWithoutConnecting() async {
        let secrets = FakeSecrets()
        let collector = FakeCollector(results: ["a.com": .success(healthy)])
        let model = makeModel(secrets: secrets, collector: collector)
        model.addProfile(name: "a", host: "a.com", port: 22, user: "root", auth: .password, services: [], password: "pw")
        secrets.items.removeAll()
        await model.checkAll()
        #expect(collector.passwords.isEmpty)
        #expect(model.issues(for: model.profiles[0]).first?.detail.contains("Anahtar Zinciri") == true)
    }

    @Test @MainActor func removingAProfileDeletesItsSecretAndAlert() async {
        let nobet = NobetModel()
        let secrets = FakeSecrets()
        let collector = FakeCollector(results: ["a.com": .success(diskFull)])
        let model = makeModel(nobet: nobet, secrets: secrets, collector: collector)
        model.addProfile(name: "a", host: "a.com", port: 22, user: "root", auth: .password, services: [], password: "pw")
        await model.checkAll()
        let profile = model.profiles[0]
        model.removeProfile(profile)
        #expect(model.profiles.isEmpty)
        #expect(secrets.items[profile.id] == nil)
        #expect(nobet.alertCount == 0)
    }

    @Test @MainActor func profileLimitIsEnforced() {
        let model = makeModel()
        for index in 0..<RemoteModel.maxProfiles {
            model.addProfile(name: "", host: "h\(index).com", port: 22, user: "root", auth: .key, services: [], password: "")
        }
        model.addProfile(name: "", host: "fazla.com", port: 22, user: "root", auth: .key, services: [], password: "")
        #expect(model.profiles.count == RemoteModel.maxProfiles)
        #expect(model.errorText != nil)
    }
}

struct SSHRunnerPureTests {
    private let password = SSHProfile.make(name: "a", host: "a.com", port: 22, user: "root", auth: .password, services: [])!
    private let key = SSHProfile.make(name: "a", host: "a.com", port: 22, user: "deploy", auth: .key, services: [])!

    @Test func passwordAuthSetsAskpassEnvironment() {
        let env = SSHRunner.environment(for: password, password: "pw", askpassPath: "/app/Nobet", base: ["PATH": "/usr/bin"])
        #expect(env["SSH_ASKPASS"] == "/app/Nobet")
        #expect(env["SSH_ASKPASS_REQUIRE"] == "force")
        #expect(env["NOBET_ASKPASS"] == "1")
        #expect(env["NOBET_PW"] == "pw")
        #expect(env["PATH"] == "/usr/bin")
    }

    @Test func keyAuthNeverCarriesAPassword() {
        let env = SSHRunner.environment(for: key, password: "pw", askpassPath: "/app/Nobet", base: ["NOBET_PW": "kalinti"])
        #expect(env["NOBET_PW"] == nil)
        #expect(env["NOBET_ASKPASS"] == nil)
        #expect(env["SSH_ASKPASS"] == nil)
    }

    @Test func successfulOutputBecomesMetrics() {
        let output = "#df\nFilesystem 1024-blocks Used Available Capacity Mounted on\n/dev/sda1 100 50 50 50% /\n#nproc\n2\n"
        let result = SSHRunner.interpret(status: 0, stdout: output, stderr: "")
        #expect((try? result.get())?.cores == 2)
    }

    @Test func unparseableOutputIsAClearFailure() {
        let result = SSHRunner.interpret(status: 0, stdout: "merhaba", stderr: "")
        guard case .failure(let failure) = result else { Issue.record("Hata bekleniyordu"); return }
        #expect(failure.message.contains("Beklenmeyen"))
    }

    @Test func nonZeroStatusUsesTheErrorMapping() {
        let result = SSHRunner.interpret(status: 255, stdout: "", stderr: "root@a: Permission denied (password).")
        guard case .failure(let failure) = result else { Issue.record("Hata bekleniyordu"); return }
        #expect(failure.message.contains("Kimlik doğrulama"))
    }
}
