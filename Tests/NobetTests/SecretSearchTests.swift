import Foundation
import Testing
@testable import Nobet

struct SecretSearchTests {
    private func finding(_ kind: SecretKind, _ path: String, detail: String = "") -> SecretFinding {
        SecretFinding(kind: kind, severity: .info, path: path, detail: detail)
    }

    @Test func emptyQueryMatchesEverything() {
        #expect(SecretSearch.matches(finding(.envTracked, "/h/app/.env"), query: ""))
        #expect(SecretSearch.matches(finding(.envTracked, "/h/app/.env"), query: "   "))
    }

    @Test func findingMatchesPathTitleAndDetail() {
        let item = finding(.privateKeyPermissions, "/h/.ssh/id_ed25519", detail: "izin 644, beklenen 600")
        #expect(SecretSearch.matches(item, query: "id_ed25519"))
        #expect(SecretSearch.matches(item, query: "özel anahtar"))
        #expect(SecretSearch.matches(item, query: "644"))
        #expect(!SecretSearch.matches(item, query: "docker"))
    }

    @Test func searchIgnoresCaseAndTurkishLetters() {
        let item = finding(.unencryptedPrivateKey, "/h/.ssh/id_rsa")
        #expect(SecretSearch.matches(item, query: "PAROLASIZ"))
        #expect(SecretSearch.matches(item, query: "ozel anahtar"))
    }

    @Test func everyWordMustMatch() {
        let item = finding(.privateKeyPermissions, "/h/.ssh/id_rsa")
        #expect(SecretSearch.matches(item, query: "ssh rsa"))
        #expect(!SecretSearch.matches(item, query: "ssh ed25519"))
    }

    @Test func keyMatchesNameAndKeywords() {
        let key = SSHKeyInfo(path: "/h/.ssh/id_ed25519", mode: 0o600, isEncrypted: true)
        #expect(SecretSearch.matches(key, query: "ed25519"))
        #expect(SecretSearch.matches(key, query: "ssh key"))
        #expect(SecretSearch.matches(key, query: "parolalı"))
        #expect(!SecretSearch.matches(key, query: "parolasız"))
    }

    @Test func keysListOnlyPrivateKeysEvenWhenPermissionsAreGood() {
        let entries = [
            SSHEntry(path: "/h/.ssh/id_ed25519", mode: 0o600, head: "-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\n"),
            SSHEntry(path: "/h/.ssh/id_ed25519.pub", mode: 0o644, head: "ssh-ed25519 AAAA user@host"),
            SSHEntry(path: "/h/.ssh/known_hosts", mode: 0o644, head: "example.com ssh-ed25519 AAAA"),
        ]
        let keys = SSHAudit.keys(entries: entries)
        #expect(keys == [SSHKeyInfo(path: "/h/.ssh/id_ed25519", mode: 0o600, isEncrypted: true)])
    }

    @Test func keyInfoReportsNameAndLooseMode() {
        let key = SSHKeyInfo(path: "/h/.ssh/deploy", mode: 0o644, isEncrypted: false)
        #expect(key.name == "deploy")
        #expect(key.isLoose)
        #expect(!SSHKeyInfo(path: "/h/.ssh/a", mode: 0o600, isEncrypted: false).isLoose)
    }

    @Test @MainActor func modelKeepsKeysSeparateFromFindings() {
        let model = SecretsModel(nobet: NobetModel(), defaults: TestDefaults.make("nobet-test-\(UUID().uuidString)"), home: "/h")
        model.applyKeys([SSHKeyInfo(path: "/h/.ssh/id_rsa", mode: 0o600, isEncrypted: true)])
        #expect(model.sshKeys.count == 1)
        #expect(model.findings.isEmpty)
    }

    @Test func publicKeyLineAcceptsKnownTypesWithAComment() {
        #expect(PublicKey.line(from: "ssh-ed25519 AAAAC3Nza user@host\n") == "ssh-ed25519 AAAAC3Nza user@host")
        #expect(PublicKey.line(from: "ssh-rsa AAAAB3 kullanici") != nil)
        #expect(PublicKey.line(from: "ecdsa-sha2-nistp256 AAAAE2 x") != nil)
    }

    @Test func publicKeyLineRejectsPrivateKeysAndOtherText() {
        #expect(PublicKey.line(from: "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----") == nil)
        #expect(PublicKey.line(from: "ssh-ed25519 AAAA\n-----BEGIN RSA PRIVATE KEY-----") == nil)
        #expect(PublicKey.line(from: "merhaba dünya") == nil)
        #expect(PublicKey.line(from: "ssh-ed25519") == nil)
        #expect(PublicKey.line(from: "ssh-ed25519 AAAA\nssh-rsa BBBB") == nil)
        #expect(PublicKey.line(from: "") == nil)
    }

    @Test func publicKeyLoadsOnlyTheMatchingPubFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nobet-pub-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let key = directory.appendingPathComponent("id_test").path
        #expect(PublicKey.load(forKeyAt: key) == nil)
        try "ssh-ed25519 AAAA test".write(toFile: key + ".pub", atomically: true, encoding: .utf8)
        #expect(PublicKey.load(forKeyAt: key) == "ssh-ed25519 AAAA test")
        try String(repeating: "a", count: PublicKey.maxBytes + 1).write(toFile: key + ".pub", atomically: true, encoding: .utf8)
        #expect(PublicKey.load(forKeyAt: key) == nil)
    }

    @Test @MainActor func sourceScanIsOffByDefaultAndPersists() {
        let name = "nobet-test-\(UUID().uuidString)"
        let defaults = TestDefaults.make(name)
        defaults.removePersistentDomain(forName: name)
        let model = SecretsModel(nobet: NobetModel(), defaults: defaults, home: "/h")
        #expect(!model.scanSource)
        model.setScanSource(true)
        #expect(model.scanSource)
        #expect(defaults.bool(forKey: SecretsModel.scanSourceKey))
    }
}
