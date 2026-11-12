import Foundation

enum Severity: Int, Comparable, Codable {
    case info = 0
    case medium = 1
    case high = 2

    static func < (lhs: Severity, rhs: Severity) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Renkten bağımsız şekil. Renk körü kullanıcı önemi simgeden ayırır.
    var symbol: String {
        switch self {
        case .high: return "exclamationmark.octagon.fill"
        case .medium: return "exclamationmark.triangle.fill"
        case .info: return "info.circle"
        }
    }

    var label: String {
        switch self {
        case .high: return "Yüksek"
        case .medium: return "Orta"
        case .info: return "Bilgi"
        }
    }
}

enum SecretKind: String, CaseIterable {
    case privateKeyPermissions
    case sshDirectoryPermissions
    case unencryptedPrivateKey
    case envTracked
    case envNotIgnored
    case envInHistory
    case envWorldReadable
    case credentialWorldReadable
    case plaintextCredentialStore
    case credentialFile
    case sourceToken

    var title: String {
        switch self {
        case .privateKeyPermissions: return "Özel anahtarın izni gevşek"
        case .sshDirectoryPermissions: return ".ssh klasörünün izni gevşek"
        case .unencryptedPrivateKey: return "Parolasız özel anahtar"
        case .envTracked: return ".env dosyası git'e eklenmiş"
        case .envNotIgnored: return ".env dosyası .gitignore dışında"
        case .envInHistory: return ".env dosyası git geçmişinde"
        case .envWorldReadable: return "Sır içeren dosya başkalarınca okunur"
        case .credentialWorldReadable: return "Kimlik bilgisi dosyası başkalarınca okunur"
        case .plaintextCredentialStore: return "Düz metin kimlik bilgisi dosyası"
        case .credentialFile: return "Kimlik bilgisi dosyası"
        case .sourceToken: return "Kaynak kodda jeton var"
        }
    }
}

/// Tarama bulgusu. `detail` anahtar adlarını ve izinleri içerir. Sır değerini asla içermez.
struct SecretFinding: Identifiable, Equatable {
    let kind: SecretKind
    let severity: Severity
    let path: String
    let detail: String

    var id: String { kind.rawValue + "|" + path }

    /// Kullanıcının kendi çalıştıracağı düzeltme komutu. Uygulama komutu çalıştırmaz.
    var suggestedCommand: String? {
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        switch kind {
        case .privateKeyPermissions, .credentialWorldReadable, .envWorldReadable:
            return "chmod 600 \(Self.shellQuoted(path))"
        case .sshDirectoryPermissions:
            return "chmod 700 \(Self.shellQuoted(path))"
        case .envTracked:
            return "git -C \(Self.shellQuoted(directory)) rm --cached -- \(Self.shellQuoted(name))"
        case .envNotIgnored:
            return "echo \(Self.shellQuoted(name)) >> \(Self.shellQuoted(directory + "/.gitignore"))"
        case .unencryptedPrivateKey:
            return "ssh-keygen -p -f \(Self.shellQuoted(path))"
        case .credentialFile, .plaintextCredentialStore, .envInHistory, .sourceToken:
            return nil
        }
    }

    /// Sır başkalarının eline geçmiş olabilirse sağlayıcıda yenileme önerisi. Uygulama bunu kendisi yapmaz.
    var rotationAdvice: String? {
        var parts: [String] = []
        if kind == .sourceToken {
            parts.append("Jeton kaynak kodda durur. Kodu paylaştıysanız sırrı sağlayıcıda yenileyin ve kodda ortam değişkenine taşıyın.")
        }
        if kind == .envTracked || kind == .envInHistory {
            parts.append("Dosya git geçmişinde kaldı. Dosyayı silmek yetmez, sırları sağlayıcıda yenileyin.")
        }
        for name in TokenPattern.providerNames where detail.contains("(\(name))") {
            if let hint = TokenPattern.rotationHint(for: name) { parts.append(hint) }
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func shellQuoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Menü çubuğu uyarısı: yüksek ve orta bulguların sayısı. Bilgi bulguları sayılmaz.
    static func alertCount(_ findings: [SecretFinding]) -> Int {
        findings.filter { $0.severity >= .medium }.count
    }

    /// Önce ağırlık (yüksek önce), sonra yol sırası.
    static func sorted(_ findings: [SecretFinding]) -> [SecretFinding] {
        findings.sorted { lhs, rhs in
            lhs.severity != rhs.severity ? lhs.severity > rhs.severity : lhs.path < rhs.path
        }
    }
}

enum FileMode {
    static func isGroupOrWorldAccessible(_ mode: UInt16) -> Bool { mode & 0o077 != 0 }
    static func isWorldReadable(_ mode: UInt16) -> Bool { mode & 0o004 != 0 }
    /// Dosya türü bitleri atılır: 0o100644 → "644".
    static func octal(_ mode: UInt16) -> String { String(mode & 0o777, radix: 8) }
}

/// `.env` dosyalarını tanır ve sır içeren satırların yalnızca anahtar adını ve değer uzunluğunu verir.
enum EnvFile {
    struct Secret: Equatable {
        let key: String
        let valueLength: Int
        /// Değer tanınan bir jeton biçimindeyse sağlayıcı adı. Değerin kendisi tutulmaz.
        var token: String? = nil
    }

    private static let templateSuffixes: Set<String> = ["example", "sample", "dist", "template", "defaults"]
    private static let secretWords = [
        "SECRET", "TOKEN", "PASSWORD", "PASSWD", "PRIVATE_KEY", "API_KEY", "APIKEY", "ACCESS_KEY", "APP_KEY", "CREDENTIAL",
    ]
    private static let placeholders: Set<String> = [
        "null", "none", "changeme", "change-me", "change_me", "secret", "password", "todo", "xxx", "your-key", "undefined",
    ]

    static func isEnvFileName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if lower == ".env" { return true }
        guard lower.hasPrefix(".env.") else { return false }
        return !templateSuffixes.contains(String(lower.dropFirst(5)))
    }

    static func secrets(in text: String) -> [Secret] {
        var result: [Secret] = []
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)).trimmingCharacters(in: .whitespaces) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            guard isValidKey(key) else { continue }
            let value = unquote(line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces))
            let token = TokenPattern.match(value)
            guard isSecretKey(key) || token != nil, !isPlaceholder(value) else { continue }
            result.append(Secret(key: key, valueLength: value.count, token: token))
        }
        return result
    }

    private static func isValidKey(_ key: String) -> Bool {
        guard let first = key.unicodeScalars.first, first == "_" || (first.isASCII && CharacterSet.letters.contains(first)) else { return false }
        return key.unicodeScalars.allSatisfy { $0 == "_" || ($0.isASCII && CharacterSet.alphanumerics.contains($0)) }
    }

    private static func isSecretKey(_ key: String) -> Bool {
        let upper = key.uppercased()
        if upper.contains("PUBLIC") { return false }
        if secretWords.contains(where: upper.contains) { return true }
        return upper.hasSuffix("_KEY") || upper.hasSuffix("_PASS") || upper == "PASS"
    }

    private static func unquote(_ value: String) -> String {
        if value.count >= 2, let first = value.first, first == "\"" || first == "'", value.last == first {
            return String(value.dropFirst().dropLast())
        }
        if let comment = value.range(of: " #") { return String(value[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return value
    }

    private static func isPlaceholder(_ value: String) -> Bool {
        if value.isEmpty { return true }
        let lower = value.lowercased()
        if placeholders.contains(lower) || lower.hasPrefix("your") || lower.hasPrefix("<") || lower.hasPrefix("$") || lower.contains("${") {
            return true
        }
        return value.count >= 3 && Set(value).count == 1
    }
}

struct KeyInspection: Equatable {
    let isEncrypted: Bool
}

/// Dosya başlığına bakıp özel anahtar olup olmadığını ve parolalı olup olmadığını söyler. Anahtar içeriğini ayrıştırmaz.
enum PrivateKey {
    static func inspect(_ text: String) -> KeyInspection? {
        guard let begin = text.range(of: "-----BEGIN "),
              let headerEnd = text.range(of: "-----", range: begin.upperBound..<text.endIndex) else { return nil }
        let label = String(text[begin.upperBound..<headerEnd.lowerBound])
        guard label.hasSuffix("PRIVATE KEY") else { return nil }
        if label == "ENCRYPTED PRIVATE KEY" { return KeyInspection(isEncrypted: true) }
        if label == "OPENSSH PRIVATE KEY" {
            let body = text[headerEnd.upperBound...].components(separatedBy: "-----END").first ?? ""
            return KeyInspection(isEncrypted: opensshIsEncrypted(body))
        }
        return KeyInspection(isEncrypted: text.contains("ENCRYPTED"))
    }

    /// `openssh-key-v1` gövdesindeki şifre adı `none` ise anahtar parolasızdır. Çözülemezse parolalı varsayılır.
    private static func opensshIsEncrypted(_ body: String) -> Bool {
        let compact = body.filter { !$0.isWhitespace }
        let head = compact.prefix(120)
        let usable = String(head.dropLast(head.count % 4))
        guard let data = Data(base64Encoded: usable) else { return true }
        let bytes = [UInt8](data)
        let magic = Array("openssh-key-v1".utf8) + [0]
        guard bytes.count >= magic.count + 4, Array(bytes.prefix(magic.count)) == magic else { return true }
        let offset = magic.count
        let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
        guard length > 0, length < 64, bytes.count >= offset + 4 + length else { return true }
        let cipher = String(decoding: bytes[(offset + 4)..<(offset + 4 + length)], as: UTF8.self)
        return cipher != "none"
    }
}

struct SSHEntry {
    let path: String
    let mode: UInt16
    /// Dosyanın ilk baytları. Okunamadıysa boş.
    let head: String
}

/// `~/.ssh` altındaki bir özel anahtar. Bulgu değildir: izni doğru ve parolalı anahtar da listelenir. İçerik tutulmaz.
struct SSHKeyInfo: Identifiable, Equatable {
    let path: String
    let mode: UInt16
    let isEncrypted: Bool

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    var isLoose: Bool { FileMode.isGroupOrWorldAccessible(mode) }
}

/// `.pub` dosyasından kopyalanacak açık anahtar satırı. Yalnızca tek satırlık, tanınan türde bir açık anahtar kabul edilir.
/// Dosyada özel anahtar veya başka içerik varsa nil döner. Böylece yanlış adlandırılmış bir dosya panoya sızmaz.
enum PublicKey {
    private static let types = ["ssh-ed25519", "ssh-rsa", "ssh-dss", "ecdsa-sha2-", "sk-ssh-ed25519@openssh.com", "sk-ecdsa-sha2-"]
    static let maxBytes = 8 * 1_024

    static func line(from text: String) -> String? {
        guard !text.contains("PRIVATE KEY") else { return nil }
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard lines.count == 1, let line = lines.first, types.contains(where: { line.hasPrefix($0) }),
              line.split(separator: " ").count >= 2 else { return nil }
        return line
    }

    /// Anahtar dosyasının yanındaki `.pub` dosyasını okur. Dosya yoksa, büyükse veya açık anahtar değilse nil döner.
    static func load(forKeyAt path: String) -> String? {
        let publicPath = path + ".pub"
        guard let size = (try? FileManager.default.attributesOfItem(atPath: publicPath))?[.size] as? NSNumber, size.intValue <= maxBytes,
              let data = FileManager.default.contents(atPath: publicPath) else { return nil }
        return line(from: String(decoding: data, as: UTF8.self))
    }
}

/// Sırlar sayfasındaki arama. Her sözcük küçük harf ve aksan farkı gözetmeden aranır.
enum SecretSearch {
    static func matches(_ finding: SecretFinding, query: String) -> Bool {
        matches(haystack: [finding.kind.title, finding.path, finding.detail], query: query)
    }

    static func matches(_ key: SSHKeyInfo, query: String) -> Bool {
        matches(haystack: [key.path, "ssh key anahtar özel anahtar", key.isEncrypted ? "parolalı" : "parolasız", "izin \(FileMode.octal(key.mode))"],
                query: query)
    }

    private static func matches(haystack: [String], query: String) -> Bool {
        let words = AlertFilter.fold(query).split(whereSeparator: \.isWhitespace)
        guard !words.isEmpty else { return true }
        let text = AlertFilter.fold(haystack.joined(separator: " "))
        return words.allSatisfy { text.contains($0) }
    }
}

enum SSHAudit {
    /// Özel anahtar dosyaları. İzin ve parola durumuna bakılmaksızın hepsi döner.
    static func keys(entries: [SSHEntry]) -> [SSHKeyInfo] {
        entries.compactMap { entry in
            PrivateKey.inspect(entry.head).map { SSHKeyInfo(path: entry.path, mode: entry.mode, isEncrypted: $0.isEncrypted) }
        }
    }

    static func evaluate(dirPath: String, dirMode: UInt16, entries: [SSHEntry]) -> [SecretFinding] {
        var findings: [SecretFinding] = []
        if FileMode.isGroupOrWorldAccessible(dirMode) {
            findings.append(SecretFinding(kind: .sshDirectoryPermissions, severity: .medium, path: dirPath,
                                          detail: "izin \(FileMode.octal(dirMode)), beklenen 700"))
        }
        for entry in entries {
            guard let key = PrivateKey.inspect(entry.head) else { continue }
            if FileMode.isGroupOrWorldAccessible(entry.mode) {
                findings.append(SecretFinding(kind: .privateKeyPermissions, severity: .high, path: entry.path,
                                              detail: "izin \(FileMode.octal(entry.mode)), beklenen 600"))
            } else if !key.isEncrypted {
                findings.append(SecretFinding(kind: .unencryptedPrivateKey, severity: .info, path: entry.path,
                                              detail: "Anahtar parolasız. Ajan veya Anahtar Zinciri kullanın."))
            }
        }
        return findings
    }
}

/// Ev klasöründeki bilinen kimlik bilgisi dosyaları. `needles` dosyada gerçekten kimlik bilgisi olduğunu gösterir.
struct CredentialSpec {
    let relativePath: String
    let plaintext: Bool
    let needles: [String]

    static let all: [CredentialSpec] = [
        CredentialSpec(relativePath: ".git-credentials", plaintext: true, needles: ["://"]),
        CredentialSpec(relativePath: ".netrc", plaintext: false, needles: ["password"]),
        CredentialSpec(relativePath: ".npmrc", plaintext: false, needles: ["_authtoken"]),
        CredentialSpec(relativePath: ".aws/credentials", plaintext: false, needles: ["aws_secret_access_key"]),
        CredentialSpec(relativePath: ".docker/config.json", plaintext: false, needles: ["\"auth\":"]),
        CredentialSpec(relativePath: ".config/gh/hosts.yml", plaintext: false, needles: ["oauth_token"]),
        CredentialSpec(relativePath: ".pypirc", plaintext: false, needles: ["password"]),
    ]
}

enum CredentialAudit {
    static func evaluate(path: String, spec: CredentialSpec, mode: UInt16, head: String) -> SecretFinding? {
        let lower = head.lowercased()
        guard spec.needles.contains(where: lower.contains) else { return nil }
        if FileMode.isGroupOrWorldAccessible(mode) {
            return SecretFinding(kind: .credentialWorldReadable, severity: .high, path: path,
                                 detail: "izin \(FileMode.octal(mode)), beklenen 600")
        }
        if spec.plaintext {
            return SecretFinding(kind: .plaintextCredentialStore, severity: .medium, path: path,
                                 detail: "Parola düz metin olarak saklanıyor.")
        }
        return SecretFinding(kind: .credentialFile, severity: .info, path: path,
                             detail: "Kimlik bilgisi içeriyor. İzin 600, yalnızca siz okursunuz.")
    }
}

struct GitStatus: Equatable {
    let inRepo: Bool
    let tracked: Bool
    let ignored: Bool
}

enum EnvAudit {
    private static let shownKeys = 5

    /// En çok 5 anahtar adı gösterilir. Fazlası "+N" olur. Değer hiçbir zaman yazılmaz.
    private static func keyList(_ secrets: [EnvFile.Secret]) -> String {
        let names = secrets.prefix(shownKeys).map { secret in secret.token.map { "\(secret.key) (\($0))" } ?? secret.key }.joined(separator: ", ")
        let extra = secrets.count - shownKeys
        return extra > 0 ? "\(names) +\(extra)" : names
    }

    static func evaluate(path: String, secrets: [EnvFile.Secret], mode: UInt16, git: GitStatus, inHistory: Bool = false) -> [SecretFinding] {
        guard !secrets.isEmpty else { return [] }
        let keys = keyList(secrets)
        var findings: [SecretFinding] = []
        if git.tracked {
            findings.append(SecretFinding(kind: .envTracked, severity: .high, path: path, detail: "git'e eklenmiş. Sırlar: \(keys)"))
        } else if git.inRepo && !git.ignored {
            findings.append(SecretFinding(kind: .envNotIgnored, severity: .medium, path: path, detail: "Commit edilebilir. Sırlar: \(keys)"))
        }
        if git.inRepo && !git.tracked && inHistory {
            findings.append(SecretFinding(kind: .envInHistory, severity: .medium, path: path,
                                          detail: "Eski commit'lerde bulundu. Sırlar: \(keys)"))
        }
        if FileMode.isWorldReadable(mode) {
            findings.append(SecretFinding(kind: .envWorldReadable, severity: .high, path: path,
                                          detail: "izin \(FileMode.octal(mode)), beklenen 600. Sırlar: \(keys)"))
        }
        return findings
    }
}

/// Bilinen jeton biçimleri. Yalnızca sağlayıcı adı döner. Değer saklanmaz ve gösterilmez.
enum TokenPattern {
    private static let patterns: [(name: String, regex: NSRegularExpression)] = [
        ("GitHub", "^(gh[pousr]_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,})$"),
        ("Stripe", "^[rs]k_live_[A-Za-z0-9]{24,}$"),
        ("Slack", "^xox[abprs]-[A-Za-z0-9-]{10,}$"),
        ("AWS", "^(AKIA|ASIA)[A-Z0-9]{16}$"),
        ("Google", "^AIza[A-Za-z0-9_-]{35}$"),
        ("GitLab", "^glpat-[A-Za-z0-9_-]{20,}$"),
        ("npm", "^npm_[A-Za-z0-9]{36}$"),
        ("Anthropic", "^sk-ant-[A-Za-z0-9_-]{20,}$"),
        ("OpenAI", "^sk-(proj-)?[A-Za-z0-9_-]{32,}$"),
    ].compactMap { name, pattern in (try? NSRegularExpression(pattern: pattern)).map { (name, $0) } }

    static var providerNames: [String] { patterns.map(\.name) }

    static func rotationHint(for provider: String) -> String? {
        switch provider {
        case "GitHub": return "GitHub: jetonu Settings > Developer settings bölümünden iptal edip yenisini üretin."
        case "Stripe": return "Stripe: anahtarı Dashboard > Developers > API keys bölümünde yenileyin."
        case "Slack": return "Slack: jetonu uygulamanın ayar sayfasından iptal edip yenisini üretin."
        case "AWS": return "AWS: erişim anahtarını IAM konsolunda devre dışı bırakıp yenisini üretin."
        case "Google": return "Google: anahtarı Cloud Console > Credentials bölümünde silip yenisini üretin."
        case "GitLab": return "GitLab: jetonu Preferences > Access tokens bölümünden iptal edin."
        case "npm": return "npm: jetonu npmjs.com hesap ayarlarından iptal edip yenisini üretin."
        case "Anthropic": return "Anthropic: anahtarı Console > API keys bölümünden silip yenisini üretin."
        case "OpenAI": return "OpenAI: anahtarı platform ayarlarındaki API keys bölümünden iptal edin."
        default: return nil
        }
    }

    static func match(_ value: String) -> String? {
        let range = NSRange(value.startIndex..., in: value)
        return patterns.first { $0.regex.firstMatch(in: value, range: range) != nil }?.name
    }
}
