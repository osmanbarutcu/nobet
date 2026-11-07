import Foundation
import Testing
@testable import Nobet

private func metrics(disk: Int) -> RemoteMetrics {
    RemoteMetrics(disks: [DiskUsage(mount: "/", usedPercent: disk)], memory: nil, load: nil, cores: nil,
                  uptimeSeconds: nil, services: [:], failedUnits: [])
}

struct RemoteEditTests {
    private func makeDefaults() -> UserDefaults {
        let name = "nobet-edit-test-\(UUID().uuidString)"
        let defaults = TestDefaults.make(name)
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @MainActor
    private func makeModel(secrets: SecretStoring, defaults: UserDefaults? = nil) -> RemoteModel {
        RemoteModel(nobet: NobetModel(), defaults: defaults ?? makeDefaults(), secrets: secrets, collector: FakeCollector(results: [:]))
    }

    @MainActor
    private func seeded(_ secrets: FakeSecrets) -> (RemoteModel, SSHProfile, SSHProfile) {
        let model = makeModel(secrets: secrets)
        model.addProfile(name: "A", host: "a.com", port: 22, user: "root", auth: .password, services: ["nginx"], password: "eski-parola")
        model.addProfile(name: "B", host: "b.com", port: 22, user: "root", auth: .key, services: [], password: "")
        return (model, model.profiles[0], model.profiles[1])
    }

    @Test @MainActor func editKeepsIdAndOrderAndKeepsThePasswordWhenEmpty() {
        let secrets = FakeSecrets()
        let (model, a, _) = seeded(secrets)
        let ok = model.updateProfile(id: a.id, name: "Yeni ad", host: "a.com", port: 2222, user: "root", auth: .password,
                                     services: ["nginx", "mariadb"], thresholds: nil, password: "")
        #expect(ok)
        #expect(model.profiles.map(\.id) == [a.id, model.profiles[1].id])
        #expect(model.profiles[0].name == "Yeni ad")
        #expect(model.profiles[0].port == 2222)
        #expect(model.profiles[0].services == ["nginx", "mariadb"])
        #expect(String(decoding: secrets.items[a.id] ?? Data(), as: UTF8.self) == "eski-parola")
    }

    @Test @MainActor func editWithANewPasswordReplacesIt() {
        let secrets = FakeSecrets()
        let (model, a, _) = seeded(secrets)
        #expect(model.updateProfile(id: a.id, name: "A", host: "a.com", port: 22, user: "root", auth: .password,
                                    services: [], thresholds: nil, password: "yeni-parola"))
        #expect(String(decoding: secrets.items[a.id] ?? Data(), as: UTF8.self) == "yeni-parola")
    }

    @Test @MainActor func switchingToKeyAuthDeletesTheStoredPassword() {
        let secrets = FakeSecrets()
        let (model, a, _) = seeded(secrets)
        #expect(model.updateProfile(id: a.id, name: "A", host: "a.com", port: 22, user: "root", auth: .key,
                                    services: [], thresholds: nil, password: ""))
        #expect(secrets.items[a.id] == nil)
    }

    @Test @MainActor func switchingToPasswordWithoutAnyPasswordIsRefused() {
        let secrets = FakeSecrets()
        let (model, _, b) = seeded(secrets)
        #expect(!model.updateProfile(id: b.id, name: "B", host: "b.com", port: 22, user: "root", auth: .password,
                                     services: [], thresholds: nil, password: ""))
        #expect(model.profiles[1].auth == .key)
        #expect(model.errorText != nil)
    }

    @Test @MainActor func editingIntoAnExistingServerIsRefused() {
        let (model, a, _) = seeded(FakeSecrets())
        #expect(!model.updateProfile(id: a.id, name: "A", host: "b.com", port: 22, user: "root", auth: .password,
                                     services: [], thresholds: nil, password: ""))
        #expect(model.profiles[0].host == "a.com")
        #expect(model.errorText != nil)
    }

    @Test @MainActor func keychainFailureLeavesTheProfileUnchanged() {
        let secrets = FakeSecrets()
        let (model, a, _) = seeded(secrets)
        secrets.failOnSet = true
        #expect(!model.updateProfile(id: a.id, name: "Değişti", host: "a.com", port: 22, user: "root", auth: .password,
                                     services: [], thresholds: nil, password: "x"))
        #expect(model.profiles[0].name == "A")
    }

    @Test @MainActor func unknownIdIsRefused() {
        let (model, _, _) = seeded(FakeSecrets())
        #expect(!model.updateProfile(id: "yok", name: "A", host: "z.com", port: 22, user: "root", auth: .key,
                                     services: [], thresholds: nil, password: ""))
    }

    @Test func invalidThresholdsAreRefused() {
        let bad = ServerThresholds(diskMedium: 95, diskHigh: 90, memoryLowPercent: 10, loadPerCore: 2)
        #expect(!bad.isValid)
        #expect(SSHProfile.make(name: "", host: "a.com", port: 22, user: "root", auth: .key, services: [], thresholds: bad) == nil)
        #expect(!ServerThresholds(diskMedium: 0, diskHigh: 90, memoryLowPercent: 10, loadPerCore: 2).isValid)
        #expect(!ServerThresholds(diskMedium: 80, diskHigh: 101, memoryLowPercent: 10, loadPerCore: 2).isValid)
        #expect(!ServerThresholds(diskMedium: 80, diskHigh: 90, memoryLowPercent: 10, loadPerCore: 0).isValid)
        #expect(ServerThresholds.standard.isValid)
    }

    @Test func customThresholdsChangeWhatCountsAsAnIssue() {
        let relaxed = ServerThresholds(diskMedium: 90, diskHigh: 97, memoryLowPercent: 10, loadPerCore: 2)
        #expect(RemoteHealth.issues(for: metrics(disk: 85)).count == 1)
        #expect(RemoteHealth.issues(for: metrics(disk: 85), thresholds: relaxed).isEmpty)
        let strict = ServerThresholds(diskMedium: 50, diskHigh: 60, memoryLowPercent: 10, loadPerCore: 2)
        #expect(RemoteHealth.issues(for: metrics(disk: 65), thresholds: strict).first?.severity == .high)
    }

    @Test @MainActor func modelUsesTheProfileThresholds() async {
        let secrets = FakeSecrets()
        let collector = FakeCollector(results: ["a.com": .success(metrics(disk: 85))])
        let model = RemoteModel(nobet: NobetModel(), defaults: makeDefaults(), secrets: secrets, collector: collector)
        model.addProfile(name: "A", host: "a.com", port: 22, user: "root", auth: .key, services: [], password: "")
        await model.checkAll()
        #expect(model.issues(for: model.profiles[0]).count == 1)
        let relaxed = ServerThresholds(diskMedium: 90, diskHigh: 97, memoryLowPercent: 10, loadPerCore: 2)
        #expect(model.updateProfile(id: model.profiles[0].id, name: "A", host: "a.com", port: 22, user: "root", auth: .key,
                                    services: [], thresholds: relaxed, password: ""))
        await model.checkAll()
        #expect(model.issues(for: model.profiles[0]).isEmpty)
    }

    @Test func profilesSavedBeforeThresholdsStillDecode() throws {
        let old = #"{"id":"1","name":"A","host":"a.com","port":22,"user":"root","auth":"key","services":[]}"#
        let profile = try JSONDecoder().decode(SSHProfile.self, from: Data(old.utf8))
        #expect(profile.thresholds == nil)
    }
}
