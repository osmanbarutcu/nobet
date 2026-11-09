import Foundation

/// Sırlar sayfasının durumu. Tarama arka planda çalışır. Bulgular diske yazılmaz, yalnızca ek klasör listesi saklanır.
@MainActor
final class SecretsModel: ObservableObject {
    static let shared = SecretsModel(nobet: .shared, alerts: .shared, autoRescan: true)

    static let foldersKey = "secrets.extraFolders"
    /// Yok sayılan bulguların özeti (`tür|yol özeti`). Yol diske yazılmaz.
    static let ignoredKey = "secrets.ignored"
    nonisolated static let scanTimeLimit: TimeInterval = 20

    @Published private(set) var findings: [SecretFinding] = []
    @Published private(set) var ignoredFindings: [SecretFinding] = []
    private var latest: [SecretFinding] = []
    private var ignored: Set<String>
    @Published private(set) var scanning = false
    @Published private(set) var scanned = false
    @Published private(set) var folders: [String]
    @Published private(set) var errorText: String?
    /// Son düzenleme sonucu. Yalnızca üst klasör ve dosya adı içerir. Değer içermez.
    @Published private(set) var notice: String?

    private let nobet: NobetModel
    private let defaults: UserDefaults
    private let home: String
    private let alerts: AlertCenter?
    private let autoRescan: Bool
    private var polling: Task<Void, Never>?

    init(nobet: NobetModel, defaults: UserDefaults = .standard, home: String = NSHomeDirectory(), alerts: AlertCenter? = nil,
         autoRescan: Bool = false) {
        self.alerts = alerts
        self.autoRescan = autoRescan
        self.nobet = nobet
        self.defaults = defaults
        self.home = home
        folders = defaults.stringArray(forKey: Self.foldersKey) ?? []
        ignored = Set(defaults.stringArray(forKey: Self.ignoredKey) ?? [])
    }

    private static func ignoreKey(_ finding: SecretFinding) -> String {
        "\(finding.kind.rawValue)|\(AlertKey.digest(finding.path))"
    }

    func ignore(_ finding: SecretFinding) {
        saveIgnored(ignored.union([Self.ignoreKey(finding)]))
    }

    func unignore(_ finding: SecretFinding) {
        saveIgnored(ignored.subtracting([Self.ignoreKey(finding)]))
    }

    private func saveIgnored(_ next: Set<String>) {
        ignored = next
        defaults.set(next.sorted(), forKey: Self.ignoredKey)
        apply(latest)
    }

    /// Taranan kökler: önce ev klasörü, sonra kullanıcının eklediği klasörler.
    var roots: [String] { [home] + folders }

    /// Okunan sonucu yayınlar ve menü çubuğu uyarı sayısını günceller.
    func apply(_ all: [SecretFinding]) {
        latest = all
        let next = all.filter { !ignored.contains(Self.ignoreKey($0)) }
        ignoredFindings = all.filter { ignored.contains(Self.ignoreKey($0)) }
        findings = next
        scanned = true
        nobet.setAlerts(SecretFinding.alertCount(next), for: "secrets")
        alerts?.ingest(module: "secrets", issues: next.map(Self.alertIssue))
    }

    /// Anahtar yolun özetidir, saklanan metne yol girmez. Konu yalnızca dosya adıdır.
    nonisolated static func alertIssue(_ finding: SecretFinding) -> AlertIssue {
        AlertIssue(key: "secrets|\(finding.kind.rawValue)|\(AlertKey.digest(finding.path))", module: "secrets",
                   subject: subject(for: finding.path), title: finding.kind.title, severity: finding.severity)
    }

    /// Üst klasör ve dosya adı. Tam yol bildirime girmez.
    nonisolated static func subject(for path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let parent = ((path as NSString).deletingLastPathComponent as NSString).lastPathComponent
        return parent.isEmpty || parent == "/" ? name : "\(parent)/\(name)"
    }

    func rescan() {
        guard !scanning else { return }
        scanning = true
        let roots = roots
        let home = home
        Task {
            let next = await Task.detached(priority: .utility) {
                SecretScanner.scan(roots: roots, home: home, git: SystemGit(), deadline: Date().addingTimeInterval(Self.scanTimeLimit))
            }.value
            apply(next)
            scanning = false
        }
    }

    /// Dosya düzenlendi. Sonuç değişmiş olabileceği için yeniden tarar.
    func didEdit(path: String) {
        notice = "\(Self.subject(for: path)) kaydedildi."
        rescan()
    }

    func dismissNotice() { notice = nil }

    /// Tarama pahalıdır. Uygulama açıkken 15 dakikada bir çalışır. İkinci çağrı bir şey yapmaz.
    func startPolling(every seconds: UInt64 = 900) {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                self?.rescan()
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }

    /// Var olan klasörü ekler. Dosya, eksik yol, ev klasörü ve yinelenen yol reddedilir veya yok sayılır.
    func addFolder(_ path: String) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            errorText = "Klasör bulunamadı: \(path)"
            return
        }
        errorText = nil
        guard path != home, !folders.contains(path) else { return }
        save(folders + [path])
    }

    func removeFolder(_ path: String) {
        save(folders.filter { $0 != path })
    }

    private func save(_ next: [String]) {
        folders = next
        defaults.set(next, forKey: Self.foldersKey)
        if autoRescan { rescan() }
    }
}
