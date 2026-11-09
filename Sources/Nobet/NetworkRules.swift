import Foundation

/// Dinleyen bir süreç ve ikili dosya bilgisi. Kurallar bu değeri okur.
struct NetworkListener: Identifiable, Equatable {
    let port: ListeningPort
    let identity: ProcessIdentity
    /// Geliştirme modülü bu portu bir projeye bağladı. Ağ modülü bu portlar için uyarı üretmez.
    let isProjectPort: Bool

    var id: String { port.id }

    /// Süreç ve kapsam. Port numarası girmez, çünkü birçok uygulama her açılışta rastgele port seçer.
    /// Aynı süreç yerelden tüm ağa geçerse anahtar değişir ve "yeni" sayılır.
    var baselineKey: String { "\(identity.key(fallbackName: port.process))|\(port.scope.rawValue)" }

    var digest: String { AlertKey.digest(baselineKey) }
}

enum NetworkRisk: String, CaseIterable, Hashable {
    case newListener, exposedSystemPort, suspiciousLocation, unsignedExposed

    var title: String {
        switch self {
        case .newListener: return "Yeni dinleyen süreç"
        case .exposedSystemPort: return "Sistem portu tüm ağa açık"
        case .suspiciousLocation: return "Şüpheli klasörden çalışıyor"
        case .unsignedExposed: return "İmzasız süreç tüm ağa açık"
        }
    }

    var severity: Severity {
        self == .suspiciousLocation ? .high : .medium
    }
}

/// Ağ sayfasının tek bakışlık özeti.
struct NetworkHealth: Equatable {
    enum Level { case ok, warning }

    let listening: Int
    let exposed: Int
    let issues: Int

    init(listeners: [NetworkListener], newKeys: Set<String>, trusted: Set<String>) {
        listening = listeners.count
        exposed = listeners.filter { !$0.isProjectPort && $0.port.scope == .all }.count
        issues = NetworkRules.alertIssues(listeners, newKeys: newKeys, trusted: trusted).count
    }

    var level: Level { issues == 0 ? .ok : .warning }
    var headline: String { issues == 0 ? "Her şey yolunda" : "\(issues) sorun var" }
}

/// Dinleyicilerden uyarı üretir. Saf fonksiyonlardır, G/Ç yapmaz.
enum NetworkRules {
    /// Ad-hoc imza tek başına uyarı üretmez (Nöbet ve MoleBar ad-hoc imzalıdır).
    /// Güvenilir işaretli dinleyici hiçbir kuralı tetiklemez.
    static func risks(for listener: NetworkListener, newKeys: Set<String>, trusted: Set<String>) -> [NetworkRisk] {
        guard !listener.isProjectPort, !trusted.contains(listener.digest) else { return [] }
        let exposed = listener.port.scope == .all
        let signature = listener.identity.signature
        let unsigned = signature == .unsigned || signature == .invalid
        var result: [NetworkRisk] = []
        if newKeys.contains(listener.digest) { result.append(.newListener) }
        if listener.identity.suspiciousLocation { result.append(.suspiciousLocation) }
        if exposed, unsigned { result.append(.unsignedExposed) }
        if exposed, !unsigned, signature != .apple { result.append(.exposedSystemPort) }
        return result
    }

    /// Sayfa sırası: yüksek önemli riskler önce, sonra sistem portları, en sonda proje portları. Aynı grupta port sırası.
    static func displayOrder(_ listeners: [NetworkListener], newKeys: Set<String>, trusted: Set<String>) -> [NetworkListener] {
        let ranked = listeners.map { item -> (item: NetworkListener, severity: Int) in
            (item, risks(for: item, newKeys: newKeys, trusted: trusted).map(\.severity.rawValue).max() ?? -1)
        }
        return ranked.sorted {
            (-$0.severity, $0.item.isProjectPort ? 1 : 0, $0.item.port.port) < (-$1.severity, $1.item.isProjectPort ? 1 : 0, $1.item.port.port)
        }.map(\.item)
    }

    /// Anahtar kural ve süreç özetidir. PID ve yol girmez. Aynı süreç ve kural tek uyarı olur.
    /// Önce yüksek önem, sonra konu sırası.
    static func alertIssues(_ listeners: [NetworkListener], newKeys: Set<String>, trusted: Set<String>) -> [AlertIssue] {
        var seen = Set<String>()
        var issues: [AlertIssue] = []
        for listener in listeners {
            for risk in risks(for: listener, newKeys: newKeys, trusted: trusted) {
                let key = "net|\(risk.rawValue)|\(listener.digest)"
                guard seen.insert(key).inserted else { continue }
                issues.append(AlertIssue(key: key, module: "net", subject: listener.port.process, title: risk.title, severity: risk.severity))
            }
        }
        return issues.sorted { ($1.severity, $0.subject, $0.key) < ($0.severity, $1.subject, $1.key) }
    }
}
