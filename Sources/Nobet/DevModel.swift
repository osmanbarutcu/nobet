import Foundation

/// Geliştirme sayfasının durumu. Okuma arka planda yapılır. Eylemler önce onay bekler.
@MainActor
final class DevModel: ObservableObject {
    static let shared = DevModel(nobet: .shared, alerts: .shared)

    @Published private(set) var overview = DevOverview.empty
    @Published private(set) var loading = false
    @Published private(set) var loaded = false
    @Published private(set) var pending: DevAction?
    @Published private(set) var errorText: String?

    private let nobet: NobetModel
    private let alerts: AlertCenter?
    private var polling: Task<Void, Never>?

    init(nobet: NobetModel, alerts: AlertCenter? = nil) {
        self.nobet = nobet
        self.alerts = alerts
    }

    /// Okunan sonucu yayınlar ve menü çubuğu uyarı sayısını günceller.
    func apply(_ next: DevOverview) {
        overview = next
        loaded = true
        nobet.setAlerts(next.alertCount, for: "dev")
        alerts?.ingest(module: "dev", issues: Self.alertIssues(next))
    }

    /// Tüm ağa açık proje portları. Anahtar proje ve port numarasından oluşur, PID yeniden başlatmada değişir.
    nonisolated static func alertIssues(_ overview: DevOverview) -> [AlertIssue] {
        let exposed = overview.projects.flatMap { project in
            project.ports.filter { $0.scope == .all }.map {
                AlertIssue(key: "dev|\(AlertKey.digest(project.id))|\($0.port)", module: "dev", subject: "\(project.name) :\($0.port)",
                           title: "Port tüm ağa açık", severity: .medium)
            }
        }
        let conflicts = overview.conflicts.map {
            AlertIssue(key: "dev|conflict|\($0.port)", module: "dev", subject: ":\($0.port) · \($0.processes.joined(separator: ", "))",
                       title: "Port çakışması", severity: .medium)
        }
        return exposed + conflicts
    }

    func reload() {
        guard !loading else { return }
        loading = true
        Task {
            let next = await Task.detached(priority: .utility) { DevRunner.snapshot() }.value
            apply(next)
            loading = false
        }
    }

    /// Uygulama açıkken uyarı sayısı güncel kalsın diye düzenli okur. İkinci çağrı bir şey yapmaz.
    func startPolling(every seconds: UInt64 = 60) {
        guard polling == nil else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                self?.reload()
                try? await Task.sleep(nanoseconds: seconds * 1_000_000_000)
            }
        }
    }

    /// Geçerli eylem onay bekler. Geçersiz eylem hata metni verir ve bekletilmez.
    func request(_ action: DevAction) {
        guard action.command != nil else {
            errorText = "Eylem geçersiz: ad veya numara güvenli değil."
            return
        }
        errorText = nil
        pending = action
    }

    func cancel() {
        pending = nil
    }

    /// Onay penceresinin yakaladığı eylemi çalıştırır. Pencere kapanırken `cancel` önce çalışsa bile eylem kaybolmaz.
    func confirm(_ action: DevAction) {
        pending = nil
        Task {
            let failure = await Task.detached(priority: .userInitiated) { DevRunner.execute(action) }.value
            errorText = failure
            loading = false
            reload()
        }
    }
}
