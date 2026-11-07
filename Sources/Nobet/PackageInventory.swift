import Foundation

/// Sunucuda kurulu bir paket. Değerler sunucudan gelir ve yalnızca gösterilir.
struct InstalledPackage: Equatable, Identifiable {
    let name: String
    let version: String

    var id: String { name }
}

/// İstek üzerine paket listesini okuyan kaynak. Yalnızca okur, hiçbir şey kurmaz veya silmez.
protocol PackageListing: Sendable {
    func packages(_ profile: SSHProfile, password: String?) async -> Result<[InstalledPackage], SSHFailure>
}

enum PackageInventory {
    static let limit = 5000

    /// Satır biçimi: `ad sürüm`. Boş, eksik, fazla alanlı veya güvensiz karakterli satır atılır.
    static func parse(_ text: String) -> [InstalledPackage] {
        var items: [InstalledPackage] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 2, isSafe(String(fields[0]), extra: "+.-_:@"), isSafe(String(fields[1]), extra: "+.-_:~^") else { continue }
            items.append(InstalledPackage(name: String(fields[0]), version: String(fields[1])))
            if items.count >= limit { break }
        }
        return items.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    static func filter(_ items: [InstalledPackage], text: String) -> [InstalledPackage] {
        let needle = AlertFilter.fold(text.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty else { return items }
        return items.filter { AlertFilter.fold($0.name).contains(needle) }
    }

    private static func isSafe(_ value: String, extra: String) -> Bool {
        !value.isEmpty && value.count <= 100 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || extra.contains($0)) }
    }
}

extension RemoteScript {
    /// Salt okunur paket listesi. Önce dpkg, yoksa rpm. İkisi de yoksa çıktı boş kalır.
    static let packages = [
        "if command -v dpkg-query >/dev/null 2>&1; then dpkg-query -W -f='${Package} ${Version}\\n' 2>/dev/null;",
        "elif command -v rpm >/dev/null 2>&1; then rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}\\n' 2>/dev/null; fi",
    ].joined(separator: " ")
}
