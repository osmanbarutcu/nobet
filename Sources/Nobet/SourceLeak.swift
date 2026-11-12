import Foundation

/// Kaynak kod ve yapılandırma dosyalarında gömülü jeton arar. Yalnızca bilinen sağlayıcı biçimlerini tanır.
/// Bulguda satır numarası ve sağlayıcı adı yer alır. Jetonun değeri hiçbir yerde saklanmaz veya gösterilmez.
enum SourceLeak {
    static let maxFileBytes = 256 * 1_024
    static let maxLineLength = 2_000
    static let maxListed = 5
    static let maxFiles = 20_000

    struct Hit: Equatable {
        let line: Int
        let provider: String
    }

    private static let extensions: Set<String> = [
        "swift", "js", "mjs", "cjs", "ts", "tsx", "jsx", "py", "rb", "php", "go", "rs", "java", "kt", "cs", "c", "h", "cpp", "m",
        "sh", "zsh", "bash", "yml", "yaml", "json", "toml", "ini", "cfg", "conf", "properties", "tf", "gradle", "xml", "plist",
    ]
    private static let specialNames: Set<String> = ["dockerfile", "makefile", "docker-compose.yml"]
    private static let skippedNames: Set<String> = [
        "package-lock.json", "composer.lock", "package.resolved", "yarn.lock", "pnpm-lock.yaml", "cargo.lock", "poetry.lock",
    ]
    /// Jeton adayı: harf, rakam, alt çizgi ve tireden oluşan en az 20 karakterlik sözcük.
    private static let candidate = try? NSRegularExpression(pattern: "[A-Za-z0-9_-]{20,}")

    /// `.env` dosyaları ayrı denetlenir. Kilit dosyaları ve küçültülmüş betikler gürültü üretir.
    static func isScannable(fileName: String) -> Bool {
        let name = fileName.lowercased()
        guard !name.hasPrefix(".env"), !skippedNames.contains(name), !name.hasSuffix(".min.js"), !name.hasSuffix(".min.css") else { return false }
        if specialNames.contains(name) { return true }
        return extensions.contains((name as NSString).pathExtension)
    }

    static func hits(in text: String) -> [Hit] {
        guard let candidate else { return [] }
        var found: [Hit] = []
        for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() where line.count <= maxLineLength {
            let value = String(line)
            let range = NSRange(value.startIndex..., in: value)
            for match in candidate.matches(in: value, range: range) {
                guard let word = Range(match.range, in: value), let provider = TokenPattern.match(String(value[word])) else { continue }
                found.append(Hit(line: index + 1, provider: provider))
            }
        }
        return found
    }

    static func finding(path: String, text: String) -> SecretFinding? {
        let all = hits(in: text)
        guard !all.isEmpty else { return nil }
        let listed = all.prefix(maxListed).map { "\($0.line) (\($0.provider))" }.joined(separator: ", ")
        let extra = all.count - maxListed
        let detail = "Satır \(listed)\(extra > 0 ? " +\(extra)" : ""). Gerçek jeton değilse Yok say."
        return SecretFinding(kind: .sourceToken, severity: .medium, path: path, detail: detail)
    }
}
