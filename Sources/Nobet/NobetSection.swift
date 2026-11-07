import SwiftUI

extension Notification.Name {
    /// Ana pencereyi açma isteği. Menü çubuğu etiketi dinler ve `openWindow` çağırır.
    static let nobetOpenMain = Notification.Name("nobet.openMain")
    /// Komut paletini açma isteği (⌘K).
    static let nobetOpenPalette = Notification.Name("nobet.openPalette")
}

/// Ana pencerenin kenar çubuğu sayfaları. Ham değer hem başlıktır hem `mainSection` ayarında saklanır.
enum NobetSection: String, CaseIterable, Identifiable {
    case general = "Genel"
    case development = "Geliştirme"
    case servers = "Sunucular"
    case secrets = "Sırlar"
    case settings = "Ayarlar"
    case about = "Hakkında"

    var id: String { rawValue }

    /// ⌘1 ... ⌘4 ve Ayarlar için ⌘0.
    var shortcut: KeyEquivalent? {
        switch self {
        case .general: return "1"
        case .development: return "2"
        case .servers: return "3"
        case .secrets: return "4"
        case .settings: return "0"
        case .about: return nil
        }
    }

    var symbol: String {
        switch self {
        case .general: return "binoculars"
        case .development: return "hammer"
        case .servers: return "server.rack"
        case .secrets: return "key.viewfinder"
        case .settings: return "gearshape"
        case .about: return "info.circle"
        }
    }
}

/// Bildirime tıklayınca açılacak sayfa. Kimlikler bildirim gönderilirken verilir.
enum NotificationRoute {
    static func section(for identifier: String) -> NobetSection? {
        switch identifier {
        case "nobet.server": return .servers
        case "nobet.secret": return .secrets
        case "nobet.dev": return .development
        case "nobet.update": return .settings
        default: return nil
        }
    }
}

/// Menü çubuğu etiketi. Uyarı yoksa yalnızca simge görünür. Uyarı varsa sayı görünür.
enum StatusLabel {
    static let cap = 9

    static func title(alertCount: Int) -> String {
        guard alertCount > 0 else { return "" }
        return alertCount > cap ? "\(cap)+" : String(alertCount)
    }

    /// Pencere alt başlığı. Pencere arka plandayken de durum görünür.
    static func subtitle(alertCount: Int) -> String {
        alertCount > 0 ? "Nöbet · \(alertCount) sorun" : "Nöbet"
    }

    /// Genel sayfasının büyük başlığı.
    static func hero(openCount: Int, worst: Severity?) -> String {
        guard openCount > 0 else { return "Her şey yolunda" }
        return worst == .high ? "\(openCount) sorun var, en az biri yüksek önemde" : "\(openCount) sorun var"
    }

    enum Tint: Equatable { case none, warning, critical }

    /// Simge rengi. Yalnızca orta ve yüksek önem rengi değiştirir.
    static func tint(worst: Severity?) -> Tint {
        switch worst {
        case .high: return .critical
        case .medium: return .warning
        default: return .none
        }
    }

    static func accessibility(alertCount: Int) -> String {
        alertCount > 0 ? "Nöbet, \(alertCount) uyarı" : "Nöbet, uyarı yok"
    }
}
