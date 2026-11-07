import Foundation
import Testing
@testable import Nobet

final class FakeLister: PackageListing, @unchecked Sendable {
    var result: Result<[InstalledPackage], SSHFailure>
    private(set) var calls = 0
    private(set) var receivedPassword: String??

    init(_ result: Result<[InstalledPackage], SSHFailure>) { self.result = result }

    func packages(_ profile: SSHProfile, password: String?) async -> Result<[InstalledPackage], SSHFailure> {
        calls += 1
        receivedPassword = .some(password)
        return result
    }
}

struct PackageInventoryParserTests {
    @Test func parsesNameAndVersionSortedByName() {
        let text = "zlib1g 1:1.3-1\nbash 5.2.15-2\nopenssl 3.0.11-1\n"
        let items = PackageInventory.parse(text)
        #expect(items.map(\.name) == ["bash", "openssl", "zlib1g"])
        #expect(items[0].version == "5.2.15-2")
    }

    @Test func skipsBlankMalformedAndUnsafeLines() {
        let text = "\nsadece-ad\nok 1.0\nkötü;ad 1.0\nrm -rf 1\nbaşka 1.0 fazla\n"
        #expect(PackageInventory.parse(text).map(\.name) == ["ok"])
    }

    @Test func capsTheListAtTheLimit() {
        let text = (0..<(PackageInventory.limit + 50)).map { "p\($0) 1" }.joined(separator: "\n")
        #expect(PackageInventory.parse(text).count == PackageInventory.limit)
    }

    @Test func filterMatchesNameIgnoringCase() {
        let items = [InstalledPackage(name: "OpenSSL", version: "3"), InstalledPackage(name: "bash", version: "5")]
        #expect(PackageInventory.filter(items, text: "ssl").map(\.name) == ["OpenSSL"])
        #expect(PackageInventory.filter(items, text: "").count == 2)
    }
}

struct PackageCommandTests {
    @Test func commandOnlyListsPackagesAndStaysReadOnly() {
        let command = RemoteScript.packages
        #expect(command.contains("dpkg-query -W"))
        #expect(command.contains("rpm -qa"))
        for forbidden in ["rm ", "sudo", "apt ", "yum ", "dnf ", "install", "remove", "erase", "chmod", "kill", "> /", "systemctl"] {
            #expect(!command.contains(forbidden))
        }
    }
}

struct PackageInventoryModelTests {
    private func makeDefaults() -> UserDefaults {
        let name = "nobet-pkg-test-\(UUID().uuidString)"
        let defaults = TestDefaults.make(name)
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test @MainActor func loadStoresThePackagesForThatServerOnly() async throws {
        let lister = FakeLister(.success([InstalledPackage(name: "bash", version: "5")]))
        let model = RemoteModel(nobet: NobetModel(), defaults: makeDefaults(), secrets: FakeSecrets(),
                                collector: FakeCollector(results: [:]), lister: lister)
        model.addProfile(name: "a", host: "a.com", port: 22, user: "root", auth: .key, services: [], password: "")
        let profile = try #require(model.profiles.first)
        #expect(model.inventory[profile.id] == nil)
        await model.loadInventory(profile)
        #expect(model.inventory[profile.id]?.map(\.name) == ["bash"])
        #expect(lister.calls == 1)
        #expect(!model.loadingInventory.contains(profile.id))
    }

    @Test @MainActor func failureKeepsTheMessageAndNoList() async throws {
        let lister = FakeLister(.failure(SSHFailure(message: "Zaman aşımı.")))
        let model = RemoteModel(nobet: NobetModel(), defaults: makeDefaults(), secrets: FakeSecrets(),
                                collector: FakeCollector(results: [:]), lister: lister)
        model.addProfile(name: "a", host: "a.com", port: 22, user: "root", auth: .key, services: [], password: "")
        let profile = try #require(model.profiles.first)
        await model.loadInventory(profile)
        #expect(model.inventory[profile.id] == nil)
        #expect(model.inventoryErrors[profile.id] == "Zaman aşımı.")
    }

    @Test @MainActor func passwordProfileReadsThePasswordFromTheKeychain() async throws {
        let secrets = FakeSecrets()
        let lister = FakeLister(.success([]))
        let model = RemoteModel(nobet: NobetModel(), defaults: makeDefaults(), secrets: secrets,
                                collector: FakeCollector(results: [:]), lister: lister)
        model.addProfile(name: "a", host: "a.com", port: 22, user: "root", auth: .password, services: [], password: "gizli-1")
        let profile = try #require(model.profiles.first)
        await model.loadInventory(profile)
        #expect(lister.receivedPassword == .some("gizli-1"))
    }

    @Test @MainActor func missingPasswordFailsWithoutConnecting() async throws {
        let secrets = FakeSecrets()
        let lister = FakeLister(.success([]))
        let model = RemoteModel(nobet: NobetModel(), defaults: makeDefaults(), secrets: secrets,
                                collector: FakeCollector(results: [:]), lister: lister)
        model.addProfile(name: "a", host: "a.com", port: 22, user: "root", auth: .password, services: [], password: "gizli-1")
        let profile = try #require(model.profiles.first)
        try secrets.delete(account: profile.id)
        await model.loadInventory(profile)
        #expect(lister.calls == 0)
        #expect(model.inventoryErrors[profile.id] != nil)
    }

    @Test @MainActor func windowsServerNeverRunsThePackageCommand() async throws {
        let lister = FakeLister(.success([]))
        let model = RemoteModel(nobet: NobetModel(), defaults: makeDefaults(), secrets: FakeSecrets(),
                                collector: FakeCollector(results: [:]), lister: lister)
        model.addProfile(name: "w", host: "w.com", port: 22, user: "Administrator", auth: .key, services: [], platform: .windows, password: "")
        let profile = try #require(model.profiles.first)
        #expect(profile.isWindows)
        await model.loadInventory(profile)
        #expect(lister.calls == 0)
        #expect(model.inventoryErrors[profile.id] == "Paket listesi yalnızca Linux sunucularda okunur.")
    }
}
