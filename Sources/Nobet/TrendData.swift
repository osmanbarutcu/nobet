import Foundation

/// Bir sitenin tek kontrolü. Yalnızca bellekte durur, diske yazılmaz.
struct SiteSample: Equatable, Codable {
    let date: Date
    let up: Bool
    let latencyMs: Int?
}

/// Son 24 saatin site örnekleri. Çalışma yüzdesi ve ortalama gecikme buradan hesaplanır.
enum SiteHistory {
    static let window: TimeInterval = 24 * 3600
    static let limit = 288

    static func appending(_ sample: SiteSample, to old: [SiteSample]) -> [SiteSample] {
        let cutoff = sample.date.addingTimeInterval(-window)
        return Array((old.filter { $0.date >= cutoff } + [sample]).suffix(limit))
    }

    /// Başarılı kontrolün toplam kontrole oranı. Örnek yoksa `nil`.
    static func uptimePercent(_ samples: [SiteSample]) -> Double? {
        guard !samples.isEmpty else { return nil }
        return Double(samples.filter(\.up).count) / Double(samples.count) * 100
    }

    /// Yalnızca başarılı kontrollerin ortalaması. Başarısız kontrol gecikme taşımaz.
    static func averageLatencyMs(_ samples: [SiteSample]) -> Int? {
        let values = latencies(samples)
        guard !values.isEmpty else { return nil }
        return Int((values.reduce(0, +) / Double(values.count)).rounded())
    }

    static func latencies(_ samples: [SiteSample]) -> [Double] {
        samples.compactMap { $0.up ? $0.latencyMs.map(Double.init) : nil }
    }

    struct Point: Equatable {
        let date: Date
        let value: Double
    }

    static func latencyPoints(_ samples: [SiteSample]) -> [Point] {
        samples.compactMap { sample in
            sample.up ? sample.latencyMs.map { Point(date: sample.date, value: Double($0)) } : nil
        }
    }

    /// Başarısız kontrollerin zamanı. Grafikte kırmızı işaret olur.
    static func downtimeDates(_ samples: [SiteSample]) -> [Date] {
        samples.filter { !$0.up }.map(\.date)
    }

    /// Eksen 0'dan en yakın üst yüze kadar uzanır. En az 100 ms.
    static func latencyDomain(_ values: [Double]) -> ClosedRange<Double> {
        0...max(100, ((values.max() ?? 0) / 100).rounded(.up) * 100)
    }
}

/// Başlayan sorunların saat başına sayısı. Grafik bunu çubuk olarak çizer.
enum AlertTimeline {
    /// En eski kutu önce, son kutu şimdiye biter. Kutu `k`, `k` saat önce başlayan ve `k+1` saatten yeni olayları sayar.
    /// Tam saat sınırındaki olay eski kutuya düşer. Pencere dışı ve gelecekteki olay sayılmaz.
    static func hourlyStarts(_ events: [AlertEvent], now: Date, hours: Int = 24) -> [Int] {
        var buckets = Array(repeating: 0, count: max(0, hours))
        for event in events where event.kind == .started {
            let age = now.timeIntervalSince(event.date)
            guard age >= 0 else { continue }
            let hoursAgo = Int(age / 3600)
            guard hoursAgo < buckets.count else { continue }
            buckets[buckets.count - 1 - hoursAgo] += 1
        }
        return buckets
    }

    /// Kutuya düşen başlayan sorunların başlıkları. `hourlyStarts` ile aynı kutu kuralını kullanır.
    static func titles(_ events: [AlertEvent], bucket: Int, now: Date, hours: Int = 24) -> [String] {
        events.filter { event in
            guard event.kind == .started else { return false }
            let age = now.timeIntervalSince(event.date)
            guard age >= 0 else { return false }
            let hoursAgo = Int(age / 3600)
            return hoursAgo < hours && hours - 1 - hoursAgo == bucket
        }.map(\.issue.title)
    }

    /// Kutunun okunur adı. Son kutu "Son 1 saat" olur.
    static func label(bucket: Int, hours: Int = 24) -> String {
        let hoursAgo = hours - bucket
        return hoursAgo <= 1 ? "Son 1 saat" : "\(hoursAgo) saat önce"
    }
}

/// 24 saatlik ölçü geçmişinin isteğe bağlı disk kopyası. Yalnızca zaman ve sayı yazılır, sır yazılmaz.
struct HistoryFile<Sample: Codable & HistoryDated> {
    static var enabledKey: String { "history.persist" }

    let url: URL

    /// Ayarlar'da açıksa uygulama klasörüne yazan dosya. Kapalıysa `nil`.
    static func standard(named name: String, defaults: UserDefaults = .standard) -> HistoryFile? {
        guard defaults.bool(forKey: enabledKey),
              let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        return HistoryFile(url: base.appendingPathComponent("Nobet").appendingPathComponent(name))
    }

    func load(now: Date) -> [String: [Sample]] {
        guard let data = try? Data(contentsOf: url), let all = try? JSONDecoder().decode([String: [Sample]].self, from: data) else { return [:] }
        let cutoff = now.addingTimeInterval(-24 * 3600)
        return all.mapValues { $0.filter { $0.sampleDate >= cutoff } }.filter { !$0.value.isEmpty }
    }

    func save(_ history: [String: [Sample]]) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(history) else { return }
        try? data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

protocol HistoryDated {
    var sampleDate: Date { get }
}

extension SiteSample: HistoryDated { var sampleDate: Date { date } }
extension MetricSample: HistoryDated { var sampleDate: Date { date } }

/// Son 24 saat için saatlik uptime şeridi. Her hücre o saatteki başarılı kontrol yüzdesidir.
enum UptimeStrip {
    enum Level { case unknown, good, degraded, down }

    /// En eski hücre önce. Hücre `k`, yaşı `k` ile `k+1` saat arasındaki örnekleri sayar.
    /// Tam saat sınırındaki örnek eski hücreye düşer. Gelecekteki ve pencere dışı örnek sayılmaz.
    static func cells(_ samples: [SiteSample], now: Date, hours: Int = 24) -> [Double?] {
        var buckets = [[SiteSample]](repeating: [], count: hours)
        for sample in samples {
            let age = now.timeIntervalSince(sample.date)
            guard age >= 0 else { continue }
            let k = Int(age / 3600)
            if k < hours { buckets[k].append(sample) }
        }
        return buckets.reversed().map { group in
            group.isEmpty ? nil : Double(group.filter(\.up).count) / Double(group.count) * 100
        }
    }

    static func level(_ percent: Double?) -> Level {
        guard let percent else { return .unknown }
        return percent >= 99 ? .good : percent >= 90 ? .degraded : .down
    }
}
