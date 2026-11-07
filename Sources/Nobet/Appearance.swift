import SwiftUI

/// Görünüm ayarları. Her biri bilinmeyen kayıtta varsayılana döner.
enum AppearanceAccent: String, CaseIterable {
    case indigo, blue, green, orange, pink, gray

    static let key = "appearance.accent"

    init(stored: String?) { self = stored.flatMap(Self.init(rawValue:)) ?? .indigo }

    var title: String {
        switch self {
        case .indigo: return "Çivit"
        case .blue: return "Mavi"
        case .green: return "Yeşil"
        case .orange: return "Turuncu"
        case .pink: return "Pembe"
        case .gray: return "Gri"
        }
    }

    var color: Color {
        switch self {
        case .indigo: return .indigo
        case .blue: return .blue
        case .green: return .green
        case .orange: return .orange
        case .pink: return .pink
        case .gray: return .gray
        }
    }
}

enum AppearanceTheme: String, CaseIterable {
    case system, light, dark

    static let key = "appearance.theme"

    init(stored: String?) { self = stored.flatMap(Self.init(rawValue:)) ?? .system }

    var title: String {
        switch self {
        case .system: return "Otomatik"
        case .light: return "Açık"
        case .dark: return "Koyu"
        }
    }

    /// `nil` sistemi izler.
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

enum AppearanceDensity: String, CaseIterable {
    case comfortable, compact

    static let key = "appearance.density"

    init(stored: String?) { self = stored.flatMap(Self.init(rawValue:)) ?? .comfortable }

    var title: String { self == .comfortable ? "Rahat" : "Sıkı" }
    var pageSpacing: CGFloat { self == .comfortable ? 16 : 10 }
    var pagePadding: CGFloat { self == .comfortable ? 24 : 14 }
}

enum AppearanceTextScale: String, CaseIterable {
    case small, standard, large

    static let key = "appearance.textScale"

    init(stored: String?) { self = stored.flatMap(Self.init(rawValue:)) ?? .standard }

    var title: String {
        switch self {
        case .small: return "Küçük"
        case .standard: return "Standart"
        case .large: return "Büyük"
        }
    }

    var factor: Double {
        switch self {
        case .small: return 0.9
        case .standard: return 1
        case .large: return 1.15
        }
    }

    var typeSize: DynamicTypeSize {
        switch self {
        case .small: return .small
        case .standard: return .large
        case .large: return .xxLarge
        }
    }
}

enum AppearanceIconStyle: String, CaseIterable {
    case binoculars, eye, shield

    static let key = "appearance.icon"

    init(stored: String?) { self = stored.flatMap(Self.init(rawValue:)) ?? .binoculars }

    var title: String {
        switch self {
        case .binoculars: return "Dürbün"
        case .eye: return "Göz"
        case .shield: return "Kalkan"
        }
    }

    /// Uyarı varken dolu, yokken çizgi simge.
    func symbol(filled: Bool) -> String {
        switch self {
        case .binoculars: return filled ? "binoculars.fill" : "binoculars"
        case .eye: return filled ? "eye.fill" : "eye"
        case .shield: return filled ? "shield.lefthalf.filled" : "shield"
        }
    }
}

/// Menü paneli düzeni. Kısa düzen yalnızca durum ve sorunları gösterir.
enum PanelLayout: String, CaseIterable {
    case standard, compact

    static let key = "appearance.panel"

    init(stored: String?) { self = stored.flatMap(Self.init(rawValue:)) ?? .standard }

    var title: String { self == .standard ? "Tam" : "Kısa" }
    var showsServers: Bool { self == .standard }
    var showsSites: Bool { self == .standard }
}

private struct DensityKey: EnvironmentKey {
    static let defaultValue = AppearanceDensity.comfortable
}

extension EnvironmentValues {
    var nobetDensity: AppearanceDensity {
        get { self[DensityKey.self] }
        set { self[DensityKey.self] = newValue }
    }
}

/// Kök görünüme tema, vurgu rengi, yoğunluk ve yazı boyutunu uygular.
struct AppearanceModifier: ViewModifier {
    @AppStorage(AppearanceAccent.key) private var accent = AppearanceAccent.indigo.rawValue
    @AppStorage(AppearanceTheme.key) private var theme = AppearanceTheme.system.rawValue
    @AppStorage(AppearanceDensity.key) private var density = AppearanceDensity.comfortable.rawValue
    @AppStorage(AppearanceTextScale.key) private var textScale = AppearanceTextScale.standard.rawValue

    func body(content: Content) -> some View {
        content
            .tint(AppearanceAccent(stored: accent).color)
            .preferredColorScheme(AppearanceTheme(stored: theme).colorScheme)
            .environment(\.nobetDensity, AppearanceDensity(stored: density))
            .dynamicTypeSize(AppearanceTextScale(stored: textScale).typeSize)
    }
}

extension View {
    func nobetAppearance() -> some View { modifier(AppearanceModifier()) }
}

/// Sayfa kabı. Boşluk ve iç boşluk yoğunluk ayarından gelir.
struct PageContainer<Content: View>: View {
    @Environment(\.nobetDensity) private var density
    let content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: density.pageSpacing) { content }
                .padding(density.pagePadding)
        }
        .shadowSafeScroll(vertical: 0)
    }
}

/// Animasyon kuralı: macOS "Hareketi azalt" açıksa animasyon çalışmaz.
enum Motion {
    static func animation(_ base: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : base
    }
}

private struct MotionAnimationModifier<Value: Equatable>: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let base: Animation
    let value: Value

    func body(content: Content) -> some View {
        content.animation(Motion.animation(base, reduceMotion: reduceMotion), value: value)
    }
}

extension View {
    /// `.animation(_:value:)` gibi çalışır, ama "Hareketi azalt" ayarına uyar.
    func nobetAnimation<Value: Equatable>(_ base: Animation, value: Value) -> some View {
        modifier(MotionAnimationModifier(base: base, value: value))
    }
}
