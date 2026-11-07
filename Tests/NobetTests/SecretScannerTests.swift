import Foundation
import Testing
@testable import Nobet

/// Geçici klasör. Her test kendi klasörünü açar ve işi bitince siler. Gerçek ev klasörüne dokunulmaz.
private final class TempTree {
    let root: String

    init() {
        root = NSTemporaryDirectory() + "nobet-test-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(atPath: root) }

    @discardableResult
    func write(_ relative: String, _ content: String, mode: UInt16 = 0o600) -> String {
        let path = root + "/" + relative
        let dir = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data(content.utf8), attributes: [.posixPermissions: NSNumber(value: mode)])
        return path
    }

    func makeDirectory(_ relative: String, mode: UInt16) {
        let path = root + "/" + relative
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: NSNumber(value: mode)])
        try? FileManager.default.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: path)
    }
}

private struct FakeGit: GitProbing {
    var status: GitStatus
    func status(ofFile path: String) -> GitStatus { status }
}

private let far = Date().addingTimeInterval(60)

struct FileWalkerTests {
    @Test func findsEnvFilesInNestedFolders() {
        let tree = TempTree()
        let a = tree.write("app/.env", "X=1")
        let b = tree.write("app/api/.env.local", "X=1")
        tree.write("app/.env.example", "X=1")
        tree.write("app/readme.md", "x")
        let found = Set(FileWalker.envFiles(under: tree.root, maxDepth: 6, maxEntries: 10_000, deadline: far))
        #expect(found == [a, b])
    }

    @Test func skipsHeavyAndSystemDirectories() {
        let tree = TempTree()
        tree.write("node_modules/pkg/.env", "X=1")
        tree.write("vendor/.env", "X=1")
        tree.write(".git/.env", "X=1")
        tree.write("Library/Caches/.env", "X=1")
        tree.write("Documents/.env", "X=1")
        tree.write("Downloads/.env", "X=1")
        let found = FileWalker.envFiles(under: tree.root, maxDepth: 6, maxEntries: 10_000, deadline: far)
        #expect(found.isEmpty)
    }

    @Test func explicitRootInsideASkippedNameIsStillScanned() {
        let tree = TempTree()
        let file = tree.write("Documents/proje/.env", "X=1")
        let found = FileWalker.envFiles(under: tree.root + "/Documents/proje", maxDepth: 6, maxEntries: 10_000, deadline: far)
        #expect(found == [file])
    }

    @Test func respectsMaxDepth() {
        let tree = TempTree()
        let shallow = tree.write("a/b/.env", "X=1")
        tree.write("a/b/c/d/.env", "X=1")
        let found = FileWalker.envFiles(under: tree.root, maxDepth: 3, maxEntries: 10_000, deadline: far)
        #expect(found == [shallow])
    }

    @Test func pastDeadlineReturnsNothing() {
        let tree = TempTree()
        tree.write("a/.env", "X=1")
        let found = FileWalker.envFiles(under: tree.root, maxDepth: 6, maxEntries: 10_000, deadline: Date().addingTimeInterval(-1))
        #expect(found.isEmpty)
    }

    @Test func doesNotFollowSymbolicLinks() throws {
        let tree = TempTree()
        let other = TempTree()
        other.write(".env", "X=1")
        try FileManager.default.createSymbolicLink(atPath: tree.root + "/link", withDestinationPath: other.root)
        let found = FileWalker.envFiles(under: tree.root, maxDepth: 6, maxEntries: 10_000, deadline: far)
        #expect(found.isEmpty)
    }

    @Test func entryLimitStopsTheWalk() {
        let tree = TempTree()
        for index in 0..<50 { tree.write("d\(index)/x.txt", "x") }
        tree.write("zz/.env", "X=1")
        let found = FileWalker.envFiles(under: tree.root, maxDepth: 6, maxEntries: 5, deadline: far)
        #expect(found.count <= 1)
    }
}

struct SystemGitTests {
    private func git(_ dir: String, _ arguments: [String]) {
        _ = DevRunner.run("/usr/bin/git", ["-C", dir, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + arguments, timeout: 20)
    }

    private func probe() -> SystemGit { SystemGit() }

    @Test func committedFileIsTracked() throws {
        try #require(SystemGit.gitPath != nil, "git bulunamadı")
        let tree = TempTree()
        let file = tree.write(".env", "DB_PASSWORD=abcdefgh1234")
        git(tree.root, ["init", "-q"])
        git(tree.root, ["add", ".env"])
        git(tree.root, ["commit", "-q", "-m", "x"])
        #expect(probe().status(ofFile: file) == GitStatus(inRepo: true, tracked: true, ignored: false))
    }

    @Test func ignoredFileIsReported() throws {
        try #require(SystemGit.gitPath != nil, "git bulunamadı")
        let tree = TempTree()
        tree.write(".gitignore", ".env\n")
        let file = tree.write(".env", "DB_PASSWORD=abcdefgh1234")
        git(tree.root, ["init", "-q"])
        #expect(probe().status(ofFile: file) == GitStatus(inRepo: true, tracked: false, ignored: true))
    }

    @Test func untrackedUnignoredFileIsReported() throws {
        try #require(SystemGit.gitPath != nil, "git bulunamadı")
        let tree = TempTree()
        let file = tree.write(".env", "DB_PASSWORD=abcdefgh1234")
        git(tree.root, ["init", "-q"])
        #expect(probe().status(ofFile: file) == GitStatus(inRepo: true, tracked: false, ignored: false))
    }

    @Test func fileOutsideAnyRepoIsNotInRepo() throws {
        try #require(SystemGit.gitPath != nil, "git bulunamadı")
        let tree = TempTree()
        let file = tree.write(".env", "DB_PASSWORD=abcdefgh1234")
        #expect(probe().status(ofFile: file) == GitStatus(inRepo: false, tracked: false, ignored: false))
    }
}

struct SecretScannerTests {
    private let pem = "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEA\n-----END RSA PRIVATE KEY-----\n"
    private let tracked = FakeGit(status: GitStatus(inRepo: true, tracked: true, ignored: false))
    private let clean = FakeGit(status: GitStatus(inRepo: true, tracked: false, ignored: true))

    @Test func reportsTrackedEnvFile() {
        let home = TempTree()
        let file = home.write("proj/.env", "DB_PASSWORD=abcdefgh1234\n")
        let findings = SecretScanner.scan(roots: [home.root], home: home.root, git: tracked, deadline: far)
        #expect(findings.contains { $0.kind == .envTracked && $0.path == file })
    }

    @Test func findingsNeverContainSecretValues() {
        let home = TempTree()
        home.write("proj/.env", "DB_PASSWORD=abcdefgh1234\n", mode: 0o644)
        home.write(".git-credentials", "https://user:SUPERSECRETPASS@github.com\n")
        let findings = SecretScanner.scan(roots: [home.root], home: home.root, git: tracked, deadline: far)
        #expect(!findings.isEmpty)
        for finding in findings {
            #expect(!finding.detail.contains("abcdefgh1234"))
            #expect(!finding.detail.contains("SUPERSECRETPASS"))
            #expect(!finding.path.contains("SUPERSECRETPASS"))
        }
    }

    @Test func reportsLooseSshKeyAndDirectory() {
        let home = TempTree()
        home.makeDirectory(".ssh", mode: 0o755)
        let key = home.write(".ssh/id_rsa", pem, mode: 0o644)
        let findings = SecretScanner.scan(roots: [], home: home.root, git: clean, deadline: far)
        #expect(findings.contains { $0.kind == .privateKeyPermissions && $0.path == key })
        #expect(findings.contains { $0.kind == .sshDirectoryPermissions })
    }

    @Test func publicKeysAndConfigAreNotFlagged() {
        let home = TempTree()
        home.makeDirectory(".ssh", mode: 0o700)
        home.write(".ssh/id_rsa.pub", "ssh-rsa AAAA user\n", mode: 0o644)
        home.write(".ssh/config", "Host *\n", mode: 0o644)
        home.write(".ssh/known_hosts", "host ssh-rsa AAAA\n", mode: 0o644)
        let findings = SecretScanner.scan(roots: [], home: home.root, git: clean, deadline: far)
        #expect(findings.isEmpty)
    }

    @Test func reportsPlaintextCredentialStore() {
        let home = TempTree()
        let file = home.write(".git-credentials", "https://u:p@github.com\n")
        let findings = SecretScanner.scan(roots: [], home: home.root, git: clean, deadline: far)
        #expect(findings.contains { $0.kind == .plaintextCredentialStore && $0.path == file })
    }

    @Test func emptyHomeGivesNoFindings() {
        let home = TempTree()
        #expect(SecretScanner.scan(roots: [home.root], home: home.root, git: clean, deadline: far).isEmpty)
    }

    @Test func overlappingRootsReportAFileOnce() {
        let home = TempTree()
        home.write("proj/.env", "DB_PASSWORD=abcdefgh1234\n")
        let findings = SecretScanner.scan(roots: [home.root, home.root + "/proj"], home: home.root, git: tracked, deadline: far)
        #expect(findings.filter { $0.kind == .envTracked }.count == 1)
    }

    @Test func hugeEnvFileIsSkipped() {
        let home = TempTree()
        let filler = String(repeating: "A=1\n", count: 40_000)
        home.write("proj/.env", "DB_PASSWORD=abcdefgh1234\n" + filler)
        let findings = SecretScanner.scan(roots: [home.root], home: home.root, git: tracked, deadline: far)
        #expect(findings.isEmpty)
    }

    @Test func highFindingsComeFirst() {
        let home = TempTree()
        home.write(".git-credentials", "https://u:p@github.com\n")
        home.write("proj/.env", "DB_PASSWORD=abcdefgh1234\n")
        let findings = SecretScanner.scan(roots: [home.root], home: home.root, git: tracked, deadline: far)
        #expect(findings.first?.severity == .high)
        #expect(findings.map(\.severity) == findings.map(\.severity).sorted(by: >))
    }

    @Test func gitIgnoredSafeEnvFileGivesNoFinding() {
        let home = TempTree()
        home.write("proj/.env", "DB_PASSWORD=abcdefgh1234\n")
        #expect(SecretScanner.scan(roots: [home.root], home: home.root, git: clean, deadline: far).isEmpty)
    }
}
