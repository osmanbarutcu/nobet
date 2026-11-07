import Foundation

/// Ekran görüntüsü için sahte veri kipi. Gerçek sunucuya, ağa, Anahtar Zinciri'ne ve bildirime dokunmaz.
/// İki koşul birlikte gerekir: `NOBET_DEMO=1` ortam değişkeni ve `local.nobet.demo` paket kimliği.
/// Paket kimliği ayrı olduğu için gerçek uygulamanın ayarlarına yazılmaz. `scripts/demo.sh` bu kopyayı kurar.
enum DemoMode {
    static let bundleID = "local.nobet.demo"

    static let isOn: Bool = {
        ProcessInfo.processInfo.environment["NOBET_DEMO"] == "1" && Bundle.main.bundleIdentifier == bundleID
    }()

    /// Belgelerdeki örnek alan adları (RFC 2606). Gerçek bir sunucuya çözülmez.
    static let profiles: [SSHProfile] = [
        SSHProfile.make(name: "Web sunucusu", host: "web-01.example.com", port: 22, user: "deploy", auth: .key,
                        services: ["nginx", "php8.3-fpm"], id: "demo-web"),
        SSHProfile.make(name: "Veritabanı", host: "db-01.example.com", port: 22, user: "deploy", auth: .key,
                        services: ["postgresql", "redis-server"], id: "demo-db"),
        SSHProfile.make(name: "Yedek sunucusu", host: "backup-01.example.com", port: 22, user: "deploy", auth: .key,
                        services: ["cron"], backupPath: "/srv/backups", id: "demo-backup"),
    ].compactMap { $0 }

    static let sites: [ServerSite] = [
        ServerSite.make(name: "Ana site", host: "www.example.com", port: 443, id: "demo-site-www"),
        ServerSite.make(name: "Mağaza", host: "shop.example.org", port: 443, id: "demo-site-shop"),
        ServerSite.make(name: "Blog", host: "blog.example.net", port: 443, id: "demo-site-blog"),
        ServerSite.make(name: "API", host: "api.example.dev", port: 443, id: "demo-site-api"),
        ServerSite.make(name: "Durum sayfası", host: "status.example.io", port: 443, id: "demo-site-status"),
    ].compactMap { $0 }

    static var notifier: AlertNotifying { isOn ? DemoNotifier() : SystemAlertNotifier() }

    static var collector: RemoteCollecting { isOn ? DemoCollector() : SSHRunner() }

    static var prober: ServerProbing { isOn ? DemoProber() : NetworkProber() }

    private static let tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("nobet-demo")

    /// Demo kipinde geçici dosyadan, değilse Ayarlar'daki isteğe bağlı kopyadan okur.
    static func metricHistoryFile() -> HistoryFile<MetricSample>? {
        isOn ? HistoryFile(url: tempDirectory.appendingPathComponent("metric-history.json")) : HistoryFile.standard(named: "metric-history.json")
    }

    static func siteHistoryFile() -> HistoryFile<SiteSample>? {
        isOn ? HistoryFile(url: tempDirectory.appendingPathComponent("site-history.json")) : HistoryFile.standard(named: "site-history.json")
    }

    /// Demo kipinde ayarları, sunucu listelerini ve 24 saatlik geçmişi yazar. Kip kapalıysa hiçbir şey yapmaz.
    @MainActor
    static func prepare(defaults: UserDefaults = .standard, now: Date = Date()) {
        guard isOn else { return }
        let encoder = JSONEncoder()
        defaults.set(try? encoder.encode(profiles), forKey: RemoteModel.profilesKey)
        defaults.set(try? encoder.encode(sites), forKey: ServerModel.sitesKey)
        defaults.set(true, forKey: "onboarding.done")
        defaults.set(try? encoder.encode(alertHistory(now: now)), forKey: AlertCenter.historyKey)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let metrics = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, metricSamples(for: $0.id, now: now)) })
        let siteSeries = Dictionary(uniqueKeysWithValues: sites.map { ($0.id, siteSamples(for: $0.id, now: now)) })
        try? encoder.encode(metrics).write(to: tempDirectory.appendingPathComponent("metric-history.json"))
        try? encoder.encode(siteSeries).write(to: tempDirectory.appendingPathComponent("site-history.json"))
    }

    /// Geliştirme ve Sırlar modülleri gerçek diski tarar. Demo kipte tarama kapalıdır, sorunlar uydurmadır.
    @MainActor
    static func ingestFakeModules(into center: AlertCenter, nobet: NobetModel) {
        let dev = [AlertIssue(key: "dev|demo|node", module: "dev", subject: "Node.js", title: "Sürüm destek dışı", severity: .medium)]
        let secrets = [AlertIssue(key: "secrets|demo|key", module: "secrets", subject: "ornek-proje/config.ts",
                                  title: "Koda yazılmış API anahtarı", severity: .high)]
        center.ingest(module: "dev", issues: dev)
        center.ingest(module: "secrets", issues: secrets)
        nobet.setAlerts(dev.count, for: "dev")
        nobet.setAlerts(secrets.count, for: "secrets")
    }

    // MARK: - Üretilen geçmiş

    /// 5 dakikada bir 288 örnek. Seri sabit formülden gelir, her çalıştırmada aynı çıkar.
    static func metricSamples(for id: String, now: Date) -> [MetricSample] {
        (0..<288).map { index in
            let date = now.addingTimeInterval(-Double(287 - index) * 300)
            let t = Double(index)
            switch id {
            case "demo-db":
                return MetricSample(date: date, diskPercent: 86 + index / 96, memoryPercent: Int(68 + 6 * sin(t / 18)),
                                    load: 1.2 + 0.5 * sin(t / 23) + 0.2 * sin(t / 6))
            case "demo-backup":
                return MetricSample(date: date, diskPercent: 54 + index / 90, memoryPercent: Int(31 + 4 * sin(t / 25)),
                                    load: 0.2 + 0.08 * sin(t / 31))
            default:
                return MetricSample(date: date, diskPercent: 41 + index / 144, memoryPercent: Int(57 + 9 * sin(t / 20)),
                                    load: 0.5 + 0.25 * sin(t / 29) + 0.1 * sin(t / 7))
            }
        }
    }

    static func siteSamples(for id: String, now: Date) -> [SiteSample] {
        (0..<288).map { index in
            let date = now.addingTimeInterval(-Double(287 - index) * 300)
            let i = Double(index)
            let wave = 0.55 * abs(sin(i / 38)) + 0.45 * abs(sin(i / 7.3 + 1))
            switch id {
            case "demo-site-api": return SiteSample(date: date, up: index < 250 || index > 262, latencyMs: Int(210 + 120 * wave))
            case "demo-site-blog": return SiteSample(date: date, up: true, latencyMs: Int(1500 + 600 * wave))
            case "demo-site-shop": return SiteSample(date: date, up: true, latencyMs: Int(260 + 90 * wave))
            default: return SiteSample(date: date, up: true, latencyMs: Int(110 + 50 * wave))
            }
        }
    }

    /// Son 24 saate dağılmış başlayan ve çözülen sorunlar. Genel sayfadaki grafik bunu çizer.
    static func alertHistory(now: Date) -> [AlertEvent] {
        let plan: [(hoursAgo: Double, module: String, subject: String, title: String, severity: Severity, resolved: Bool)] = [
            (22, "servers", "Mağaza", "Yanıt yavaş", .info, true),
            (19, "remote", "Veritabanı", "Disk dolmak üzere", .medium, false),
            (15, "servers", "API", "Site kapalı", .high, true),
            (14.5, "servers", "API", "Site kapalı", .high, false),
            (11, "remote", "Yedek sunucusu", "Yeniden başlatma gerekli", .info, false),
            (8, "secrets", "ornek-proje/config.ts", "Koda yazılmış API anahtarı", .high, false),
            (6, "remote", "Veritabanı", "Servis çalışmıyor", .high, false),
            (3, "dev", "Node.js", "Sürüm destek dışı", .medium, false),
            (2, "servers", "Mağaza", "Sertifika süresi doluyor", .medium, false),
        ]
        return plan.map { item in
            let issue = AlertIssue(key: "demo|\(item.module)|\(item.subject)|\(item.title)", module: item.module, subject: item.subject,
                                   title: item.title, severity: item.severity)
            return AlertEvent(kind: item.resolved ? .resolved : .started, issue: issue,
                              date: now.addingTimeInterval(-item.hoursAgo * 3600))
        }
    }
}

struct DemoNotifier: AlertNotifying {
    func notify(_ event: AlertEvent) {}
}

/// Ağa çıkmadan sabit ölçüm verir. Üç sunucunun üçü de farklı durumdadır.
struct DemoCollector: RemoteCollecting {
    func collect(_ profile: SSHProfile, password: String?) async -> Result<RemoteMetrics, SSHFailure> {
        let now = Int(Date().timeIntervalSince1970)
        var services: [String: ServiceState] = [:]
        for name in profile.services { services[name] = (profile.id == "demo-db" && name == "redis-server") ? .failed : .active }
        switch profile.id {
        case "demo-db":
            return .success(RemoteMetrics(
                disks: [DiskUsage(mount: "/", usedPercent: 89)],
                memory: MemoryUsage(totalMB: 16384, availableMB: 4700, swapTotalMB: 2048, swapUsedMB: 310),
                load: [1.6, 1.4, 1.2], cores: 8, uptimeSeconds: 63 * 86400, services: services, failedUnits: ["redis-server.service"],
                osName: "Ubuntu 24.04 LTS",
                security: SecurityPosture(permitRootLogin: "no", passwordAuthentication: false, fail2banActive: true,
                                          failedLogins: 14, publicPorts: [22, 5432], rebootRequired: false),
                databases: [DatabaseProbe(engine: .postgres, up: true)], errorLogs: 3))
        case "demo-backup":
            return .success(RemoteMetrics(
                disks: [DiskUsage(mount: "/", usedPercent: 57)],
                memory: MemoryUsage(totalMB: 4096, availableMB: 2800, swapTotalMB: 0, swapUsedMB: 0),
                load: [0.2, 0.2, 0.1], cores: 2, uptimeSeconds: 112 * 86400, services: services, failedUnits: [],
                osName: "Debian 12",
                security: SecurityPosture(permitRootLogin: "no", passwordAuthentication: false, fail2banActive: true,
                                          failedLogins: 2, publicPorts: [22], rebootRequired: true),
                backup: BackupState(newestEpoch: now - 3 * 86400 - 4000, serverEpoch: now), errorLogs: 0))
        default:
            return .success(RemoteMetrics(
                disks: [DiskUsage(mount: "/", usedPercent: 42)],
                memory: MemoryUsage(totalMB: 8192, availableMB: 3400, swapTotalMB: 1024, swapUsedMB: 40),
                load: [0.5, 0.6, 0.5], cores: 4, uptimeSeconds: 41 * 86400, services: services, failedUnits: [],
                osName: "Ubuntu 24.04 LTS",
                security: SecurityPosture(permitRootLogin: "no", passwordAuthentication: false, fail2banActive: true,
                                          failedLogins: 6, publicPorts: [22, 80, 443], rebootRequired: false),
                containers: [RemoteContainer(name: "app", state: "running", status: "Up 6 days"),
                             RemoteContainer(name: "queue", state: "running", status: "Up 6 days")],
                errorLogs: 0))
        }
    }
}

/// Ağa çıkmadan sabit yanıt verir. Her site farklı bir durumu gösterir.
struct DemoProber: ServerProbing {
    func probe(_ site: ServerSite) async -> ProbeResult {
        let day: TimeInterval = 86400
        switch site.id {
        case "demo-site-shop":
            return ProbeResult(reachable: true, httpStatus: 200, latencyMs: 280, certExpiry: Date().addingTimeInterval(9 * day), error: nil)
        case "demo-site-blog":
            return ProbeResult(reachable: true, httpStatus: 200, latencyMs: 1840, certExpiry: Date().addingTimeInterval(61 * day), error: nil)
        case "demo-site-api":
            return ProbeResult(reachable: true, httpStatus: 503, latencyMs: 240, certExpiry: Date().addingTimeInterval(44 * day), error: nil)
        default:
            return ProbeResult(reachable: true, httpStatus: 200, latencyMs: 128, certExpiry: Date().addingTimeInterval(78 * day), error: nil)
        }
    }
}
