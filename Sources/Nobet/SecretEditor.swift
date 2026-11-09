import Foundation

enum SecretEditError: Error, Equatable {
    case notRegularFile, tooLarge, notText, changedOnDisk, writeFailed
    case invalidValue(key: String)

    /// Mesaj değer ve yol içermez.
    var message: String {
        switch self {
        case .notRegularFile: return "Dosya okunamadı veya düz bir dosya değil."
        case .tooLarge: return "Dosya 256 KB sınırından büyük."
        case .notText: return "Dosya UTF-8 metin değil."
        case .changedOnDisk: return "Dosya siz açtıktan sonra değişti. Kapatıp yeniden açın."
        case .writeFailed: return "Dosya yazılamadı. Dosya olduğu gibi duruyor."
        case .invalidValue(let key): return "\(key) değeri geçersiz: satır sonu veya uyumsuz tırnak içeriyor."
        }
    }
}

/// `.env` dosyasının bir satırı. Dokunulmayan satır dosyaya birebir geri yazılır.
struct EnvLine: Identifiable, Equatable {
    let id: Int
    let raw: String
    /// `nil`: yorum, boş veya tanınmayan satır.
    let key: String?
    let original: String
    var value: String
    let quote: Character?
    let exported: Bool
    /// Değerden sonra gelen kısım: satır sonu yorumu, boşluk, CR.
    let suffix: String
    var deleted = false

    var changed: Bool { key != nil && !deleted && value != original }
}

struct EnvDocument: Equatable {
    var lines: [EnvLine]
    let trailingNewline: Bool

    var changedCount: Int { lines.filter(\.changed).count }
    var deletedCount: Int { lines.filter(\.deleted).count }

    mutating func setValue(_ value: String, at index: Int) {
        guard lines.indices.contains(index), lines[index].key != nil else { return }
        lines[index].value = value
    }

    mutating func toggleDelete(at index: Int) {
        guard lines.indices.contains(index), lines[index].key != nil else { return }
        lines[index].deleted.toggle()
    }

    /// Geçersiz değer dosyaya yazılmadan önce burada reddedilir.
    func serialized() throws -> String {
        let kept = try lines.filter { !$0.deleted }.map(Self.render)
        return kept.joined(separator: "\n") + (trailingNewline && !kept.isEmpty ? "\n" : "")
    }

    private static func render(_ line: EnvLine) throws -> String {
        guard let key = line.key, line.value != line.original else { return line.raw }
        let quote = try quoteFor(line)
        let q = quote.map(String.init) ?? ""
        return (line.exported ? "export " : "") + key + "=" + q + line.value + q + line.suffix
    }

    private static func quoteFor(_ line: EnvLine) throws -> Character? {
        let value = line.value
        let invalid = SecretEditError.invalidValue(key: line.key ?? "")
        // `\r\n` tek Character sayılır. Bu yüzden scalar düzeyinde de bakılır.
        if value.unicodeScalars.contains(where: { $0 == "\n" || $0 == "\r" || $0 == "\0" }) { throw invalid }
        if let q = line.quote {
            if closes(value, with: q) { throw invalid }
            return q
        }
        let needsQuotes = value.contains(where: { $0.isWhitespace || "#\"'".contains($0) })
        guard needsQuotes else { return nil }
        if !value.contains("\"") && !value.contains("\\") { return "\"" }
        if !value.contains("'") { return "'" }
        throw invalid
    }

    /// Değer kendi tırnağını erken kapatır mı? Çift tırnakta `\` bir sonraki karakteri kaçırır.
    private static func closes(_ value: String, with quote: Character) -> Bool {
        var escaped = false
        for character in value {
            if escaped { escaped = false; continue }
            if quote == "\"" && character == "\\" { escaped = true; continue }
            if character == quote { return true }
        }
        return escaped
    }

    // MARK: Ayrıştırma

    static func parse(_ text: String) -> EnvDocument {
        guard !text.isEmpty else { return EnvDocument(lines: [], trailingNewline: false) }
        var pieces = splitLines(text)
        let trailing = text.unicodeScalars.last == "\n"
        if trailing { pieces.removeLast() }
        return EnvDocument(lines: pieces.enumerated().map { parseLine($1, id: $0) }, trailingNewline: trailing)
    }

    /// `\r\n` tek karakter sayıldığı için satırlar scalar düzeyinde bölünür. CR satırın sonunda kalır.
    private static func splitLines(_ text: String) -> [String] {
        var result: [String] = []
        var current = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                result.append(String(current))
                current = String.UnicodeScalarView()
            } else {
                current.append(scalar)
            }
        }
        result.append(String(current))
        return result
    }

    private static func opaque(_ raw: String, _ id: Int) -> EnvLine {
        EnvLine(id: id, raw: raw, key: nil, original: "", value: "", quote: nil, exported: false, suffix: "")
    }

    private static func blank(_ character: Character) -> Bool { character == " " || character == "\t" }

    private static func parseLine(_ raw: String, id: Int) -> EnvLine {
        var rest = Substring(raw).drop(while: blank)
        guard !rest.isEmpty, !rest.hasPrefix("#") else { return opaque(raw, id) }
        var exported = false
        if rest.hasPrefix("export ") {
            exported = true
            rest = rest.dropFirst(7).drop(while: blank)
        }
        guard let first = rest.first, first.isLetter || first == "_" else { return opaque(raw, id) }
        let key = String(rest.prefix(while: { $0.isLetter || $0.isNumber || "_.-".contains($0) }))
        rest = rest.dropFirst(key.count).drop(while: blank)
        guard rest.hasPrefix("=") else { return opaque(raw, id) }
        rest = rest.dropFirst().drop(while: blank)
        let (value, quote, suffix) = splitValue(rest)
        return EnvLine(id: id, raw: raw, key: key, original: value, value: value, quote: quote, exported: exported, suffix: suffix)
    }

    private static func splitValue(_ rest: Substring) -> (String, Character?, String) {
        if let q = rest.first, q == "\"" || q == "'" {
            var escaped = false
            var index = rest.index(after: rest.startIndex)
            while index < rest.endIndex {
                let character = rest[index]
                if escaped {
                    escaped = false
                } else if q == "\"" && character == "\\" {
                    escaped = true
                } else if character == q {
                    let inner = String(rest[rest.index(after: rest.startIndex)..<index])
                    return (inner, q, String(rest[rest.index(after: index)...]))
                }
                index = rest.index(after: index)
            }
        }
        // Tırnaksız değer: ` #` satır sonu yorumunu başlatır. Değerin sondaki boşluğu sonekte kalır.
        var end = rest.endIndex
        var previousBlank = false
        for index in rest.indices {
            if rest[index] == "#", previousBlank { end = rest.index(before: index); break }
            previousBlank = blank(rest[index])
        }
        var valueEnd = end
        while valueEnd > rest.startIndex, rest[rest.index(before: valueEnd)].isWhitespace { valueEnd = rest.index(before: valueEnd) }
        return (String(rest[..<valueEnd]), nil, String(rest[valueEnd...]))
    }
}

/// Sır bulgusundaki `.env` dosyasını güvenle düzenler. Yalnızca düz dosya, 256 KB'a kadar, UTF-8.
enum SecretEditor {
    nonisolated static let maxBytes = 256 * 1024
    private static let editableKinds: Set<SecretKind> = [.envTracked, .envNotIgnored, .envInHistory, .envWorldReadable]

    static func canEdit(_ finding: SecretFinding) -> Bool {
        editableKinds.contains(finding.kind) && (finding.path as NSString).lastPathComponent.hasPrefix(".env")
    }

    struct Loaded: Equatable {
        var document: EnvDocument
        let fingerprint: String
        let mode: Int
    }

    static func load(path: String) throws -> Loaded {
        let manager = FileManager.default
        // `attributesOfItem` bağlantıyı izlemez: sembolik bağlantı `.typeSymbolicLink` döner.
        guard let attributes = try? manager.attributesOfItem(atPath: path),
              attributes[.type] as? FileAttributeType == .typeRegular else { throw SecretEditError.notRegularFile }
        guard ((attributes[.size] as? NSNumber)?.intValue ?? 0) <= maxBytes else { throw SecretEditError.tooLarge }
        guard let data = manager.contents(atPath: path) else { throw SecretEditError.notRegularFile }
        guard data.count <= maxBytes else { throw SecretEditError.tooLarge }
        guard !data.contains(0), let text = String(data: data, encoding: .utf8) else { throw SecretEditError.notText }
        return Loaded(document: .parse(text), fingerprint: "\(AlertKey.digest(text))|\(data.count)",
                      mode: (attributes[.posixPermissions] as? Int) ?? 0o600)
    }

    /// Dosya açıldıktan sonra değiştiyse reddeder. Geçici dosya aynı klasörde 0600 ile açılır,
    /// özgün izinle `rename` edilir. Hata olursa özgün dosya olduğu gibi kalır.
    static func save(_ loaded: Loaded, to path: String) throws {
        guard try load(path: path).fingerprint == loaded.fingerprint else { throw SecretEditError.changedOnDisk }
        let data = Data(try loaded.document.serialized().utf8)
        let temp = (path as NSString).deletingLastPathComponent + "/.nobet-tmp-" + UUID().uuidString
        guard FileManager.default.createFile(atPath: temp, contents: nil, attributes: [.posixPermissions: 0o600]),
              let handle = FileHandle(forWritingAtPath: temp) else { throw SecretEditError.writeFailed }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try FileManager.default.setAttributes([.posixPermissions: loaded.mode], ofItemAtPath: temp)
            guard rename(temp, path) == 0 else { throw SecretEditError.writeFailed }
        } catch {
            try? FileManager.default.removeItem(atPath: temp)
            throw SecretEditError.writeFailed
        }
    }
}

/// Düzenleme penceresinin durumu. Değerler yalnızca bellekte durur ve pencere kapanınca gider.
@MainActor
final class SecretEditModel: ObservableObject {
    let path: String
    @Published private(set) var document: EnvDocument?
    @Published var revealed: Set<Int> = []
    @Published private(set) var errorText: String?
    private var loaded: SecretEditor.Loaded?

    init(path: String) { self.path = path }

    func load() {
        do {
            let result = try SecretEditor.load(path: path)
            loaded = result
            document = result.document
            errorText = nil
        } catch {
            loaded = nil
            document = nil
            errorText = (error as? SecretEditError)?.message ?? SecretEditError.notRegularFile.message
        }
    }

    func setValue(_ id: Int, _ value: String) { document?.setValue(value, at: id) }
    func toggleDelete(_ id: Int) { document?.toggleDelete(at: id) }

    var hasChanges: Bool { (document?.changedCount ?? 0) + (document?.deletedCount ?? 0) > 0 }

    /// Değer içermez. Onay penceresinde gösterilir.
    var summary: String {
        var parts: [String] = []
        if let changed = document?.changedCount, changed > 0 { parts.append("\(changed) değer değişti") }
        if let deleted = document?.deletedCount, deleted > 0 { parts.append("\(deleted) satır silinecek") }
        return parts.isEmpty ? "Değişiklik yok" : parts.joined(separator: ", ")
    }

    @discardableResult
    func save() -> Bool {
        guard var current = loaded, let document else { return false }
        current.document = document
        do {
            try SecretEditor.save(current, to: path)
            errorText = nil
            return true
        } catch {
            errorText = (error as? SecretEditError)?.message ?? SecretEditError.writeFailed.message
            return false
        }
    }
}
