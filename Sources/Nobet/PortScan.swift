import Foundation

struct ListeningPort: Identifiable, Equatable {
    enum Scope: Int, Comparable {
        case all, interface, local

        var label: String {
            switch self {
            case .all: return "Tüm ağa açık"
            case .interface: return "Ağ arayüzü"
            case .local: return "Yerel"
            }
        }

        static func < (lhs: Scope, rhs: Scope) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let pid: Int
    let process: String
    let address: String
    let port: Int
    let scope: Scope
    var id: String { "\(pid)/\(port)/\(scope.rawValue)" }

    /// Satır altı metni. PID ve port kimliktir, binlik ayraç almaz.
    /// `Text("\(sayı)")` tamsayıyı yerel ayara göre biçimler (8001 → 8.001). Bu yüzden düz String kurulur.
    var detail: String { "PID \(pid) · \(address):\(port)" }
}

/// Aynı port numarasını birden çok süreç dinliyor.
struct PortConflict: Equatable, Identifiable {
    let port: Int
    let processes: [String]
    var id: Int { port }
}

/// Dinleyen TCP portlarını listeler. Yalnızca `lsof` çıktısını okur. Tarama süreçleri kapatmaz.
enum PortScan {
    private static let wildcards: Set<String> = ["*", "0.0.0.0", "::"]

    /// `lsof -F pcn` çıktısını ayrıştırır. Aynı süreç ve portun IPv4 ve IPv6 kayıtları tek satıra iner.
    /// En geniş erişim önce gelir, sonra port sırası.
    static func parse(_ output: String) -> [ListeningPort] {
        var pid: Int?
        var process = ""
        var seen = Set<String>()
        var result: [ListeningPort] = []
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
                guard let pid, let entry = endpoint(value) else { continue }
                let port = ListeningPort(pid: pid, process: process, address: entry.host, port: entry.port, scope: scope(of: entry.host))
                if seen.insert(port.id).inserted { result.append(port) }
            default:
                continue
            }
        }
        return result.sorted { ($0.scope, $0.port, $0.pid) < ($1.scope, $1.port, $1.pid) }
    }

    /// Aynı portu farklı PID'lerin dinlediği durumlar. Aynı sürecin iki adresi çakışma sayılmaz.
    static func conflicts(_ ports: [ListeningPort]) -> [PortConflict] {
        Dictionary(grouping: ports, by: \.port).compactMap { number, group in
            guard Set(group.map(\.pid)).count > 1 else { return nil }
            var seen = Set<Int>()
            let names = group.sorted { $0.pid < $1.pid }.filter { seen.insert($0.pid).inserted }.map(\.process)
            return PortConflict(port: number, processes: names)
        }.sorted { $0.port < $1.port }
    }

    static func exposedCount(_ ports: [ListeningPort]) -> Int { ports.filter { $0.scope == .all }.count }

    /// "*:7000", "127.0.0.1:11434", "[::1]:3000". Port sayı değilse nil döner.
    static func endpoint(_ text: String) -> (host: String, port: Int)? {
        guard let colon = text.lastIndex(of: ":"), let port = Int(text[text.index(after: colon)...]) else { return nil }
        var host = String(text[..<colon])
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return host.isEmpty ? nil : (host, port)
    }

    private static func scope(of host: String) -> ListeningPort.Scope {
        if wildcards.contains(host) { return .all }
        if host == "::1" || host.hasPrefix("127.") { return .local }
        return .interface
    }

    /// `lsof` yoksa veya 8 saniyede bitmezse boş döner.
    nonisolated static func scan() -> [ListeningPort] {
        let path = "/usr/sbin/lsof"
        guard FileManager.default.isExecutableFile(atPath: path) else { return [] }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN", "-F", "pcn"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return [] }
        let watchdog = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        return parse(String(decoding: data, as: UTF8.self))
    }
}

