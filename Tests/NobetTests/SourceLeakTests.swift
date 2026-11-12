import Foundation
import Testing
@testable import Nobet

/// Test jetonları çalışma anında birleştirilir. Kaynak dosyada bütün biçimde durmaz, böylece Nöbet kendi deposunu işaretlemez.
private enum Fake {
    static let github = "gh" + "p_" + String(repeating: "a", count: 36)
    static let aws = "AK" + "IA" + String(repeating: "B", count: 16)
    static let stripe = "sk" + "_live_" + String(repeating: "c", count: 24)
}

struct SourceLeakTests {
    @Test func findsAKnownTokenInsideAStringLiteral() {
        let hits = SourceLeak.hits(in: "let a = 1\nlet token = \"\(Fake.github)\"\n")
        #expect(hits == [SourceLeak.Hit(line: 2, provider: "GitHub")])
    }

    @Test func findsTokensAfterEqualsAndBearer() {
        let text = "export KEY=\(Fake.aws)\ncurl -H 'Authorization: Bearer \(Fake.stripe)'"
        #expect(SourceLeak.hits(in: text).map(\.provider) == ["AWS", "Stripe"])
    }

    @Test func ignoresOrdinaryLongIdentifiers() {
        let text = "let veryLongVariableNameForTheTest = 1\nfunc computeSomethingVeryLongNamed() {}\nid = 123456789012345678901234567890"
        #expect(SourceLeak.hits(in: text).isEmpty)
    }

    @Test func ignoresTokenShapeGluedToOtherLetters() {
        #expect(SourceLeak.hits(in: "x\(Fake.aws)y").isEmpty)
    }

    @Test func skipsMinifiedLongLines() {
        let long = String(repeating: "a", count: SourceLeak.maxLineLength + 1) + " \(Fake.github)"
        #expect(SourceLeak.hits(in: long).isEmpty)
    }

    @Test func findingNamesLinesAndProvidersButNeverTheValue() throws {
        let text = "a\n\(Fake.github)\n\(Fake.aws)\n"
        let finding = try #require(SourceLeak.finding(path: "/p/app.py", text: text))
        #expect(finding.kind == .sourceToken)
        #expect(finding.detail.contains("2 (GitHub)"))
        #expect(finding.detail.contains("3 (AWS)"))
        #expect(!finding.detail.contains(Fake.github))
        #expect(!finding.detail.contains(Fake.aws))
        #expect(finding.rotationAdvice?.contains("GitHub") == true)
    }

    @Test func findingCapsTheListedHits() throws {
        let text = (1...12).map { _ in Fake.github }.joined(separator: "\n")
        let finding = try #require(SourceLeak.finding(path: "/p/a.js", text: text))
        #expect(finding.detail.contains("+7"))
    }

    @Test func noTokenMeansNoFinding() {
        #expect(SourceLeak.finding(path: "/p/a.js", text: "console.log('merhaba')") == nil)
    }

    @Test func fileNameFilterPicksSourceAndConfigOnly() {
        for name in ["main.swift", "app.ts", "settings.py", "deploy.sh", "config.yml", "data.json", "Dockerfile"] {
            #expect(SourceLeak.isScannable(fileName: name), "\(name) taranmalı")
        }
        for name in ["photo.png", "app.min.js", "package-lock.json", "Package.resolved", "composer.lock", ".env", ".env.local", "archive.zip"] {
            #expect(!SourceLeak.isScannable(fileName: name), "\(name) taranmamalı")
        }
    }
}

struct SourceLeakScanTests {
    private func makeTree() throws -> String {
        let root = NSTemporaryDirectory() + "nobet-src-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        return root
    }

    private func write(_ root: String, _ relative: String, _ content: Data) throws {
        let path = root + "/" + relative
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try content.write(to: URL(fileURLWithPath: path))
    }

    @Test func scanFindsTokensOnlyWhenEnabled() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(atPath: root) }
        try write(root, "app/config.py", Data("TOKEN = \"\(Fake.github)\"".utf8))
        let far = Date().addingTimeInterval(60)
        let off = SecretScanner.scan(roots: [root], home: root, git: NoGit(), deadline: far)
        #expect(!off.contains { $0.kind == .sourceToken })
        let on = SecretScanner.scan(roots: [root], home: root, git: NoGit(), deadline: far, scanSource: true)
        let hit = try #require(on.first { $0.kind == .sourceToken })
        #expect(hit.path == root + "/app/config.py")
    }

    @Test func scanSkipsBinaryOversizedAndHeavyDirectories() throws {
        let root = try makeTree()
        defer { try? FileManager.default.removeItem(atPath: root) }
        let token = Data(Fake.github.utf8)
        try write(root, "bin.py", Data([0]) + token)
        try write(root, "big.py", token + Data(repeating: 0x20, count: SourceLeak.maxFileBytes))
        try write(root, "node_modules/lib/index.js", token)
        let found = SecretScanner.scan(roots: [root], home: root, git: NoGit(), deadline: Date().addingTimeInterval(60), scanSource: true)
        #expect(!found.contains { $0.kind == .sourceToken })
    }
}

private struct NoGit: GitProbing {
    func status(ofFile path: String) -> GitStatus { GitStatus(inRepo: false, tracked: false, ignored: false) }
}
