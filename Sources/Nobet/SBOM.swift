import Foundation

/// Yazılım bileşeni. Yalnızca ad, sürüm ve ekosistem tutar. Dosya yolu tutmaz.
struct SBOMComponent: Hashable {
    enum Ecosystem: String, CaseIterable {
        case npm, composer, pypi, swift

        var title: String {
            switch self {
            case .npm: return "npm"
            case .composer: return "Composer"
            case .pypi: return "PyPI"
            case .swift: return "Swift"
            }
        }
    }

    let ecosystem: Ecosystem
    let name: String
    let version: String

    /// Package URL (purl). npm kapsam işareti `@` yüzde ile yazılır.
    var purl: String {
        let escaped = name.replacingOccurrences(of: "@", with: "%40")
        switch ecosystem {
        case .npm: return "pkg:npm/\(escaped)@\(version)"
        case .composer: return "pkg:composer/\(name)@\(version)"
        case .pypi: return "pkg:pypi/\(name.lowercased())@\(version)"
        case .swift: return "pkg:swift/\(name)@\(version)"
        }
    }
}

/// Kilit dosyalarından bileşen çıkarır. Bozuk veya beklenmeyen içerik boş sonuç verir.
enum LockfileParser {
    private static func finish(_ items: [SBOMComponent]) -> [SBOMComponent] {
        Array(Set(items)).sorted { ($0.name, $0.version) < ($1.name, $1.version) }
    }

    static func npm(_ data: Data) -> [SBOMComponent] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        var items: [SBOMComponent] = []
        if let packages = root["packages"] as? [String: [String: Any]] {
            for (path, value) in packages where !path.isEmpty && value["link"] as? Bool != true {
                guard let version = value["version"] as? String, let range = path.range(of: "node_modules/", options: .backwards) else { continue }
                items.append(SBOMComponent(ecosystem: .npm, name: String(path[range.upperBound...]), version: version))
            }
        } else if let dependencies = root["dependencies"] as? [String: [String: Any]] {
            func walk(_ map: [String: [String: Any]]) {
                for (name, value) in map {
                    if let version = value["version"] as? String { items.append(SBOMComponent(ecosystem: .npm, name: name, version: version)) }
                    if let nested = value["dependencies"] as? [String: [String: Any]] { walk(nested) }
                }
            }
            walk(dependencies)
        }
        return finish(items)
    }

    static func composer(_ data: Data) -> [SBOMComponent] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        var items: [SBOMComponent] = []
        for key in ["packages", "packages-dev"] {
            for package in root[key] as? [[String: Any]] ?? [] {
                guard let name = package["name"] as? String, var version = package["version"] as? String else { continue }
                if version.count > 1, version.hasPrefix("v") || version.hasPrefix("V"), version.dropFirst().first?.isNumber == true { version.removeFirst() }
                items.append(SBOMComponent(ecosystem: .composer, name: name, version: version))
            }
        }
        return finish(items)
    }

    /// Uzak adres `host/yol` biçimine indirilir. `https://` öneki ve `.git` soneki atılır.
    private static func repositoryName(_ location: String) -> String {
        var text = location
        if let scheme = text.range(of: "://") {
            text = String(text[scheme.upperBound...])
        } else if text.hasPrefix("git@") {
            text = String(text.dropFirst(4)).replacingOccurrences(of: ":", with: "/")
        }
        return text.hasSuffix(".git") ? String(text.dropLast(4)) : text
    }

    static func swiftResolved(_ data: Data) -> [SBOMComponent] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [] }
        let pins = root["pins"] as? [[String: Any]] ?? (root["object"] as? [String: Any])?["pins"] as? [[String: Any]] ?? []
        let items = pins.compactMap { pin -> SBOMComponent? in
            guard let state = pin["state"] as? [String: Any], let version = state["version"] as? String,
                  let location = pin["location"] as? String ?? pin["repositoryURL"] as? String else { return nil }
            return SBOMComponent(ecosystem: .swift, name: repositoryName(location), version: version)
        }
        return finish(items)
    }

    private static let requirementLine = try? NSRegularExpression(pattern: #"^([A-Za-z0-9][A-Za-z0-9._-]*)(\[[^\]]*\])?\s*==\s*([A-Za-z0-9._+!-]+)"#)

    static func requirements(_ text: String) -> [SBOMComponent] {
        let items = text.split(whereSeparator: \.isNewline).compactMap { raw -> SBOMComponent? in
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("-") { return nil }
            if let marker = line.firstIndex(of: ";") { line = String(line[..<marker]).trimmingCharacters(in: .whitespaces) }
            let range = NSRange(line.startIndex..., in: line)
            guard let match = requirementLine?.firstMatch(in: line, range: range),
                  let name = Range(match.range(at: 1), in: line), let version = Range(match.range(at: 3), in: line) else { return nil }
            // PEP 503: küçük harf, ayraçlar tek tire.
            let normalized = String(line[name]).lowercased().replacingOccurrences(of: "[-_.]+", with: "-", options: .regularExpression)
            return SBOMComponent(ecosystem: .pypi, name: normalized, version: String(line[version]))
        }
        return finish(items)
    }
}

/// CycloneDX 1.5 JSON. Yol, sunucu adı veya kullanıcı bilgisi içermez.
enum CycloneDX {
    static func json(_ items: [SBOMComponent], date: Date) -> String {
        let components = items.map { ["type": "library", "name": $0.name, "version": $0.version, "purl": $0.purl] }
        let document: [String: Any] = [
            "bomFormat": "CycloneDX",
            "specVersion": "1.5",
            "version": 1,
            "metadata": ["timestamp": ISO8601DateFormatter().string(from: date), "tools": [["name": "Nobet"]]],
            "components": components,
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) else {
            return "{}"
        }
        return String(decoding: data, as: UTF8.self)
    }
}

protocol VulnLookup: Sendable {
    /// Bileşen başına bilinen açık kimlikleri döner. Ağ veya yanıt hatasında `nil`.
    func lookup(_ components: [SBOMComponent]) async -> [SBOMComponent: [String]]?
}

/// OSV.dev toplu sorgusu. Yalnızca ekosistem, paket adı ve sürüm gönderilir.
enum OSVClient {
    static let batchLimit = 1000

    private static func ecosystemName(_ ecosystem: SBOMComponent.Ecosystem) -> String? {
        switch ecosystem {
        case .npm: return "npm"
        case .composer: return "Packagist"
        case .pypi: return "PyPI"
        case .swift: return nil
        }
    }

    static func queryable(_ items: [SBOMComponent]) -> [SBOMComponent] { items.filter { ecosystemName($0.ecosystem) != nil } }

    static func batches(_ items: [SBOMComponent]) -> [[SBOMComponent]] {
        stride(from: 0, to: items.count, by: batchLimit).map { Array(items[$0..<min(items.count, $0 + batchLimit)]) }
    }

    static func requestBody(for items: [SBOMComponent]) -> Data {
        let queries = items.compactMap { item -> [String: Any]? in
            ecosystemName(item.ecosystem).map { ["package": ["name": item.name, "ecosystem": $0], "version": item.version] }
        }
        return (try? JSONSerialization.data(withJSONObject: ["queries": queries])) ?? Data()
    }

    /// Yanıt dizisi sorgu sırasıyla eşleşir.
    static func parse(_ data: Data, for items: [SBOMComponent]) -> [SBOMComponent: [String]]? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let results = root["results"] as? [[String: Any]] else { return nil }
        var map: [SBOMComponent: [String]] = [:]
        for (item, result) in zip(items, results) {
            let ids = (result["vulns"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
            if !ids.isEmpty { map[item] = ids }
        }
        return map
    }
}

struct OSVLookup: VulnLookup {
    static let endpoint = URL(string: "https://api.osv.dev/v1/querybatch")!

    func lookup(_ components: [SBOMComponent]) async -> [SBOMComponent: [String]]? {
        var merged: [SBOMComponent: [String]] = [:]
        for batch in OSVClient.batches(OSVClient.queryable(components)) {
            var request = URLRequest(url: Self.endpoint, timeoutInterval: 20)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = OSVClient.requestBody(for: batch)
            guard let (data, response) = try? await URLSession.shared.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200,
                  let map = OSVClient.parse(data, for: batch) else { return nil }
            merged.merge(map) { $1 }
        }
        return merged
    }
}

/// Proje klasörlerindeki kilit dosyalarını bulur. Bağımlılık klasörlerine girmez.
enum SBOMScanner {
    static let maxFileBytes = 8 * 1024 * 1024
    static let maxDepth = 4
    static let maxEntries = 100_000
    private static let skipped: Set<String> = ["node_modules", "vendor", ".build", ".git", "Pods", "DerivedData", ".venv", "venv"]

    static func scan(roots: [String], deadline: Date = Date().addingTimeInterval(20)) -> [SBOMComponent] {
        var items = Set<SBOMComponent>()
        var entries = 0
        for root in Set(roots) {
            let base = URL(fileURLWithPath: root)
            guard let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey]) else { continue }
            for case let url as URL in walker {
                entries += 1
                if entries > maxEntries || Date() > deadline { break }
                let depth = url.pathComponents.count - base.pathComponents.count
                let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
                if values?.isDirectory == true {
                    if skipped.contains(url.lastPathComponent) || depth >= maxDepth { walker.skipDescendants() }
                    continue
                }
                guard (values?.fileSize ?? 0) <= maxFileBytes else { continue }
                items.formUnion(parse(url))
            }
        }
        return items.sorted { ($0.ecosystem.rawValue, $0.name, $0.version) < ($1.ecosystem.rawValue, $1.name, $1.version) }
    }

    private static func parse(_ url: URL) -> [SBOMComponent] {
        let parser: (Data) -> [SBOMComponent]
        switch url.lastPathComponent {
        case "package-lock.json": parser = LockfileParser.npm
        case "composer.lock": parser = LockfileParser.composer
        case "Package.resolved": parser = LockfileParser.swiftResolved
        case "requirements.txt": parser = { LockfileParser.requirements(String(decoding: $0, as: UTF8.self)) }
        default: return []
        }
        return (try? Data(contentsOf: url)).map(parser) ?? []
    }
}

/// Bağımlılık envanteri ve isteğe bağlı açık sorgusu. Sorgu varsayılan olarak kapalıdır.
@MainActor
final class SBOMModel: ObservableObject {
    static let shared = SBOMModel(lookup: OSVLookup(), alerts: .shared)
    static let lookupKey = "sbom.lookup"

    @Published private(set) var components: [SBOMComponent] = []
    @Published private(set) var vulnerabilities: [SBOMComponent: [String]] = [:]
    @Published private(set) var scanning = false
    @Published private(set) var scanned = false
    @Published private(set) var lookupFailed = false

    private let defaults: UserDefaults
    private let lookup: VulnLookup
    private let alerts: AlertCenter?

    init(defaults: UserDefaults = .standard, lookup: VulnLookup, alerts: AlertCenter? = nil) {
        self.defaults = defaults
        self.lookup = lookup
        self.alerts = alerts
    }

    var lookupEnabled: Bool { defaults.bool(forKey: Self.lookupKey) }

    func setLookup(_ enabled: Bool, roots: [String]) {
        defaults.set(enabled, forKey: Self.lookupKey)
        rescan(roots: roots)
    }

    func rescan(roots: [String]) {
        guard !scanning else { return }
        scanning = true
        Task {
            let found = await Task.detached(priority: .utility) { SBOMScanner.scan(roots: roots) }.value
            await apply(components: found)
            scanning = false
        }
    }

    func apply(components found: [SBOMComponent]) async {
        components = found
        scanned = true
        if lookupEnabled {
            let result = await lookup.lookup(found)
            lookupFailed = result == nil
            vulnerabilities = result ?? vulnerabilities
        } else {
            lookupFailed = false
            vulnerabilities = [:]
        }
        alerts?.ingest(module: "sbom", issues: Self.alertIssues(vulnerabilities))
    }

    /// Açığı olan her bileşen orta önemli sorundur. Açık kimlikleri bildirime girmez.
    nonisolated static func alertIssues(_ vulnerabilities: [SBOMComponent: [String]]) -> [AlertIssue] {
        vulnerabilities.keys.sorted { ($0.name, $0.version) < ($1.name, $1.version) }.map {
            AlertIssue(key: "sbom|\($0.ecosystem.rawValue)|\(AlertKey.digest($0.name))|\($0.version)", module: "sbom",
                       subject: "\($0.name) \($0.version)", title: "Açığı olan bağımlılık", severity: .medium)
        }
    }
}

/// Bağımlılık listesi süzgeci: ekosistem, ad veya sürüm metni, yalnızca açığı olanlar.
struct SBOMFilter: Equatable {
    enum Dimension { case ecosystem, text, vulnerable }

    struct Chip: Equatable, Identifiable {
        let dimension: Dimension
        let title: String
        var id: String { title }
    }

    var ecosystems: Set<SBOMComponent.Ecosystem> = []
    var text = ""
    var onlyVulnerable = false

    private var query: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    var isActive: Bool { !ecosystems.isEmpty || !query.isEmpty || onlyVulnerable }

    func apply(_ items: [SBOMComponent], vulnerabilities: [SBOMComponent: [String]]) -> [SBOMComponent] {
        let needle = AlertFilter.fold(query)
        return items.filter { item in
            if !ecosystems.isEmpty, !ecosystems.contains(item.ecosystem) { return false }
            if onlyVulnerable, vulnerabilities[item]?.isEmpty != false { return false }
            guard !needle.isEmpty else { return true }
            return AlertFilter.fold(item.name).contains(needle) || AlertFilter.fold(item.version).contains(needle)
        }
    }

    var chips: [Chip] {
        var result: [Chip] = []
        if !ecosystems.isEmpty {
            let names = ecosystems.sorted { $0.rawValue < $1.rawValue }.map(\.title).joined(separator: ", ")
            result.append(Chip(dimension: .ecosystem, title: "Ekosistem: \(names)"))
        }
        if !query.isEmpty { result.append(Chip(dimension: .text, title: "Ara: \(query)")) }
        if onlyVulnerable { result.append(Chip(dimension: .vulnerable, title: "Yalnızca açığı olanlar")) }
        return result
    }

    func removing(_ dimension: Dimension) -> SBOMFilter {
        var next = self
        switch dimension {
        case .ecosystem: next.ecosystems = []
        case .text: next.text = ""
        case .vulnerable: next.onlyVulnerable = false
        }
        return next
    }

    func cleared() -> SBOMFilter { SBOMFilter() }
}
