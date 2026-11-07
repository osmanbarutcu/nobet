import SwiftUI

/// Tek okumadan alınan üç değer. Yalnızca bellekte durur, diske yazılmaz.
struct MetricSample: Equatable, Codable {
    let date: Date
    let diskPercent: Int?
    let memoryPercent: Int?
    let load: Double?

    init(date: Date, diskPercent: Int?, memoryPercent: Int?, load: Double?) {
        self.date = date
        self.diskPercent = diskPercent
        self.memoryPercent = memoryPercent
        self.load = load
    }

    /// Kök disk, yoksa ilk disk. Bellek kullanım yüzdesi. 1 dakikalık yük.
    init(metrics: RemoteMetrics, date: Date) {
        let disk = metrics.disks.first { $0.mount == "/" } ?? metrics.disks.first
        self.init(date: date, diskPercent: disk?.usedPercent, memoryPercent: metrics.memory?.usedPercent, load: metrics.load?.first)
    }
}

/// Son 24 saatin örnekleri. Sınırı aşan eski örnek düşer.
enum MetricHistory {
    static let window: TimeInterval = 24 * 3600
    /// 5 dakikalık okumada 24 saat 288 örnektir.
    static let limit = 288

    static func appending(_ sample: MetricSample, to old: [MetricSample]) -> [MetricSample] {
        let cutoff = sample.date.addingTimeInterval(-window)
        return Array((old.filter { $0.date >= cutoff } + [sample]).suffix(limit))
    }

    /// Eksik değerler atlanır.
    static func values(_ history: [MetricSample], _ pick: (MetricSample) -> Double?) -> [Double] {
        history.compactMap(pick)
    }
}

/// Küçük çizgi grafik. Yüzde serisi sabit 0-100 ölçeğinde çizilir, böylece küçük oynama zirve gibi görünmez.
struct Sparkline: View {
    let values: [Double]
    var range: ClosedRange<Double>?
    var color: Color = .secondary
    var width: CGFloat = 90
    var height: CGFloat = 22

    /// 0-1 aralığına ölçekler. İki noktadan azsa çizgi yoktur. Düz seri ortada durur.
    static func normalized(_ values: [Double], range: ClosedRange<Double>? = nil) -> [Double] {
        guard values.count >= 2 else { return [] }
        let low = range?.lowerBound ?? values.min() ?? 0
        let high = range?.upperBound ?? values.max() ?? 0
        guard high > low else { return values.map { _ in 0.5 } }
        return values.map { min(1, max(0, ($0 - low) / (high - low))) }
    }

    var body: some View {
        let points = Self.normalized(values, range: range)
        Canvas { context, size in
            guard points.count >= 2 else { return }
            var path = Path()
            for (index, point) in points.enumerated() {
                let x = size.width * CGFloat(index) / CGFloat(points.count - 1)
                let y = size.height * (1 - CGFloat(point))
                if index == 0 { path.move(to: CGPoint(x: x, y: y)) } else { path.addLine(to: CGPoint(x: x, y: y)) }
            }
            context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 1.2, lineCap: .round, lineJoin: .round))
        }
        .frame(width: width, height: height)
        .accessibilityHidden(true)
    }
}

/// Büyük grafikte seçilebilen ölçü.
enum MetricChartKind: CaseIterable, Hashable {
    case disk, memory, load

    struct Point: Equatable {
        let date: Date
        let value: Double
    }

    var title: String {
        switch self {
        case .disk: return "Disk"
        case .memory: return "Bellek"
        case .load: return "Yük"
        }
    }

    var unit: String { self == .load ? "" : "%" }

    func points(_ samples: [MetricSample]) -> [Point] {
        samples.compactMap { sample in
            let value: Double?
            switch self {
            case .disk: value = sample.diskPercent.map(Double.init)
            case .memory: value = sample.memoryPercent.map(Double.init)
            case .load: value = sample.load
            }
            return value.map { Point(date: sample.date, value: $0) }
        }
    }

    /// Grafikte çizilecek eşik çizgileri. Yük için sabit eşik yoktur, çünkü çekirdek sayısına bağlıdır.
    func thresholdLines(_ thresholds: ServerThresholds) -> [Double] {
        switch self {
        case .disk: return [Double(thresholds.diskMedium), Double(thresholds.diskHigh)]
        case .memory: return [Double(100 - thresholds.memoryLowPercent * 2), Double(100 - thresholds.memoryLowPercent)]
        case .load: return []
        }
    }

    /// Yüzde ölçüleri sabit 0-100 eksenini kullanır. Yük, tepe değerin üstündeki tam sayıya kadar uzanır.
    func yDomain(for values: [Double]) -> ClosedRange<Double> {
        guard self == .load else { return 0...100 }
        return 0...max(1, (values.max() ?? 0).rounded(.up))
    }
}

/// Grafikte gösterilen süre.
enum ChartWindow: CaseIterable, Hashable {
    case hour, sixHours, day

    var title: String {
        switch self {
        case .hour: return "1 saat"
        case .sixHours: return "6 saat"
        case .day: return "24 saat"
        }
    }

    var seconds: TimeInterval {
        switch self {
        case .hour: return 3600
        case .sixHours: return 6 * 3600
        case .day: return 24 * 3600
        }
    }

    /// Pencere içindeki örnekleri tutar. Sınırdaki örnek dışarıda kalır.
    func filter<T: HistoryDated>(_ samples: [T], now: Date) -> [T] {
        samples.filter { $0.sampleDate > now.addingTimeInterval(-seconds) && $0.sampleDate <= now }
    }
}

/// Çalışma süresi geriye düşerse sunucu yeniden başlamıştır.
enum RebootDetector {
    static let tolerance = 60
    static let keep = 10

    static func rebooted(previous: Int?, current: Int?) -> Bool {
        guard let previous, let current else { return false }
        return current < previous - tolerance
    }

    static func rebootDate(now: Date, uptime: Int) -> Date { now.addingTimeInterval(-Double(uptime)) }

    static func appending(_ date: Date, to old: [Date]) -> [Date] { Array((old + [date]).suffix(keep)) }
}

enum ResponseTimeText {
    static func make(ms: Int) -> String {
        ms < 1000 ? "\(ms) ms" : String(format: "%.1f sn", Double(ms) / 1000).replacingOccurrences(of: ".", with: ",")
    }
}
