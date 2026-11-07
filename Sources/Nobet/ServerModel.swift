import Foundation

/// Sunucular sayfasının durumu. Site listesi `UserDefaults` içinde durur. Sonuçlar yalnızca bellekte kalır.
@MainActor
final class ServerModel: ObservableObject {
    static let shared = ServerModel(nobet: .shared, prober: DemoMode.prober, alerts: .shared, history: DemoMode.siteHistoryFile())

    static let sitesKey = "servers.sites"
    static let maxSites = 50

    @Published private(set) var sites: [ServerSite]
    @Published private(set) var results: [String: ProbeResult] = [:]
    @Published private(set) var checking = false
    @Published private(set) var checked = false
    /// Site başına son 24 saatin kontrolleri. Yalnızca bellekte durur.
    @Published private(set) var history: [String: [SiteSample]] = [:] {
        didSet { historyFile?.save(history) }
    }
    @Published private(set) var errorText: String?

    private let nobet: NobetModel
    private let defaults: UserDefaults
    private let prober: ServerProbing
    private let now: () -> Date
    private let alerts: AlertCenter?
    private let historyFile: HistoryFile<SiteSample>?
    private var polling: Task<Void, Never>?

    init(nobet: NobetModel, defaults: UserDefaults = .standard, prober: ServerProbing = NetworkProber(), now: @escaping () -> Date = Date.init,
         alerts: AlertCenter? = nil, history: HistoryFile<SiteSample>? = nil) {
        historyFile = history
        self.alerts = alerts
        self.nobet = nobet
        self.defaults = defaults
        self.prober = prober
        self.now = now
        let data = defaults.data(forKey: Self.sitesKey)
        sites = data.flatMap { try? JSONDecoder().decode([ServerSite].self, from: $0) } ?? []
        self.history = history?.load(now: now()) ?? [:]
    }

    func issues(for site: ServerSite) -> [ServerIssue] {
        results[site.id].map { SiteHealth.issues(for: $0, now: now()) } ?? []
    }

    func addSite(name: String, host: String, port: Int) {
        guard sites.count < Self.maxSites else {
            errorText = "En çok \(Self.maxSites) site izlenir."
            return
        }
        guard let site = ServerSite.make(name: name, host: host, port: port) else {
            errorText = "Alan adı veya port geçersiz. Şema ve yol olmadan yazın, örnek: example.com"
            return
        }
        guard !sites.contains(where: { $0.host == site.host && $0.port == site.port }) else {
            errorText = "Bu site zaten listede."
            return
        }
        errorText = nil
        save(sites + [site])
        refresh()
    }

    func clearError() { errorText = nil }

    /// Siteyi yerinde değiştirir. Kimlik ve sıra korunur. Başarısız değişiklik siteyi olduğu gibi bırakır.
    @discardableResult
    func updateSite(id: String, name: String, host: String, port: Int) -> Bool {
        guard let index = sites.firstIndex(where: { $0.id == id }) else {
            errorText = "Site bulunamadı."
            return false
        }
        guard let site = ServerSite.make(name: name, host: host, port: port, id: id) else {
            errorText = "Alan adı veya port geçersiz. Şema ve yol olmadan yazın, örnek: example.com"
            return false
        }
        guard !sites.contains(where: { $0.id != id && $0.host == site.host && $0.port == site.port }) else {
            errorText = "Bu site zaten listede."
            return false
        }
        errorText = nil
        var next = sites
        next[index] = site
        var nextResults = results
        nextResults[id] = nil
        results = nextResults
        history[id] = nil
        save(next)
        publishAlerts()
        refresh()
        return true
    }

    func removeSite(_ site: ServerSite) {
        var next = results
        next[site.id] = nil
        results = next
        history[site.id] = nil
        save(sites.filter { $0.id != site.id })
        publishAlerts()
    }

    /// Tüm siteleri paralel kontrol eder. Sonuç gelince menü çubuğu uyarı sayısı güncellenir.
    func checkAll() async {
        let targets = sites
        let prober = prober
        let fresh = await withTaskGroup(of: (String, ProbeResult).self) { group in
            for site in targets { group.addTask { (site.id, await prober.probe(site)) } }
            var collected: [String: ProbeResult] = [:]
            for await (id, result) in group { collected[id] = result }
            return collected
        }
        // Kontrol sürerken silinen site sonuç listesine geri girmez.
        let live = Set(sites.map(\.id))
        results = fresh.filter { live.contains($0.key) }
        recordHistory(fresh, live: live)
        checked = true
        publishAlerts()
    }

    private func recordHistory(_ fresh: [String: ProbeResult], live: Set<String>) {
        var next = history.filter { live.contains($0.key) }
        for (id, result) in fresh where live.contains(id) {
            let sample = SiteSample(date: now(), up: result.reachable, latencyMs: result.latencyMs)
            next[id] = SiteHistory.appending(sample, to: next[id] ?? [])
        }
        history = next
    }

    func refresh() {
        guard !checking else { return }
        checking = true
        Task {
            await checkAll()
            checking = false
        }
    }

    /// Uygulama açıkken 5 dakikada bir kontrol eder. İkinci çağrı bir şey yapmaz.
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
        let total = sites.reduce(0) { $0 + SiteHealth.alertCount(issues(for: $1)) }
        nobet.setAlerts(total, for: "servers")
        alerts?.ingest(module: "servers", issues: alertIssues())
    }

    /// Bildirilebilir sorunlar. Anahtar site kimliği ve sorun türünden oluşur, böylece aynı sorun aynı anahtarı üretir.
    func alertIssues() -> [AlertIssue] {
        sites.flatMap { site in
            issues(for: site).map {
                AlertIssue(key: "servers|\(site.id)|\($0.kind.rawValue)", module: "servers", subject: site.host,
                           title: $0.kind.title, severity: $0.severity)
            }
        }
    }

    private func save(_ next: [ServerSite]) {
        sites = next
        defaults.set(try? JSONEncoder().encode(next), forKey: Self.sitesKey)
    }
}
