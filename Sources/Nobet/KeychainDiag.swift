import AppKit
import Security

/// Geliştirme tanılaması. `NOBET_DIAG_KEYCHAIN=write|read|delete` sahte bir kaydı işler, sonucu yazar ve çıkar.
/// Amaç: uygulama yeniden derlenip imzası değişince Anahtar Zinciri erişiminin sürüp sürmediğini görmek.
/// Kullanıcı arayüzü istemi kapatılır. İstem gerekirse çağrı bekleyip kilitlenmek yerine hata verir.
enum KeychainDiag {
    static let account = "diag-spike"
    /// Her deneme derlemesinde değişir. İkili dosyanın gerçekten farklı olmasını sağlar.
    static let buildMarker = "A"

    @MainActor
    static func runIfRequested() {
        guard let action = ProcessInfo.processInfo.environment["NOBET_DIAG_KEYCHAIN"] else { return }
        SecKeychainSetUserInteractionAllowed(false)
        let store = KeychainStore()
        do {
            switch action {
            case "write":
                try store.set(Data("sahte-\(UUID().uuidString)".utf8), account: account)
                print("keychain write: OK")
            case "read":
                if let value = try store.get(account: account) {
                    print("keychain read: OK (\(value.count) bayt) build=\(buildMarker)")
                } else {
                    print("keychain read: kayıt yok")
                }
            case "delete":
                try store.delete(account: account)
                print("keychain delete: OK")
            default:
                print("keychain: bilinmeyen eylem \(action)")
            }
        } catch {
            print("keychain \(action): HATA \(error)")
        }
        fflush(stdout)
        NSApp.terminate(nil)
    }
}
