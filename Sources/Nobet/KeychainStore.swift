import Foundation
import Security

enum KeychainError: Error, CustomStringConvertible {
    case status(OSStatus)

    var description: String {
        guard case .status(let code) = self else { return "" }
        let message = SecCopyErrorMessageString(code, nil) as String? ?? "bilinmeyen hata"
        return "Anahtar Zinciri hatası \(code): \(message)"
    }
}

/// Parola ve özel anahtar gibi sırları macOS Anahtar Zinciri'nde tutar.
/// Sırlar uygulama klasörüne, ayar dosyasına veya günlüğe yazılmaz.
/// Kayıtlar `kSecClassGenericPassword` sınıfındadır. `service` uygulamayı, `account` sunucuyu ayırır.
struct KeychainStore {
    static let appService = "local.nobet"

    let service: String

    init(service: String = KeychainStore.appService) {
        self.service = service
    }

    private func query(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    /// Kayıt yoksa ekler, varsa değerini değiştirir.
    func set(_ secret: Data, account: String) throws {
        var addition = query(account)
        addition[kSecValueData as String] = secret
        let added = SecItemAdd(addition as CFDictionary, nil)
        if added == errSecSuccess { return }
        guard added == errSecDuplicateItem else { throw KeychainError.status(added) }
        let updated = SecItemUpdate(query(account) as CFDictionary, [kSecValueData as String: secret] as CFDictionary)
        guard updated == errSecSuccess else { throw KeychainError.status(updated) }
    }

    /// Kayıt yoksa nil döner.
    func get(account: String) throws -> Data? {
        var request = query(account)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.status(status) }
        return result as? Data
    }

    /// Kayıt yoksa hata vermez.
    func delete(account: String) throws {
        let status = SecItemDelete(query(account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.status(status) }
    }
}
