import Foundation
import UserNotifications

struct ReleaseInfo: Equatable {
    let version: String
    let url: URL
}

/// Yeni sürüm denetimi. Yalnızca GitHub Releases'a tek bir GET isteği gönderir.
/// Varsayılan kapalıdır. İstek GitHub'a IP adresinizi gösterir. Hiçbir veri gönderilmez, hiçbir şey indirilmez.
enum UpdateCheck {
    static let endpoint = URL(string: "https://api.github.com/repos/osmanbarutcu/nobet/releases/latest")!
    static let interval: TimeInterval = 24 * 3_600
    static let enabledKey = "updateCheckEnabled"
    static let lastCheckKey = "lastUpdateCheck"
    static let notificationId = "nobet.update"

    /// Yanıtı çözer. Taslak, ön sürüm, bozuk yanıt ve GitHub dışı bağlantı nil verir.
    static func parse(_ data: Data) -> ReleaseInfo? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["draft"] as? Bool != true, object["prerelease"] as? Bool != true,
              let tag = object["tag_name"] as? String,
              let link = object["html_url"] as? String, let url = URL(string: link),
              url.scheme == "https", url.host == "github.com" else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        return version.isEmpty ? nil : ReleaseInfo(version: version, url: url)
    }

    /// Sürümleri sayı sayı karşılaştırır (0.10.0 > 0.9.0). Çözülemeyen sürüm asla yeni sayılmaz.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        func parts(_ text: String) -> [Int]? {
            let numbers = text.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            return numbers.contains(where: { $0 == nil }) || numbers.isEmpty ? nil : numbers.compactMap { $0 }
        }
        guard let new = parts(candidate), let old = parts(current) else { return false }
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0
            let b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    static func isDue(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= interval
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// 10 sn zaman aşımı. Ağ hatasında nil döner. Çerez ve önbellek kullanılmaz.
    static func fetchLatest() async -> ReleaseInfo? {
        var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Nobet/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.httpShouldHandleCookies = false
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }
}

/// Denetimi zamanlar ve yeni sürümde bildirim gönderir. Ayar kapalıysa ağa hiç çıkmaz.
@MainActor
final class UpdateModel: ObservableObject {
    static let shared = UpdateModel()

    @Published private(set) var availableUpdate: ReleaseInfo?
    private var checking = false
    private var polling: Task<Void, Never>?

    /// 30 dakikada bir bakar. İstek yalnızca son denetimden 24 saat geçtiyse gider.
    func startPolling() {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                await self?.checkIfDue()
                try? await Task.sleep(nanoseconds: 1_800 * 1_000_000_000)
            }
        }
    }

    func checkIfDue() async {
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: UpdateCheck.enabledKey), !checking,
              UpdateCheck.isDue(lastCheck: defaults.object(forKey: UpdateCheck.lastCheckKey) as? Date) else { return }
        checking = true
        let latest = await UpdateCheck.fetchLatest()
        checking = false
        guard let latest else { return }
        defaults.set(Date(), forKey: UpdateCheck.lastCheckKey)
        guard UpdateCheck.isNewer(latest.version, than: UpdateCheck.currentVersion) else {
            availableUpdate = nil
            return
        }
        if availableUpdate?.version != latest.version { Self.notify(latest) }
        availableUpdate = latest
    }

    private static func notify(_ release: ReleaseInfo) {
        guard Bundle.main.bundleIdentifier != nil else { return }
        let content = UNMutableNotificationContent()
        content.title = "Nöbet \(release.version) çıktı"
        content.body = "Kurulu sürüm \(UpdateCheck.currentVersion). Sürüm sayfası Ayarlar'da."
        let request = UNNotificationRequest(identifier: UpdateCheck.notificationId, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}
