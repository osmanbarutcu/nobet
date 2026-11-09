import Foundation

/// Kurulmuş bir TCP bağlantısı. Bir süreç, yerel port ve uzak uç.
struct NetworkConnection: Identifiable, Equatable {
    /// Uzak ucun erişim sınıfı. Sıra: dış adresler önce, yerel makine en sonda.
    enum Reach: Int, Comparable {
        case external, local, loopback

        var label: String {
            switch self {
            case .external: return "Dış ağ"
            case .local: return "Yerel ağ"
            case .loopback: return "Bu makine"
            }
        }

        static func < (lhs: Reach, rhs: Reach) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let pid: Int
    let process: String
    let localPort: Int
    let remoteHost: String
    let remotePort: Int

    var id: String { "\(pid)/\(localPort)/\(remoteHost)/\(remotePort)" }
    var reach: Reach { Self.reach(of: remoteHost) }

    /// PID ve port kimliktir, binlik ayraç almaz. Bu yüzden düz String kurulur.
    var detail: String { "PID \(pid) · :\(localPort) → \(remoteHost):\(remotePort)" }

    /// Adresi sınıflar. IPv4 özel aralıkları, bağlantı yerel IPv6 ve ULA yerel sayılır.
    static func reach(of host: String) -> Reach {
        let text = host.lowercased()
        if text == "::1" || text.hasPrefix("127.") { return .loopback }
        if text.hasPrefix("::ffff:"), text.contains(".") { return reach(of: String(text.dropFirst(7))) }
        if text.contains(":") {
            let linkLocal = ["fe8", "fe9", "fea", "feb"].contains { text.hasPrefix($0) }
            return linkLocal || text.hasPrefix("fc") || text.hasPrefix("fd") ? .local : .external
        }
        let octets = text.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else { return .external }
        switch (octets[0], octets[1]) {
        case (10, _), (192, 168), (169, 254): return .local
        case (172, 16...31): return .local
        case (100, 64...127): return .local
        default: return .external
        }
    }
}

/// Kurulmuş TCP bağlantılarını listeler. Yalnızca `lsof` çıktısını okur. Tarama süreçleri kapatmaz.
enum NetworkScan {
    /// `lsof -F pcn` çıktısını ayrıştırır. Ok içermeyen satırlar (dinleyiciler) atlanır.
    /// Dış adresler önce gelir, sonra süreç adı ve port sırası.
    static func parse(_ output: String) -> [NetworkConnection] {
        var pid: Int?
        var process = ""
        var seen = Set<String>()
        var result: [NetworkConnection] = []
        for line in output.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p":
                pid = Int(value)
                process = ""
            case "c":
                process = value.replacingOccurrences(of: "\\x20", with: " ")
            case "n":
                guard let pid, let connection = connection(value, pid: pid, process: process) else { continue }
                if seen.insert(connection.id).inserted { result.append(connection) }
            default:
                continue
            }
        }
        return result.sorted {
            ($0.reach, $0.process.lowercased(), $0.pid, $0.localPort) < ($1.reach, $1.process.lowercased(), $1.pid, $1.localPort)
        }
    }

    /// "192.168.1.5:50000->93.184.216.34:443". Ok yoksa veya bir port sayı değilse nil döner.
    private static func connection(_ text: String, pid: Int, process: String) -> NetworkConnection? {
        guard let arrow = text.range(of: "->"),
              let local = PortScan.endpoint(String(text[..<arrow.lowerBound])),
              let remote = PortScan.endpoint(String(text[arrow.upperBound...]))
        else { return nil }
        return NetworkConnection(pid: pid, process: process, localPort: local.port, remoteHost: remote.host, remotePort: remote.port)
    }

    /// `lsof` yoksa veya 8 saniyede bitmezse boş döner.
    nonisolated static func scan() -> [NetworkConnection] {
        guard let result = DevRunner.run("/usr/sbin/lsof", ["-nP", "-iTCP", "-sTCP:ESTABLISHED", "-F", "pcn"], timeout: 8) else { return [] }
        return parse(result.output)
    }
}
