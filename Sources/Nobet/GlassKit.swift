import Charts
import SwiftUI

/// Cam kartların altında kırılacak yumuşak renk zemini. Düz gri zemin camı görünmez yapar.
struct AmbientBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let strength = scheme == .dark ? 0.26 : 0.18
        ZStack {
            Color(nsColor: .windowBackgroundColor)
            RadialGradient(colors: [Color.accentColor.opacity(strength), .clear], center: .topLeading, startRadius: 0, endRadius: 460)
            RadialGradient(colors: [Color.teal.opacity(strength * 0.4), .clear], center: .bottomTrailing, startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }
}

/// Son 24 saatte saat başına başlayan sorun sayısı. Etkileşimsiz, panel için küçük sürüm.
struct AlertStrip: View {
    let buckets: [Int]
    var height: CGFloat = 26

    var body: some View {
        let top = max(3, buckets.max() ?? 0)
        let total = buckets.reduce(0, +)
        Chart(Array(buckets.enumerated()), id: \.offset) { index, count in
            BarMark(x: .value("Saat", index), yStart: .value("Alt", 0), yEnd: .value("En çok", top), width: .fixed(6))
                .foregroundStyle(Color.primary.opacity(0.07))
                .cornerRadius(2)
            if count > 0 {
                BarMark(x: .value("Saat", index), yStart: .value("Alt", 0), yEnd: .value("Sorun", count), width: .fixed(6))
                    .foregroundStyle(Color.orange)
                    .cornerRadius(2)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXScale(domain: -0.5...(Double(max(buckets.count, 1)) - 0.5))
        .chartYScale(domain: 0...top)
        .nobetAnimation(.easeOut(duration: 0.4), value: buckets)
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Son 24 saatte saat başına başlayan sorun sayısı")
        .accessibilityValue("Toplam \(total)")
    }
}

/// Dolgulu küçük çizgi grafik. Yüzde serisi için `range` 0...100 verin, böylece küçük oynama zirve gibi görünmez.
struct AreaSpark: View {
    let values: [Double]
    var range: ClosedRange<Double>?
    var color: Color = .accentColor
    var width: CGFloat = 40
    var height: CGFloat = 14

    /// Çizilecek eksen aralığı. Düz seri için tek noktalık aralık açılır, böylece `Chart` çökmez.
    static func domain(_ values: [Double], range: ClosedRange<Double>?) -> ClosedRange<Double> {
        if let range { return range }
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        return high > low ? low...high : (low - 0.5)...(high + 0.5)
    }

    var body: some View {
        if values.count >= 2 {
            let domain = Self.domain(values, range: range)
            Chart(Array(values.enumerated()), id: \.offset) { index, value in
                AreaMark(x: .value("Sıra", index), yStart: .value("Alt", domain.lowerBound), yEnd: .value("Değer", value))
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.35), color.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    .interpolationMethod(.monotone)
                LineMark(x: .value("Sıra", index), y: .value("Değer", value))
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartYScale(domain: domain)
            .nobetAnimation(.easeOut(duration: 0.4), value: values)
            .frame(width: width, height: height)
            .accessibilityHidden(true)
        } else {
            Color.clear.frame(width: width, height: height).accessibilityHidden(true)
        }
    }
}

/// Açık sorunların önem dağılımı. Renk tek başına taşımaz: her dilim simge ve sayıyla da yazılır.
struct SeverityDonut: View {
    /// Önem ve sayı. Sayısı 0 olan dilim çizilmez.
    let counts: [(severity: Severity, count: Int)]
    var diameter: CGFloat = 76

    static func color(_ severity: Severity) -> Color {
        switch severity {
        case .high: return .red
        case .medium: return .orange
        case .info: return .secondary
        }
    }

    var body: some View {
        let shown = counts.filter { $0.count > 0 }
        let total = shown.reduce(0) { $0 + $1.count }
        HStack(spacing: 14) {
            Chart(shown, id: \.severity) { item in
                SectorMark(angle: .value("Sayı", item.count), innerRadius: .ratio(0.64), angularInset: 2)
                    .cornerRadius(3)
                    .foregroundStyle(Self.color(item.severity))
            }
            .frame(width: diameter, height: diameter)
            .overlay {
                VStack(spacing: 0) {
                    Text("\(total)").font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit().nobetNumeric(total)
                    Text("açık").font(.nobetFootnote).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                ForEach(counts, id: \.severity) { item in
                    HStack(spacing: 6) {
                        Image(systemName: item.severity.symbol).font(.caption).foregroundStyle(Self.color(item.severity)).frame(width: 16)
                        Text(item.severity.label).font(.caption)
                        Spacer(minLength: 8)
                        Text("\(item.count)").font(.caption.weight(.semibold).monospacedDigit())
                    }
                }
            }
            .frame(minWidth: 110)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Açık sorunların önem dağılımı")
        .accessibilityValue(counts.map { "\($0.severity.label) \($0.count)" }.joined(separator: ", "))
    }
}
