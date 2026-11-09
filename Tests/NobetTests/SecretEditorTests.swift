import Foundation
import Testing
@testable import Nobet

struct EnvDocumentTests {
    private func value(_ document: EnvDocument, _ key: String) -> EnvLine? { document.lines.first { $0.key == key } }

    @Test func parseReadsEntriesAndSkipsCommentsAndBlanks() {
        let document = EnvDocument.parse("# not\nA=1\nexport B=\"x y\"\n\nC='z'\nbozuk satir\n")
        #expect(document.lines.compactMap(\.key) == ["A", "B", "C"])
        #expect(value(document, "B")?.value == "x y")
        #expect(value(document, "B")?.exported == true)
        #expect(value(document, "B")?.quote == "\"")
        #expect(value(document, "C")?.quote == "'")
        #expect(value(document, "A")?.quote == nil)
    }

    @Test func untouchedDocumentRoundTripsByteForByte() throws {
        for text in ["A=1\n# c\nB=\"x y\"  \n", "A=1", "A=1\r\nB=2\r\n", "\n\nexport  K = v # n\n", ""] {
            #expect(try EnvDocument.parse(text).serialized() == text)
        }
    }

    @Test func editKeepsQuoteExportAndComment() throws {
        var document = EnvDocument.parse("export B=\"x y\"\nA=1 # not\n")
        document.setValue("yeni değer", at: 0)
        document.setValue("2", at: 1)
        #expect(try document.serialized() == "export B=\"yeni değer\"\nA=2 # not\n")
    }

    @Test func unquotedValueWithSpaceGetsQuotes() throws {
        var document = EnvDocument.parse("A=1\n")
        document.setValue("a b", at: 0)
        #expect(try document.serialized() == "A=\"a b\"\n")
    }

    @Test func valueWithNewlineIsRejectedWithoutLeakingIt() {
        var document = EnvDocument.parse("A=1\n")
        document.setValue("gizli\nB=2", at: 0)
        #expect(throws: SecretEditError.invalidValue(key: "A")) { try document.serialized() }
    }

    @Test func valueWithBothQuoteKindsIsRejectedWhenUnquoted() {
        var document = EnvDocument.parse("A=1\n")
        document.setValue("a\"b'c", at: 0)
        #expect(throws: SecretEditError.invalidValue(key: "A")) { try document.serialized() }
    }

    @Test func deleteRemovesOnlyThatLine() throws {
        var document = EnvDocument.parse("A=1\n# k\nB=2\n")
        document.toggleDelete(at: 0)
        #expect(try document.serialized() == "# k\nB=2\n")
        document.toggleDelete(at: 0)
        #expect(try document.serialized() == "A=1\n# k\nB=2\n")
    }

    @Test func countsChangedAndDeletedEntries() {
        var document = EnvDocument.parse("A=1\nB=2\nC=3\n")
        document.setValue("9", at: 0)
        document.toggleDelete(at: 1)
        #expect(document.changedCount == 1)
        #expect(document.deletedCount == 1)
    }
}

struct SecretEditorTests {
    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("nobet-edit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, to url: URL, mode: Int = 0o600) throws {
        try Data(text.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    private func finding(_ kind: SecretKind, _ path: String) -> SecretFinding {
        SecretFinding(kind: kind, severity: .high, path: path, detail: "")
    }

    @Test func onlyEnvFilesOfEnvKindsAreEditable() {
        #expect(SecretEditor.canEdit(finding(.envTracked, "/h/p/.env")))
        #expect(SecretEditor.canEdit(finding(.envWorldReadable, "/h/p/.env.local")))
        #expect(!SecretEditor.canEdit(finding(.envNotIgnored, "/h/p/config.txt")))
        #expect(!SecretEditor.canEdit(finding(.privateKeyPermissions, "/h/.ssh/id_rsa")))
        #expect(!SecretEditor.canEdit(finding(.unencryptedPrivateKey, "/h/.env")))
        #expect(!SecretEditor.canEdit(finding(.credentialFile, "/h/.aws/credentials")))
    }

    @Test func loadRefusesSymlinkOversizeBinaryAndMissing() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let real = dir.appendingPathComponent("real")
        try write("A=1\n", to: real)
        let link = dir.appendingPathComponent(".env")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        #expect(throws: SecretEditError.notRegularFile) { try SecretEditor.load(path: link.path) }

        let big = dir.appendingPathComponent(".env.big")
        try write(String(repeating: "A=1\n", count: SecretEditor.maxBytes), to: big)
        #expect(throws: SecretEditError.tooLarge) { try SecretEditor.load(path: big.path) }

        let binary = dir.appendingPathComponent(".env.bin")
        try Data([0xFF, 0xFE, 0x00, 0x80]).write(to: binary)
        #expect(throws: SecretEditError.notText) { try SecretEditor.load(path: binary.path) }

        #expect(throws: SecretEditError.notRegularFile) { try SecretEditor.load(path: dir.appendingPathComponent("yok").path) }
    }

    @Test func saveWritesChangesKeepsModeAndLeavesNoTempFile() throws {
        for mode in [0o600, 0o644] {
            let dir = try makeDirectory()
            defer { try? FileManager.default.removeItem(at: dir) }
            let file = dir.appendingPathComponent(".env")
            try write("A=1\nB=2\n", to: file, mode: mode)
            var loaded = try SecretEditor.load(path: file.path)
            loaded.document.setValue("9", at: 0)
            loaded.document.toggleDelete(at: 1)
            try SecretEditor.save(loaded, to: file.path)
            #expect(try String(contentsOf: file, encoding: .utf8) == "A=9\n")
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect((attributes[.posixPermissions] as? Int) == mode)
            #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [".env"])
        }
    }

    @Test func saveRefusesWhenFileChangedAfterLoad() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(".env")
        try write("A=1\n", to: file)
        var loaded = try SecretEditor.load(path: file.path)
        try write("A=1\nB=baska-arac\n", to: file)
        loaded.document.setValue("9", at: 0)
        #expect(throws: SecretEditError.changedOnDisk) { try SecretEditor.save(loaded, to: file.path) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "A=1\nB=baska-arac\n")
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == [".env"])
    }

    @Test func invalidValueLeavesFileUntouched() throws {
        let dir = try makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(".env")
        try write("A=1\n", to: file)
        var loaded = try SecretEditor.load(path: file.path)
        loaded.document.setValue("x\ny", at: 0)
        #expect(throws: SecretEditError.invalidValue(key: "A")) { try SecretEditor.save(loaded, to: file.path) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "A=1\n")
    }
}

struct SecretEditModelTests {
    @Test @MainActor func editSaveRoundTripWithoutLeakingValuesIntoMessages() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nobet-editmodel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(".env")
        try Data("TOKEN=eski-gizli\nPORT=80\n".utf8).write(to: file)

        let model = SecretEditModel(path: file.path)
        model.load()
        #expect(model.document?.lines.count == 2)
        model.setValue(0, "yeni-gizli")
        model.toggleDelete(1)
        #expect(model.summary == "1 değer değişti, 1 satır silinecek")
        #expect(!model.summary.contains("gizli"))
        #expect(model.save())
        #expect(model.errorText == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == "TOKEN=yeni-gizli\n")
    }

    @Test @MainActor func failedSaveShowsMessageWithoutValues() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("nobet-editmodel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent(".env")
        try Data("TOKEN=a\n".utf8).write(to: file)
        let model = SecretEditModel(path: file.path)
        model.load()
        try Data("TOKEN=b\n".utf8).write(to: file)
        model.setValue(0, "sirrim")
        #expect(!model.save())
        #expect(model.errorText?.contains("sirrim") == false)
        #expect(model.errorText?.isEmpty == false)
    }

    @Test @MainActor func unreadableFileGivesErrorAndNoDocument() {
        let model = SecretEditModel(path: "/yok/.env")
        model.load()
        #expect(model.document == nil)
        #expect(model.errorText?.isEmpty == false)
    }
}
