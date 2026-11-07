import Foundation

/// İzlenen site. Yalnızca ad, alan adı ve port tutar. Parola veya anahtar içermez.
struct ServerSite: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let host: String
    let port: Int

    /// Geçersiz alan adı veya port için `nil` verir. Alan adı küçük harfe çevrilir. Ad boşsa alan adı kullanılır.
    static func make(name: String, host: String, port: Int, id: String = UUID().uuidString) -> ServerSite? {
        let cleanHost = host.trimmingCharacters(in: .whitespaces).lowercased()
        guard isValidHost(cleanHost), (1...65535).contains(port) else { return nil }
        let cleanName = name.trimmingCharacters(in: .whitespaces)
        return ServerSite(id: id, name: cleanName.isEmpty ? cleanHost : cleanName, host: cleanHost, port: port)
    }

    /// Harf, rakam, nokta ve tire kabul edilir. Şema, yol ve boşluk reddedilir.
    static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789.-")
        guard host.allSatisfy({ allowed.contains($0) }) else { return false }
        return !host.hasPrefix("-") && !host.hasPrefix(".") && !host.hasSuffix("-") && !host.hasSuffix(".")
    }

    var url: URL? {
        URL(string: port == 443 ? "https://\(host)/" : "https://\(host):\(port)/")
    }
}

/// Tek bir kontrolün ham sonucu. Ağ katmanı üretir, kurallar yorumlar.
struct ProbeResult: Equatable {
    let reachable: Bool
    let httpStatus: Int?
    let latencyMs: Int?
    let certExpiry: Date?
    let error: String?
    /// Sunucuya erişildi ama TLS sertifikası güvenilmedi. Sunucu çalışıyor, sorun sertifikadadır.
    var certError: String? = nil
    /// Erişilemeyen sitede hatanın hangi aşamada olduğu. Erişilen sitede `nil`.
    var failure: ProbeFailure? = nil
}

/// Tek HEAD isteğinin hata koduna göre aşama. Ek bağlantı kurulmaz.
enum ProbeFailure: String, Equatable {
    case dns, connection, timeout, offline, other

    static func classify(_ error: Error) -> ProbeFailure {
        switch (error as? URLError)?.code {
        case .cannotFindHost, .dnsLookupFailed: return .dns
        case .cannotConnectToHost, .networkConnectionLost: return .connection
        case .timedOut: return .timeout
        case .notConnectedToInternet: return .offline
        default: return .other
        }
    }
}

enum ServerIssueKind: String {
    case down, dnsFailed, portClosed, offline, httpError, certInvalid, certExpired, certExpiring, slow

    var title: String {
        switch self {
        case .down: return "Erişilemiyor"
        case .dnsFailed: return "Alan adı çözülemiyor"
        case .portClosed: return "Port bağlantısı kurulamıyor"
        case .offline: return "İnternet bağlantısı yok"
        case .httpError: return "HTTP hatası"
        case .certInvalid: return "SSL sertifikası güvenilmiyor"
        case .certExpired: return "SSL sertifikasının süresi doldu"
        case .certExpiring: return "SSL sertifikası yakında bitiyor"
        case .slow: return "Yavaş yanıt"
        }
    }
}

struct ServerIssue: Equatable {
    let kind: ServerIssueKind
    let severity: Severity
    let detail: String
}

enum SiteHealth {
    static let certWarningDays = 14.0
    static let slowThresholdMs = 2000

    static func issues(for result: ProbeResult, now: Date) -> [ServerIssue] {
        guard result.reachable else {
            let detail = result.error ?? "Bağlantı kurulamadı."
            switch result.failure {
            case .dns?: return [ServerIssue(kind: .dnsFailed, severity: .high, detail: detail)]
            case .connection?: return [ServerIssue(kind: .portClosed, severity: .high, detail: detail)]
            // İnternet yoksa her site düşmüş görünür. Bu, sitenin sorunu değildir.
            case .offline?: return [ServerIssue(kind: .offline, severity: .info, detail: detail)]
            default: return [ServerIssue(kind: .down, severity: .high, detail: detail)]
            }
        }
        var found: [ServerIssue] = []
        if let certError = result.certError {
            found.append(ServerIssue(kind: .certInvalid, severity: .high, detail: certError))
        }
        if let status = result.httpStatus, status >= 400 {
            found.append(ServerIssue(kind: .httpError, severity: status >= 500 ? .high : .medium, detail: "Durum kodu \(status)."))
        }
        if let expiry = result.certExpiry {
            let remaining = expiry.timeIntervalSince(now) / 86_400
            if remaining < 0 {
                found.append(ServerIssue(kind: .certExpired, severity: .high, detail: "Süre \(Int((-remaining).rounded(.up))) gün önce doldu."))
            } else if remaining <= certWarningDays {
                found.append(ServerIssue(kind: .certExpiring, severity: .medium, detail: "Kalan süre \(Int(remaining.rounded(.down))) gün."))
            }
        }
        if let latency = result.latencyMs, latency > slowThresholdMs {
            found.append(ServerIssue(kind: .slow, severity: .info, detail: "Yanıt süresi \(latency) ms."))
        }
        return found
    }

    /// Menü çubuğu uyarısı: yüksek ve orta sorunlar. Bilgi sorunları sayılmaz.
    static func alertCount(_ issues: [ServerIssue]) -> Int {
        issues.filter { $0.severity >= .medium }.count
    }
}

/// Sertifika bitiş takvimi. En yakın bitiş en üstte.
enum CertCalendar {
    struct Entry: Equatable {
        enum Level { case ok, warning, critical }

        let site: ServerSite
        let expiry: Date
        let daysLeft: Int
        let level: Level
    }

    static let criticalDays = 7
    static let warningDays = 30

    static func entries(sites: [ServerSite], results: [String: ProbeResult], now: Date) -> [Entry] {
        sites.compactMap { site -> Entry? in
            guard let expiry = results[site.id]?.certExpiry else { return nil }
            let days = Int((expiry.timeIntervalSince(now) / 86_400).rounded(.down))
            let level: Entry.Level = days <= criticalDays ? .critical : days <= warningDays ? .warning : .ok
            return Entry(site: site, expiry: expiry, daysLeft: days, level: level)
        }.sorted { $0.daysLeft < $1.daysLeft }
    }
}
