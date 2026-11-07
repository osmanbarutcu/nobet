import Foundation
import Testing
@testable import Nobet

struct SecretsModelTests {
    /// Her test kendi ayar paketini kullanır. Gerçek ayarlara dokunulmaz.
    private func makeDefaults() -> UserDefaults {
        let name = "nobet-test-\(UUID().uuidString)"
        let defaults = TestDefaults.make(name)
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @MainActor
    private func makeModel(nobet: NobetModel? = nil, defaults: UserDefaults? = nil, home: String = "/Users/test") -> SecretsModel {
        SecretsModel(nobet: nobet ?? NobetModel(), defaults: defaults ?? makeDefaults(), home: home)
    }

    private func finding(_ severity: Severity, _ path: String) -> SecretFinding {
        SecretFinding(kind: .envTracked, severity: severity, path: path, detail: "")
    }

    @Test @MainActor func applyingFindingsPublishesHighAndMediumAsAlerts() {
        let nobet = NobetModel()
        let model = makeModel(nobet: nobet)
        model.apply([finding(.high, "a"), finding(.medium, "b"), finding(.info, "c")])
        #expect(nobet.alertCount == 2)
        #expect(model.scanned)
        #expect(model.findings.count == 3)
    }

    @Test @MainActor func newScanReplacesTheOldAlertCount() {
        let nobet = NobetModel()
        let model = makeModel(nobet: nobet)
        model.apply([finding(.high, "a"), finding(.high, "b")])
        model.apply([])
        #expect(nobet.alertCount == 0)
    }

    @Test @MainActor func homeFolderIsAlwaysTheFirstRoot() {
        let model = makeModel(home: "/Users/test")
        #expect(model.roots == ["/Users/test"])
    }

    @Test @MainActor func addedFolderIsPersistedAndListed() throws {
        let defaults = makeDefaults()
        let tree = NSTemporaryDirectory() + "nobet-folder-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tree) }

        let model = makeModel(defaults: defaults)
        model.addFolder(tree)
        #expect(model.folders == [tree])
        #expect(model.roots == ["/Users/test", tree])

        let reloaded = makeModel(defaults: defaults)
        #expect(reloaded.folders == [tree])
    }

    @Test @MainActor func missingFolderIsRefusedWithAMessage() {
        let model = makeModel()
        model.addFolder("/yok/boyle/bir/klasor")
        #expect(model.folders.isEmpty)
        #expect(model.errorText != nil)
    }

    @Test @MainActor func aFileIsRefusedAsFolder() throws {
        let file = NSTemporaryDirectory() + "nobet-file-\(UUID().uuidString)"
        FileManager.default.createFile(atPath: file, contents: Data("x".utf8))
        defer { try? FileManager.default.removeItem(atPath: file) }
        let model = makeModel()
        model.addFolder(file)
        #expect(model.folders.isEmpty)
        #expect(model.errorText != nil)
    }

    @Test @MainActor func duplicateFolderIsAddedOnce() throws {
        let tree = NSTemporaryDirectory() + "nobet-folder-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tree) }
        let model = makeModel()
        model.addFolder(tree)
        model.addFolder(tree)
        #expect(model.folders.count == 1)
    }

    @Test @MainActor func removingAFolderPersists() throws {
        let defaults = makeDefaults()
        let tree = NSTemporaryDirectory() + "nobet-folder-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tree) }
        let model = makeModel(defaults: defaults)
        model.addFolder(tree)
        model.removeFolder(tree)
        #expect(model.folders.isEmpty)
        #expect(makeModel(defaults: defaults).folders.isEmpty)
    }

    @Test @MainActor func addingTheHomeFolderAgainIsIgnored() {
        let model = makeModel(home: NSTemporaryDirectory())
        model.addFolder(NSTemporaryDirectory())
        #expect(model.folders.isEmpty)
    }

    @Test @MainActor func ignoredFindingDisappearsFromListAndCount() {
        let nobet = NobetModel()
        let model = makeModel(nobet: nobet)
        let a = finding(.high, "/p/a/.env"), b = finding(.high, "/p/b/.env")
        model.apply([a, b])
        model.ignore(a)
        #expect(model.findings == [b])
        #expect(nobet.alertCount == 1)
        #expect(model.ignoredFindings == [a])
    }

    @Test @MainActor func ignoreSurvivesARescanAndARestart() {
        let defaults = makeDefaults()
        let model = makeModel(defaults: defaults)
        let a = finding(.high, "/p/a/.env")
        model.apply([a])
        model.ignore(a)
        model.apply([a])
        #expect(model.findings.isEmpty)
        let restarted = makeModel(defaults: defaults)
        restarted.apply([a])
        #expect(restarted.findings.isEmpty)
    }

    @Test @MainActor func unignoreBringsTheFindingBack() {
        let nobet = NobetModel()
        let model = makeModel(nobet: nobet)
        let a = finding(.high, "/p/a/.env")
        model.apply([a])
        model.ignore(a)
        model.unignore(a)
        #expect(model.findings == [a])
        #expect(nobet.alertCount == 1)
    }

    @Test @MainActor func storedIgnoreHoldsNoPath() {
        let defaults = makeDefaults()
        let model = makeModel(defaults: defaults)
        let a = finding(.high, "/Users/secret-name/proje/.env")
        model.apply([a])
        model.ignore(a)
        let saved = (defaults.stringArray(forKey: SecretsModel.ignoredKey) ?? []).joined()
        #expect(!saved.isEmpty)
        #expect(!saved.contains("secret-name"))
    }

    @Test @MainActor func addingAFolderStartsARescanWhenAutoRescanIsOn() throws {
        let tree = NSTemporaryDirectory() + "nobet-auto-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tree) }
        let model = SecretsModel(nobet: NobetModel(), defaults: makeDefaults(), home: "/Users/test", autoRescan: true)
        model.addFolder(tree)
        #expect(model.scanning)
    }

    @Test @MainActor func addingAFolderDoesNotScanByDefault() throws {
        let tree = NSTemporaryDirectory() + "nobet-auto-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: tree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: tree) }
        let model = makeModel()
        model.addFolder(tree)
        #expect(!model.scanning)
    }
}
