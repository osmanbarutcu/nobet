import Foundation

/// Testler için geçici `UserDefaults`. `cfprefsd` plist dosyasını çıkıştan sonra yazar,
/// bu yüzden önceki çalıştırmanın artıkları bir sonraki çalıştırmanın başında silinir.
enum TestDefaults {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var names: [String] = []

        init() {
            Self.sweepStale()
            atexit { TestDefaults.registry.removeFiles() }
        }

        /// Yalnızca `nobet-<ad>-test-<UUID>.plist` biçimli dosyaları siler.
        static func sweepStale() {
            let directory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences")
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for file in files where file.hasPrefix("nobet-") && file.contains("-test-") && file.hasSuffix(".plist") {
                try? FileManager.default.removeItem(at: directory.appendingPathComponent(file))
            }
        }

        /// Çıkışta yalnızca POSIX çağrısı kullanılır.
        func removeFiles() {
            guard let home = getenv("HOME") else { return }
            let directory = String(cString: home) + "/Library/Preferences/"
            for name in names { unlink(directory + name + ".plist") }
        }
    }

    private static let registry = Registry()

    static func make(_ name: String) -> UserDefaults {
        registry.lock.lock()
        registry.names.append(name)
        registry.lock.unlock()
        return UserDefaults(suiteName: name)!
    }
}
