import Darwin
import Foundation
import Security

/// Bir ikili dosyanın kod imzası durumu.
enum SignatureStatus: Equatable {
    case apple, developer, adHoc, unsigned, invalid, unknown

    var label: String {
        switch self {
        case .apple: return "Apple imzalı"
        case .developer: return "Geliştirici imzalı"
        case .adHoc: return "Ad-hoc imzalı"
        case .unsigned: return "İmzasız"
        case .invalid: return "İmza geçersiz"
        case .unknown: return "İmza okunamadı"
        }
    }
}

/// Bir sürecin ikili dosyası hakkında bilinenler. Yol okunamazsa imza `.unknown` olur.
struct ProcessIdentity: Equatable {
    let path: String?
    let signature: SignatureStatus
    let suspiciousLocation: Bool

    /// Taban çizgisi anahtarının süreç kısmı. Yol varsa yol, yoksa süreç adı.
    func key(fallbackName: String) -> String { path ?? fallbackName }
}

protocol SignatureChecking: Sendable {
    func status(forPath path: String) -> SignatureStatus
}

enum ProcessTrust {
    /// Kullanıcı klasörünün altında gizli olsa da geliştirici araçlarının kurulduğu klasörler.
    /// Bu klasörlerdeki ikili dosyalar şüpheli sayılmaz. Yanlış pozitifi azaltır.
    static let toolDirectories: Set<String> = [
        ".orbstack", ".cargo", ".rustup", ".nvm", ".pyenv", ".rbenv", ".local", ".bun", ".volta", ".docker",
        ".npm", ".swiftpm", ".ollama", ".deno", ".asdf", ".sdkman", ".gem", ".nodenv", ".fnm", ".pnpm",
    ]

    private static let riskyPrefixes = [
        "/tmp/", "/private/tmp/", "/var/tmp/", "/private/var/tmp/", "/private/var/folders/", "/Users/Shared/",
    ]

    /// Geçici klasör, İndirilenler veya tanınmayan gizli klasör. Uygulama izolasyonu (AppTranslocation) sayılmaz.
    static func isSuspiciousLocation(_ path: String, home: String) -> Bool {
        if path.contains("/AppTranslocation/") { return false }
        if riskyPrefixes.contains(where: { path.hasPrefix($0) }) { return true }
        guard let first = firstComponentUnderUser(path, home: home) else { return false }
        if first == "Downloads" { return true }
        return first.hasPrefix(".") && !toolDirectories.contains(first)
    }

    /// Kullanıcı klasöründen sonraki ilk yol parçası. Kendi ev klasörü veya `/Users/<ad>/` altında olmayan yol için nil.
    private static func firstComponentUnderUser(_ path: String, home: String) -> String? {
        if path.hasPrefix(home + "/") {
            return path.dropFirst(home.count + 1).split(separator: "/").first.map(String.init)
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 2, parts[0] == "Users" else { return nil }
        return String(parts[2])
    }

    /// Süreç numarasından ikili dosya yolunu okur. Yetki yoksa veya süreç bittiyse nil döner.
    static func processPath(pid: Int) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        let length = proc_pidpath(Int32(pid), &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    static func identity(
        pid: Int, home: String, checker: SignatureChecking,
        pathOf: (Int) -> String? = { ProcessTrust.processPath(pid: $0) }
    ) -> ProcessIdentity {
        guard let path = pathOf(pid), !path.isEmpty else {
            return ProcessIdentity(path: nil, signature: .unknown, suspiciousLocation: false)
        }
        return ProcessIdentity(
            path: path, signature: checker.status(forPath: path), suspiciousLocation: isSuspiciousLocation(path, home: home))
    }
}

/// Security çerçevesiyle imzayı okur. Dosyaya yazmaz, ağa çıkmaz.
struct SystemSignatureChecker: SignatureChecking {
    private static let adHocFlag: UInt32 = 0x2

    func status(forPath path: String) -> SignatureStatus {
        guard FileManager.default.fileExists(atPath: path) else { return .unknown }
        var created: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, SecCSFlags(), &created) == errSecSuccess,
              let code = created
        else { return .unknown }

        let validity = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: UInt32(kSecCSBasicValidateOnly)), nil)
        if validity == OSStatus(errSecCSUnsigned) { return .unsigned }
        guard validity == errSecSuccess else { return .invalid }
        if isAdHoc(code) { return .adHoc }
        return isApple(code) ? .apple : .developer
    }

    private func isAdHoc(_ code: SecStaticCode) -> Bool {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: UInt32(kSecCSSigningInformation)), &info) == errSecSuccess,
              let dictionary = info as? [String: Any],
              let flags = (dictionary[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value
        else { return false }
        return flags & Self.adHocFlag != 0
    }

    private func isApple(_ code: SecStaticCode) -> Bool {
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString("anchor apple" as CFString, SecCSFlags(), &requirement) == errSecSuccess,
              let requirement
        else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(), requirement) == errSecSuccess
    }
}

/// İmza denetimi pahalıdır. Sonuç yol ve değişiklik zamanına göre saklanır. Dosya değişirse yeniden okunur.
final class CachedSignatureChecker: SignatureChecking, @unchecked Sendable {
    static let capacity = 2000

    private let inner: SignatureChecking
    private let lock = NSLock()
    private var cache: [String: SignatureStatus] = [:]

    init(inner: SignatureChecking = SystemSignatureChecker()) {
        self.inner = inner
    }

    func status(forPath path: String) -> SignatureStatus {
        let key = "\(path)|\(Self.stamp(path))"
        lock.lock()
        let hit = cache[key]
        lock.unlock()
        if let hit { return hit }
        let value = inner.status(forPath: path)
        lock.lock()
        if cache.count >= Self.capacity { cache.removeAll() }
        cache[key] = value
        lock.unlock()
        return value
    }

    private static func stamp(_ path: String) -> TimeInterval {
        let attributes = try? FileManager.default.attributesOfItem(atPath: path)
        return (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    }
}
