import Foundation

/// SSH ile izlenen sunucuların durumu. Profil listesi `UserDefaults` içinde durur ve sır içermez.
/// Parola yalnızca Anahtar Zinciri'ndedir. Sonuçlar yalnızca bellekte kalır.
@MainActor
final class RemoteModel: ObservableObject {
    static let shared = RemoteModel(nobet: .shared, collector: DemoMode.collector, alerts: .shared, history: DemoMode.metricHistoryFile())

    static let profilesKey = "servers.ssh"
    static let maxProfiles = 20

    @Published private(set) var profiles: [SSHProfile]
    @Published private(set) var results: [String: Result<RemoteMetrics, SSHFailure>] = [:]
    @Published private(set) var checking = false
    @Published private(set) var checked = false
    /// Sunucu başına son 24 saatin örnekleri. Yalnızca bellekte durur.
    @Published private(set) var history: [String: [MetricSample]] = [:] {
        didSet { historyFile?.save(history) }
    }
    @Published private(set) var errorText: String?

    private let nobet: NobetModel
    private let defaults: UserDefaults
    private let secrets: SecretStoring
    private let collector: RemoteCollecting
    private let lister: PackageListing
    private let alerts: AlertCenter?
    private let now: () -> Date
    @Published private(set) var reboots: [String: [Date]] = [:]
    /// Son başarılı okumanın toplam süresi (SSH bağlantısı ve komutlar dahil).
    @Published private(set) var responseMs: [String: Int] = [:]
    private var lastUptime: [String: Int] = [:]
    private let historyFile: HistoryFile<MetricSample>?
    private var polling: Task<Void, Never>?
    /// İstek üzerine okunan paket listeleri. Yalnızca bellekte durur.
    @Published private(set) var inventory: [String: [InstalledPackage]] = [:]
    @Published private(set) var inventoryErrors: [String: String] = [:]
    @Published private(set) var loadingInventory: Set<String> = []

    init(nobet: NobetModel, defaults: UserDefaults = .standard, secrets: SecretStoring = KeychainStore(),
         collector: RemoteCollecting = SSHRunner(), alerts: AlertCenter? = nil, now: @escaping () -> Date = Date.init,
         history: HistoryFile<MetricSample>? = nil, lister: PackageListing = SSHRunner()) {
        self.lister = lister
        historyFile = history
        self.alerts = alerts
        self.now = now
        self.nobet = nobet
        self.defaults = defaults
        self.secrets = secrets
        self.collector = collector
        let data = defaults.data(forKey: Self.profilesKey)
        profiles = data.flatMap { try? JSONDecoder().decode([SSHProfile].self, from: $0) } ?? []
        self.history = history?.load(now: now()) ?? [:]
    }

    func issues(for profile: SSHProfile) -> [RemoteIssue] {
        switch results[profile.id] {
        case .success(let metrics): return RemoteHealth.issues(for: metrics, thresholds: profile.thresholds ?? .standard)
        case .failure(let failure): return [RemoteIssue(title: "Sunucuya bağlanılamadı", detail: failure.message, severity: .high)]
        case nil: return []
        }
    }

    func metrics(for profile: SSHProfile) -> RemoteMetrics? {
        if case .success(let metrics) = results[profile.id] { return metrics }
        return nil
    }

    /// Parola kimliğinde parola önce Anahtar Zinciri'ne yazılır. Yazma başarısızsa profil eklenmez.
    func addProfile(name: String, host: String, port: Int, user: String, auth: SSHAuth, services: [String], backupPath: String? = nil,
                    platform: RemotePlatform? = nil, keyPath: String? = nil, password: String) {
        guard profiles.count < Self.maxProfiles else {
            errorText = "En çok \(Self.maxProfiles) sunucu izlenir."
            return
        }
        guard let profile = SSHProfile.make(name: name, host: host, port: port, user: user, auth: auth, services: services,
                                            backupPath: backupPath, platform: platform, keyPath: keyPath) else {
            errorText = "Alan adı, kullanıcı, port veya anahtar yolu geçersiz. Şema olmadan yazın. Anahtar yolu / veya ~/ ile başlar."
            return
        }
        guard !profiles.contains(where: { $0.host == profile.host && $0.user == profile.user && $0.port == profile.port }) else {
            errorText = "Bu sunucu ve kullanıcı zaten listede."
            return
        }
        if auth == .password {
            guard !password.isEmpty else {
                errorText = "Parola kimliği için parola gerekir."
                return
            }
            do { try secrets.set(Data(password.utf8), account: profile.id) } catch {
                errorText = "Parola Anahtar Zinciri'ne yazılamadı. \(error)"
                return
            }
        }
        errorText = nil
        save(profiles + [profile])
        refresh()
    }

    func clearError() { errorText = nil }

    /// Profili yerinde değiştirir. Kimlik ve sıra korunur. Parola boşsa kayıtlı parola kalır.
    /// Anahtar kimliğine geçince kayıtlı parola silinir. Başarısız değişiklik profili olduğu gibi bırakır.
    @discardableResult
    func updateProfile(id: String, name: String, host: String, port: Int, user: String, auth: SSHAuth, services: [String],
                       thresholds: ServerThresholds?, backupPath: String? = nil, platform: RemotePlatform? = nil, keyPath: String? = nil, password: String) -> Bool {
        guard let index = profiles.firstIndex(where: { $0.id == id }) else {
            errorText = "Sunucu bulunamadı."
            return false
        }
        guard let profile = SSHProfile.make(name: name, host: host, port: port, user: user, auth: auth, services: services,
                                            thresholds: thresholds, backupPath: backupPath, platform: platform, keyPath: keyPath, id: id) else {
            errorText = "Alan adı, kullanıcı, port, eşik, yedek yolu veya anahtar yolu geçersiz."
            return false
        }
        guard !profiles.contains(where: { $0.id != id && $0.host == profile.host && $0.user == profile.user && $0.port == profile.port }) else {
            errorText = "Bu sunucu ve kullanıcı zaten listede."
            return false
        }
        if auth == .password {
            if password.isEmpty {
                let stored = (try? secrets.get(account: id)) ?? nil
                guard stored != nil else {
                    errorText = "Parola kimliği için parola gerekir."
                    return false
                }
            } else {
                do { try secrets.set(Data(password.utf8), account: id) } catch {
                    errorText = "Parola Anahtar Zinciri'ne yazılamadı. \(error)"
                    return false
                }
            }
        } else {
            try? secrets.delete(account: id)
        }
        errorText = nil
        var next = profiles
        next[index] = profile
        var nextResults = results
        nextResults[id] = nil
        results = nextResults
        save(next)
        publishAlerts()
        refresh()
        return true
    }

    /// Yalnızca başarılı okumalar örnek ekler. Silinen sunucunun geçmişi tutulmaz.
    private func recordHistory(_ fresh: [String: Result<RemoteMetrics, SSHFailure>], live: Set<String>) {
        var next = history.filter { live.contains($0.key) }
        for (id, result) in fresh where live.contains(id) {
            guard case .success(let metrics) = result else { continue }
            if RebootDetector.rebooted(previous: lastUptime[id], current: metrics.uptimeSeconds), let uptime = metrics.uptimeSeconds {
                reboots[id] = RebootDetector.appending(RebootDetector.rebootDate(now: now(), uptime: uptime), to: reboots[id] ?? [])
            }
            lastUptime[id] = metrics.uptimeSeconds
            next[id] = MetricHistory.appending(MetricSample(metrics: metrics, date: now()), to: next[id] ?? [])
        }
        history = next
    }

    func removeProfile(_ profile: SSHProfile) {
        try? secrets.delete(account: profile.id)
        history[profile.id] = nil
        reboots[profile.id] = nil
        responseMs[profile.id] = nil
        lastUptime[profile.id] = nil
        var next = results
        next[profile.id] = nil
        results = next
        inventory[profile.id] = nil
        inventoryErrors[profile.id] = nil
        save(profiles.filter { $0.id != profile.id })
        publishAlerts()
    }

    /// Tüm sunucuları paralel okur. Parola eksikse bağlanmadan hata verir.
    func checkAll() async {
        let targets = profiles
        var jobs: [(SSHProfile, String?)] = []
        var fresh: [String: Result<RemoteMetrics, SSHFailure>] = [:]
        for profile in targets {
            if profile.auth == .password {
                let stored = (try? secrets.get(account: profile.id)) ?? nil
                guard let stored, let password = String(data: stored, encoding: .utf8) else {
                    fresh[profile.id] = .failure(SSHFailure(message: "Parola Anahtar Zinciri'nde bulunamadı. Sunucuyu silip yeniden ekleyin."))
                    continue
                }
                jobs.append((profile, password))
            } else {
                jobs.append((profile, nil))
            }
        }
        let collector = collector
        let timed = await withTaskGroup(of: (String, Result<RemoteMetrics, SSHFailure>, Int).self) { group in
            for (profile, password) in jobs {
                group.addTask {
                    let start = ContinuousClock.now
                    let result = await collector.collect(profile, password: password)
                    let elapsed = start.duration(to: .now).components
                    return (profile.id, result, Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000))
                }
            }
            var all: [(String, Result<RemoteMetrics, SSHFailure>, Int)] = []
            for await item in group { all.append(item) }
            return all
        }
        let collected = Dictionary(uniqueKeysWithValues: timed.map { ($0.0, $0.1) })
        var times = responseMs.filter { id, _ in targets.contains { $0.id == id } }
        for (id, result, ms) in timed {
            if case .success = result { times[id] = ms } else { times[id] = nil }
        }
        responseMs = times
        fresh.merge(collected) { $1 }
        // Kontrol sürerken silinen sunucu sonuç listesine geri girmez.
        let live = Set(profiles.map(\.id))
        results = fresh.filter { live.contains($0.key) }
        recordHistory(fresh, live: live)
        checked = true
        publishAlerts()
    }

    /// Seçilen sunucunun paket listesini okur. Yalnızca kullanıcı isteğiyle çalışır.
    func loadInventory(_ profile: SSHProfile) async {
        guard !loadingInventory.contains(profile.id) else { return }
        guard !profile.isWindows else {
            inventoryErrors[profile.id] = "Paket listesi yalnızca Linux sunucularda okunur."
            return
        }
        var password: String?
        if profile.auth == .password {
            guard let stored = (try? secrets.get(account: profile.id)) ?? nil, let text = String(data: stored, encoding: .utf8) else {
                inventoryErrors[profile.id] = "Parola Anahtar Zinciri'nde bulunamadı."
                return
            }
            password = text
        }
        loadingInventory.insert(profile.id)
        inventoryErrors[profile.id] = nil
        let result = await lister.packages(profile, password: password)
        loadingInventory.remove(profile.id)
        guard profiles.contains(where: { $0.id == profile.id }) else { return }
        switch result {
        case .success(let items): inventory[profile.id] = items
        case .failure(let failure): inventory[profile.id] = nil; inventoryErrors[profile.id] = failure.message
        }
    }

    func refresh() {
        guard !checking else { return }
        checking = true
        Task {
            await checkAll()
            checking = false
        }
    }

    /// Uygulama açıkken 5 dakikada bir okur. İkinci çağrı bir şey yapmaz.
    func startPolling(every seconds: UInt64 = 300) {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }

    private func publishAlerts() {
        let total = profiles.reduce(0) { $0 + RemoteHealth.alertCount(issues(for: $1)) }
        nobet.setAlerts(total, for: "remote")
        alerts?.ingest(module: "remote", issues: alertIssues())
    }

    static func alertKey(profile: SSHProfile, issue: RemoteIssue) -> String {
        "remote|\(profile.id)|\(issue.title)"
    }

    /// Bildirilebilir sorunlar. Ayrıntı metni (`detail`) bildirime girmez, çünkü sunucudan gelir.
    func alertIssues() -> [AlertIssue] {
        profiles.flatMap { profile in
            issues(for: profile).map {
                AlertIssue(key: Self.alertKey(profile: profile, issue: $0), module: "remote", subject: profile.name,
                           title: $0.title, severity: $0.severity)
            }
        }
    }

    private func save(_ next: [SSHProfile]) {
        profiles = next
        defaults.set(try? JSONEncoder().encode(next), forKey: Self.profilesKey)
    }
}
