import Foundation

/// Tek bir okumanın sonucu. `connections` nil ise önceki bağlantı listesi korunur.
struct NetworkSnapshot: Equatable {
    let listeners: [NetworkListener]
    let connections: [NetworkConnection]?
}

/// Onay bekleyen süreç sonlandırma isteği.
struct NetworkTermination: Equatable, Identifiable {
    let action: DevAction
    let process: String
    let signature: SignatureStatus

    var id: String { action.summary }

    private var pid: Int {
        if case .terminate(let pid) = action { return pid }
        return 0
    }

    var title: String { "Süreç sonlandırılacak: \(process) (PID \(pid))" }

    var message: String {
        let base = "İşlem onaydan hemen sonra çalışır."
        return signature == .apple ? "Apple sistem süreci. Sonlandırma sistemi etkileyebilir. \(base)" : base
    }
}

extension NetworkListener {
    /// Her dinleyiciye ikili dosya kimliği ekler. Çalışma klasörü bir projedeyse port proje portu sayılır.
    /// Sıra girdi sırasıdır.
    static func build(
        ports: [ListeningPort], cwds: [Int: String], home: String,
        identityOf: (Int) -> ProcessIdentity, exists: (String) -> Bool
    ) -> [NetworkListener] {
        ports.map { port in
            let root = cwds[port.pid].flatMap { ProjectRoot.find(from: $0, home: home, exists: exists) }
            return NetworkListener(port: port, identity: identityOf(port.pid), isProjectPort: root != nil)
        }
    }
}

/// Ağ sayfasının durumu. Dinleyiciler arka planda okunur. Bağlantılar yalnızca sayfa açıkken okunur.
/// Diske yalnızca taban çizgisi özetleri yazılır. Yol, süreç adı ve IP yazılmaz.
@MainActor
final class NetworkModel: ObservableObject {
    static let shared = NetworkModel(nobet: .shared, alerts: .shared)

    @Published private(set) var listeners: [NetworkListener] = []
    @Published private(set) var connections: [NetworkConnection] = []
    @Published private(set) var baseline: NetworkBaseline
    @Published private(set) var newKeys: Set<String> = []
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var pending: NetworkTermination?
    @Published private(set) var errorText: String?

    private let nobet: NobetModel
    private let defaults: UserDefaults
    private let alerts: AlertCenter?
    private let home: String
    private let checker: SignatureChecking
    private var polling: Task<Void, Never>?

    init(nobet: NobetModel, defaults: UserDefaults = .standard, alerts: AlertCenter? = nil,
         home: String = NSHomeDirectory(), checker: SignatureChecking = CachedSignatureChecker()) {
        self.nobet = nobet
        self.defaults = defaults
        self.alerts = alerts
        self.home = home
        self.checker = checker
        baseline = NetworkBaselineStore.load(from: defaults)
    }

    var health: NetworkHealth {
        NetworkHealth(listeners: listeners, newKeys: newKeys, trusted: baseline.trusted)
    }

    func isTrusted(_ listener: NetworkListener) -> Bool { baseline.isTrusted(listener.digest) }

    /// Okunan sonucu yayınlar. İlk okuma mevcut durumu sessizce öğrenir.
    func apply(_ snapshot: NetworkSnapshot) {
        let keys = Set(snapshot.listeners.filter { !$0.isProjectPort }.map(\.digest))
        let observed = baseline.observing(keys)
        setBaseline(observed.baseline)
        newKeys = observed.newKeys
        listeners = snapshot.listeners
        if let connections = snapshot.connections { self.connections = connections }
        loaded = true
        publishAlerts()
    }

    private func setBaseline(_ next: NetworkBaseline) {
        guard next != baseline else { return }
        baseline = next
        NetworkBaselineStore.save(next, to: defaults)
    }

    private func publishAlerts() {
        let issues = NetworkRules.alertIssues(listeners, newKeys: newKeys, trusted: baseline.trusted)
        nobet.setAlerts(issues.count, for: "net")
        alerts?.ingest(module: "net", issues: issues)
    }

    /// Öğrenme bittiyse, bilinmeyen ve güvenilir olmayan proje dışı anahtarlar "yeni" sayılır.
    private func recomputeNewKeys() {
        guard baseline.learned else {
            newKeys = []
            return
        }
        let keys = Set(listeners.filter { !$0.isProjectPort }.map(\.digest))
        newKeys = keys.subtracting(baseline.known).subtracting(baseline.trusted)
    }

    /// Süreci güvenilir işaretler. Bu süreç ve kapsam için hiçbir kural uyarı üretmez.
    func trust(_ listener: NetworkListener) {
        setBaseline(baseline.trusting(listener.digest))
        recomputeNewKeys()
        publishAlerts()
    }

    func untrust(_ listener: NetworkListener) {
        setBaseline(baseline.untrusting(listener.digest))
        recomputeNewKeys()
        publishAlerts()
    }

    /// Öğrenilen kümeyi siler. Sonraki okuma mevcut durumu yeniden sessizce öğrenir. Güvenilir liste kalır.
    func resetBaseline(rescan: Bool = true) {
        setBaseline(baseline.reset())
        newKeys = []
        publishAlerts()
        if rescan { reload() }
    }

    nonisolated static func read(home: String, checker: SignatureChecking) -> NetworkSnapshot {
        let ports = PortScan.scan()
        let pids = Set(ports.map(\.pid))
        var cwds: [Int: String] = [:]
        if !pids.isEmpty,
           let result = DevRunner.run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fpn", "-p", pids.sorted().map(String.init).joined(separator: ",")], timeout: 8) {
            cwds = ProcessCwd.parse(result.output)
        }
        let listeners = NetworkListener.build(
            ports: ports, cwds: cwds, home: home,
            identityOf: { ProcessTrust.identity(pid: $0, home: home, checker: checker) },
            exists: { FileManager.default.fileExists(atPath: $0) })
        return NetworkSnapshot(listeners: listeners, connections: nil)
    }

    func reload() {
        guard !loading, !DemoMode.isOn else { return }
        loading = true
        let home = home
        let checker = checker
        Task {
            let next = await Task.detached(priority: .utility) { Self.read(home: home, checker: checker) }.value
            apply(next)
            loading = false
        }
    }

    /// Dinleyiciler uyarı sayısı güncel kalsın diye düzenli okunur. İkinci çağrı bir şey yapmaz.
    func startPolling(every seconds: UInt64 = 60) {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                self?.reload()
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }

    /// Bağlantılar hassas ve pahalıdır. Yalnızca sayfa açıkken okunur. Görünüm kapanınca görev iptal olur.
    func watchConnections(every seconds: UInt64 = 10) async {
        guard !DemoMode.isOn else { return }
        while !Task.isCancelled {
            connections = await Task.detached(priority: .utility) { NetworkScan.scan() }.value
            try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
        }
    }

    /// Geçerli eylem onay bekler. PID 1 ve Nöbet'in kendisi reddedilir.
    func request(terminating listener: NetworkListener) {
        let action = DevAction.terminate(pid: listener.port.pid)
        guard action.command != nil else {
            errorText = "Eylem geçersiz: bu süreç sonlandırılamaz."
            return
        }
        errorText = nil
        pending = NetworkTermination(action: action, process: listener.port.process, signature: listener.identity.signature)
    }

    func cancel() {
        pending = nil
    }

    /// Onay penceresinin yakaladığı eylemi çalıştırır. Pencere kapanırken `cancel` önce çalışsa bile eylem kaybolmaz.
    func confirm(_ termination: NetworkTermination) {
        pending = nil
        let action = termination.action
        Task {
            let failure = await Task.detached(priority: .userInitiated) { DevRunner.execute(action) }.value
            errorText = failure
            loading = false
            reload()
        }
    }
}
