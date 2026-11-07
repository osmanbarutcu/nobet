import Foundation

/// Uygulamanın ortak durumu. Modüller (geliştirme, sunucu, sır) uyarılarını buraya yazar.
/// Menü çubuğu etiketi ve panel bu sayıyı okur.
@MainActor
final class NobetModel: ObservableObject {
    static let shared = NobetModel()

    @Published private(set) var alerts: [String: Int] = [:]

    /// Tüm modüllerin uyarı toplamı.
    var alertCount: Int { alerts.values.reduce(0, +) }

    /// Bir modülün uyarı sayısını değiştirir. Negatif sayı sıfır sayılır.
    func setAlerts(_ count: Int, for module: String) {
        var next = alerts
        next[module] = max(0, count)
        alerts = next
    }
}
