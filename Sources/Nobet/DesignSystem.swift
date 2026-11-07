import SwiftUI

/// Kullanım yüzdesine göre sistem renkleri.
func levelColor(_ percent: Double) -> Color {
    switch percent {
    case 90...: return .red
    case 75..<90: return .orange
    default: return .green
    }
}

extension View {
    /// Cam gölgesi yatayda kırpılmasın, dikeyde liste alttaki öğelerin üstüne taşmasın.
    /// `vertical`: içeriğin üstünde ve altında bırakılan boşluk. İlk kart üst kenara, son kart alt kenara yapışmaz.
    /// İçerik zaten kendi dikey iç boşluğunu taşıyorsa 0 verin, yoksa boşluk ikiye katlanır.
    func shadowSafeScroll(vertical: CGFloat = 12) -> some View {
        self
            .scrollClipDisabled()
            .contentMargins(.vertical, vertical, for: .scrollContent)
            .mask(Rectangle().padding(.horizontal, -24))
    }

    /// macOS 26+: Liquid Glass. Eski sürümler: ince materyal + ince çerçeve.
    @ViewBuilder
    func glassCard(cornerRadius: CGFloat = 18, tint: Color? = nil) -> some View {
        if #available(macOS 26.0, *) {
            let glass: Glass = tint.map { Glass.regular.tint($0.opacity(0.22)) } ?? Glass.regular
            self
                .modifier(GlassBacking(cornerRadius: cornerRadius))
                .glassEffect(glass, in: .rect(cornerRadius: cornerRadius))
                .overlay(GlassRim(cornerRadius: cornerRadius))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        } else {
            self
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(GlassRim(cornerRadius: cornerRadius))
                .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
        }
    }

    @ViewBuilder
    func glassButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glass)
        } else {
            self.buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func glassProminentButton() -> some View {
        if #available(macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }
}

/// Cam kartın alt dolgusunun opaklığı. Ayarlar'daki "Cam yoğunluğu" kaydırıcısı bunu değiştirir.
enum GlassDensity {
    static let key = "appearance.glass"
    static let standard = 0.38
    static let range = 0.15...0.7
}

private struct GlassBacking: ViewModifier {
    @AppStorage(GlassDensity.key) private var opacity = GlassDensity.standard
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.background(
            Color(nsColor: .textBackgroundColor).opacity(min(max(opacity, GlassDensity.range.lowerBound), GlassDensity.range.upperBound)),
            in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        )
    }
}

/// Cam kenarının ince ışık çizgisi. Üst sol köşe parlak, alt sağ köşe soluk. Tıklamayı engellemez.
private struct GlassRim: View {
    let cornerRadius: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            .strokeBorder(LinearGradient(colors: [.white.opacity(0.45), .white.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.75)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension Font {
    /// En küçük metin boyutu. `subheadline` 11 pt'tir ve "Yazı boyutu" ayarıyla ölçeklenir.
    static var nobetFootnote: Font { .subheadline }
}

extension View {
    /// Sayı değişince rakamlar kayarak geçer. "Hareketi azalt" açıksa geçiş çalışmaz.
    func nobetNumeric<Value: Equatable>(_ value: Value) -> some View {
        contentTransition(.numericText()).nobetAnimation(.snappy(duration: 0.3), value: value)
    }
}

/// Anahtar sağa hizalı, etiket solda.
struct RightSwitchStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack {
            configuration.label
            Spacer(minLength: 8)
            Toggle(isOn: configuration.$isOn) { EmptyView() }
                .toggleStyle(.switch)
                .labelsHidden()
        }
    }
}

/// Cam öğeleri tek kapta toplar. macOS 26+ için birleşme ve performans sağlar.
struct GlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content
    private let shadowInset: CGFloat = 28

    var body: some View {
        if #available(macOS 26.0, *) {
            // Cam gölgesi kapsayıcı sınırında kesilmesin diye iç pay verilir; negatif dış pay yerleşimi korur.
            GlassEffectContainer(spacing: spacing) { content().padding(shadowInset) }
                .padding(-shadowInset)
        } else {
            content()
        }
    }
}

/// VoiceOver için okunur metinler. Görsel olarak çizilen değerler ekran okuyucuya bu metinlerle iletilir.
enum A11y {
    static func percent(_ value: Double) -> String {
        "yüzde \(Int(min(max(value, 0), 100).rounded()))"
    }

    static func tile(name: String, bytes: UInt64, isDirectory: Bool) -> String {
        "\(name), \(isDirectory ? "klasör" : "dosya"), \(formatBytes(bytes))"
    }
}

struct RingGauge: View {
    let title: String
    let percent: Double
    var lineWidth: CGFloat = 7

    var body: some View {
        let color = levelColor(percent)
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(.primary.opacity(0.10), lineWidth: lineWidth)
                Circle()
                    .trim(from: 0, to: min(max(percent, 0), 100) / 100)
                    .stroke(
                        AngularGradient(colors: [color.opacity(0.55), color], center: .center, startAngle: .degrees(0), endAngle: .degrees(360 * min(max(percent, 1), 100) / 100)),
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .nobetAnimation(.easeOut(duration: 0.5), value: percent)
                Text(String(format: "%.0f", percent))
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .monospacedDigit()
            }
            .frame(width: 58, height: 58)
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
        .glassCard(cornerRadius: 16)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(A11y.percent(percent))
    }
}

struct UsageBar: View {
    let percent: Double
    var height: CGFloat = 6
    var color: Color? = nil

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.10))
                Capsule()
                    .fill((color ?? levelColor(percent)).gradient)
                    .frame(width: max(proxy.size.width * min(max(percent, 0), 100) / 100, height))
                    .nobetAnimation(.easeOut(duration: 0.5), value: percent)
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Kullanım")
        .accessibilityValue(A11y.percent(percent))
    }
}

/// Dikey çekirdek çubuğu.
struct CoreBar: View {
    let index: Int
    let percent: Double

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    Capsule().fill(.primary.opacity(0.10))
                    Capsule()
                        .fill(levelColor(percent).gradient)
                        .frame(height: max(proxy.size.height * min(max(percent, 0), 100) / 100, 4))
                        .nobetAnimation(.easeOut(duration: 0.4), value: percent)
                }
            }
            .frame(width: 10, height: 44)
            Text(String(format: "%.0f", percent))
                .font(.system(size: 9, weight: .semibold).monospacedDigit())
                .lineLimit(1)
            Text("\(index + 1)")
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Çekirdek \(index + 1)")
        .accessibilityValue(A11y.percent(percent))
    }
}

struct CardHeader: View {
    let symbol: String
    let title: String
    var trailing: String = ""

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if !trailing.isEmpty {
                Text(trailing)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

struct RateChip: View {
    let symbol: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: symbol)
                .font(.callout)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(.nobetFootnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(value)
                    .font(.caption.weight(.medium).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: 14)
    }
}


enum GaugeLevel {
    case ok, warning, critical

    static func of(percent: Int, medium: Int, high: Int) -> GaugeLevel {
        percent >= high ? .critical : percent >= medium ? .warning : .ok
    }

    static func fraction(percent: Int) -> Double { min(1, max(0, Double(percent) / 100)) }
}

/// Eşiğe göre renk değiştiren yüzde halkası. Değer ortada yazar.
struct ThresholdRing: View {
    let title: String
    let percent: Int
    let medium: Int
    let high: Int

    private var color: Color {
        switch GaugeLevel.of(percent: percent, medium: medium, high: high) {
        case .ok: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle().stroke(Color.primary.opacity(0.10), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: GaugeLevel.fraction(percent: percent))
                    .stroke(
                        AngularGradient(colors: [color.opacity(0.55), color], center: .center, startAngle: .degrees(0),
                                        endAngle: .degrees(360 * max(GaugeLevel.fraction(percent: percent), 0.01))),
                        style: StrokeStyle(lineWidth: 6, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .nobetAnimation(.easeOut(duration: 0.5), value: percent)
                Text(verbatim: "%\(percent)").font(.callout.monospacedDigit().weight(.semibold)).nobetNumeric(percent)
            }
            .frame(width: 62, height: 62)
            Text(title).font(.nobetFootnote).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) yüzde \(percent)")
    }
}


/// Daraltılmış kartların kimlikleri. Yeniden açılışta korunur.
@MainActor
final class CardCollapse: ObservableObject {
    static let shared = CardCollapse()
    static let key = "ui.collapsedCards"

    @Published private(set) var collapsed: Set<String>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        collapsed = Set(defaults.stringArray(forKey: Self.key) ?? [])
    }

    func isCollapsed(_ id: String) -> Bool { collapsed.contains(id) }

    func toggle(_ id: String) {
        var next = collapsed
        if next.contains(id) { next.remove(id) } else { next.insert(id) }
        collapsed = next
        defaults.set(next.sorted(), forKey: Self.key)
    }
}

/// Başlığa tıklayınca içeriği gizleyen kart.
struct CollapsibleCard<Content: View>: View {
    let id: String
    let symbol: String
    let title: String
    var trailing: String = ""
    @ObservedObject private var store = CardCollapse.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let content: Content

    init(id: String, symbol: String, title: String, trailing: String = "", @ViewBuilder content: () -> Content) {
        self.id = id
        self.symbol = symbol
        self.title = title
        self.trailing = trailing
        self.content = content()
    }

    var body: some View {
        let folded = store.isCollapsed(id)
        VStack(alignment: .leading, spacing: 10) {
            Button { withAnimation(Motion.animation(.easeInOut(duration: 0.2), reduceMotion: reduceMotion)) { store.toggle(id) } } label: {
                HStack(spacing: 6) {
                    CardHeader(symbol: symbol, title: title, trailing: trailing)
                    Image(systemName: folded ? "chevron.right" : "chevron.down").font(.nobetFootnote).foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(folded ? "daraltılmış" : "açık")")
            if !folded { content }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}


/// Liste boşken simge, başlık ve yönlendirici metin gösterir.
struct EmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.title).foregroundStyle(.tertiary)
            Text(title).font(.callout.weight(.semibold))
            Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .accessibilityElement(children: .combine)
    }
}

/// Liste boşken cam kart: simge, başlık, tek cümle ve isteğe bağlı eylem düğmesi.
struct EmptyCard: View {
    let symbol: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 28, weight: .light)).foregroundStyle(.tertiary).accessibilityHidden(true)
            Text(title).font(.callout.weight(.semibold))
            Text(message).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let actionTitle, let action {
                Button(actionTitle, action: action).glassProminentButton().controlSize(.small).padding(.top, 2)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .padding(.horizontal, 16)
        .glassCard()
        .accessibilityElement(children: .contain)
    }
}

/// Uzun açıklamayı kartı büyütmeden gösteren ⓘ düğmesi.
struct InfoButton: View {
    let text: String
    @StateObject private var state = InfoButtonState()

    var body: some View {
        Button { state.shown.toggle() } label: { Image(systemName: "info.circle") }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Bilgi")
            .accessibilityLabel("Bilgi")
            .popover(isPresented: $state.shown) {
                Text(text)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(14)
                    .frame(width: 340, alignment: .leading)
            }
    }
}

final class InfoButtonState: ObservableObject {
    @Published var shown = false
}

/// Başlıktaki ekle/kapat düğmesi. Form açıkken çarpı görünür.
struct AddToggleButton: View {
    let isOpen: Bool
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) { Image(systemName: isOpen ? "xmark" : "plus") }
            .glassButton()
            .controlSize(.small)
            .help(isOpen ? "Formu kapat" : title)
            .accessibilityLabel(isOpen ? "Formu kapat" : title)
    }
}
