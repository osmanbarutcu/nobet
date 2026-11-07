import Foundation

/// Bir modülün bildirilebilir sorunu. `detail` yoktur: saklanan ve bildirilen metin yol, anahtar adı veya çıktı taşımaz.
struct AlertIssue: Codable, Equatable, Identifiable {
    /// Kararlı kimlik: modül, konu ve tür. Aynı sorun her okumada aynı anahtarı üretir.
    let key: String
    let module: String
    let subject: String
    let title: String
    let severity: Severity

    var id: String { key }
}

struct AlertEvent: Codable, Equatable, Identifiable {
    enum Kind: String, Codable {
        case started, resolved
    }

    let kind: Kind
    let issue: AlertIssue
    let date: Date

    var id: String { "\(kind.rawValue)|\(issue.key)|\(date.timeIntervalSince1970)" }
}

/// Önceki ve şimdiki sorun listesini karşılaştırır. Aynı sorun yeniden bildirilmez.
enum AlertEngine {
    static func diff(previous: [AlertIssue], current: [AlertIssue]) -> (started: [AlertIssue], resolved: [AlertIssue]) {
        func unique(_ issues: [AlertIssue]) -> [AlertIssue] {
            var seen = Set<String>()
            return issues.filter { seen.insert($0.key).inserted }
        }
        let now = unique(current.filter { $0.severity >= .medium })
        let before = unique(previous)
        let nowKeys = Set(now.map(\.key))
        let beforeKeys = Set(before.map(\.key))
        return (now.filter { !beforeKeys.contains($0.key) }, before.filter { !nowKeys.contains($0.key) })
    }
}

/// Gün içindeki sessiz aralık. Bitiş başlangıçtan küçükse aralık geceyi aşar. Eşitse hiç sessiz saat yoktur.
struct QuietHours: Equatable {
    let startMinute: Int
    let endMinute: Int

    func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard startMinute != endMinute else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return startMinute < endMinute ? (minute >= startMinute && minute < endMinute) : (minute >= startMinute || minute < endMinute)
    }
}

enum AlertHistory {
    static let defaultLimit = 100

    /// Yeni olaylar öne gelir. Liste sınırı aşarsa en eskiler düşer.
    static func appending(_ events: [AlertEvent], to old: [AlertEvent], limit: Int = defaultLimit) -> [AlertEvent] {
        Array((events + old).prefix(limit))
    }
}

/// Olay geçmişini dosyaya çevirir. Anahtar (`key`) dışarı verilmez.
enum AlertExport {
    private static func row(_ event: AlertEvent) -> [String] {
        [ISO8601DateFormatter().string(from: event.date), event.kind == .started ? "başladı" : "düzeldi",
         event.issue.module, event.issue.subject, event.issue.title, event.issue.severity.label]
    }

    /// Hücre `= + - @` ile başlarsa tablo programı formül sayar. Başına `'` konur.
    private static func cell(_ text: String) -> String {
        var value = text
        if let first = value.first, "=+-@".contains(first) { value = "'" + value }
        guard value.contains(where: { ",\"\n\r".contains($0) }) else { return value }
        return "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func csv(_ events: [AlertEvent]) -> String {
        let header = "tarih,olay,modül,konu,başlık,önem"
        return ([header] + events.map { row($0).map(cell).joined(separator: ",") }).joined(separator: "\n") + "\n"
    }

    static func json(_ events: [AlertEvent]) -> String {
        let keys = ["tarih", "olay", "modül", "konu", "başlık", "önem"]
        let rows = events.map { Dictionary(uniqueKeysWithValues: zip(keys, row($0))) }
        guard let data = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys]) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }
}
