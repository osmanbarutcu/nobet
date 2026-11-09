import Foundation

/// Bilinen dinleyicilerin özetleri. İlk tarama sessizce öğrenir. Sonraki taramada bilinmeyen anahtar "yeni" sayılır.
/// Anahtarlar `AlertKey.digest` özetidir. Diske yol veya süreç adı yazılmaz.
/// Değer türüdür. Her işlem yeni bir kopya döner.
struct NetworkBaseline: Equatable {
    private(set) var known: Set<String>
    private(set) var trusted: Set<String>
    private(set) var learned: Bool

    static let empty = NetworkBaseline()

    init(known: Set<String> = [], trusted: Set<String> = [], learned: Bool = false) {
        self.known = known
        self.trusted = trusted
        self.learned = learned
    }

    /// İlk çağrı tüm anahtarları öğrenir ve yeni anahtar bildirmez.
    /// Sonraki çağrılar yalnızca bilinmeyen ve güvenilir olmayan anahtarları bildirir.
    /// Bildirilen anahtar bilinenlere eklenmez. Kullanıcı güvenilir işaretleyene kadar "yeni" kalır.
    func observing(_ keys: Set<String>) -> (baseline: NetworkBaseline, newKeys: Set<String>) {
        guard learned else {
            return (NetworkBaseline(known: known.union(keys), trusted: trusted, learned: true), [])
        }
        return (self, keys.subtracting(known).subtracting(trusted))
    }

    func isTrusted(_ key: String) -> Bool { trusted.contains(key) }

    func trusting(_ key: String) -> NetworkBaseline {
        NetworkBaseline(known: known, trusted: trusted.union([key]), learned: learned)
    }

    func untrusting(_ key: String) -> NetworkBaseline {
        NetworkBaseline(known: known, trusted: trusted.subtracting([key]), learned: learned)
    }

    /// Öğrenilen kümeyi siler ve öğrenmeyi yeniden başlatır. Kullanıcının güvenilir listesi kalır.
    func reset() -> NetworkBaseline {
        NetworkBaseline(known: [], trusted: trusted, learned: false)
    }
}

/// Taban çizgisini `UserDefaults` içinde saklar.
enum NetworkBaselineStore {
    static let knownKey = "network.baseline.known"
    static let trustedKey = "network.baseline.trusted"
    static let learnedKey = "network.baseline.learned"

    static func load(from defaults: UserDefaults = .standard) -> NetworkBaseline {
        NetworkBaseline(
            known: Set(defaults.stringArray(forKey: knownKey) ?? []),
            trusted: Set(defaults.stringArray(forKey: trustedKey) ?? []),
            learned: defaults.bool(forKey: learnedKey))
    }

    static func save(_ baseline: NetworkBaseline, to defaults: UserDefaults = .standard) {
        defaults.set(baseline.known.sorted(), forKey: knownKey)
        defaults.set(baseline.trusted.sorted(), forKey: trustedKey)
        defaults.set(baseline.learned, forKey: learnedKey)
    }
}
