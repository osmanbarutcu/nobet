import AppKit
import SwiftUI

/// `@State` bu araç zincirinde derlenmez. Görünüm durumu küçük bir nesnede durur.
private final class NetworkPageState: ObservableObject {
    @Published var showAllConnections = false
    @Published var confirmReset = false
}

/// Ağ: dinleyen süreçler, ikili dosya imzaları ve kurulmuş bağlantılar. Nöbet yalnızca okur ve bağlantı engellemez.
struct NetworkPage: View {
    @ObservedObject var model: NetworkModel
    @StateObject private var state = NetworkPageState()

    private static let connectionLimit = 12

    var body: some View {
        PageContainer {
            header
            if model.loaded { HealthCard(health: model.health, external: externalCount, newCount: model.newKeys.count) }
            if model.loaded && model.listeners.isEmpty {
                EmptyState(symbol: "network", title: "Dinleyen süreç yok",
                           message: "Bu Mac'te sizin süreçlerinizden dinleyen TCP portu bulunamadı.")
            }
            if !model.listeners.isEmpty { listenersCard }
            connectionsCard
            baselineCard
        }
        .onAppear { model.reload() }
        .task { await model.watchConnections() }
        .alert(
            model.pending?.title ?? "",
            isPresented: Binding(get: { model.pending != nil }, set: { if !$0 { model.cancel() } }),
            presenting: model.pending
        ) { termination in
            Button("İptal", role: .cancel) { model.cancel() }
            Button("Onayla", role: .destructive) { model.confirm(termination) }
        } message: { termination in
            Text(termination.message)
        }
        .alert("Taban çizgisi sıfırlansın mı?", isPresented: $state.confirmReset) {
            Button("İptal", role: .cancel) {}
            Button("Sıfırla", role: .destructive) { model.resetBaseline() }
        } message: {
            Text("Nöbet mevcut dinleyenleri yeniden sessizce öğrenir. Güvenilir listeniz kalır.")
        }
    }

    private var externalCount: Int { model.connections.filter { $0.reach == .external }.count }

    private var header: some View {
        let summary = "\(model.health.listening) dinleyen · \(model.health.issues) uyarı"
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                CardHeader(symbol: "network", title: "Ağ", trailing: model.loaded ? summary : "")
                if model.loading { ProgressView().controlSize(.small) }
                Button { model.reload() } label: { Image(systemName: "arrow.clockwise") }
                    .glassButton()
                    .controlSize(.small)
                    .disabled(model.loading)
                    .help("Yeniden tara")
                    .accessibilityLabel("Yeniden tara")
            }
            if let error = model.errorText {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
            Text("Nöbet yalnızca okur ve bağlantı engellemez. Yönetici yetkisi olmadan yalnızca sizin süreçleriniz görünür. Proje portları Geliştirme sayfasında kalır.")
                .font(.nobetFootnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var listenersCard: some View {
        let ordered = NetworkRules.displayOrder(model.listeners, newKeys: model.newKeys, trusted: model.baseline.trusted)
        return VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbol: "antenna.radiowaves.left.and.right", title: "Dinleyen süreçler", trailing: "\(ordered.count)")
            ForEach(ordered) { listener in
                ListenerRow(
                    listener: listener,
                    risks: NetworkRules.risks(for: listener, newKeys: model.newKeys, trusted: model.baseline.trusted),
                    trusted: model.isTrusted(listener), model: model)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var connectionsCard: some View {
        let all = model.connections
        let shown = state.showAllConnections ? all : Array(all.prefix(Self.connectionLimit))
        return VStack(alignment: .leading, spacing: 10) {
            CardHeader(symbol: "arrow.left.arrow.right", title: "Kurulmuş bağlantılar", trailing: "\(all.count)")
            if all.isEmpty {
                Text("Kurulmuş bağlantı yok.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(shown) { connection in
                ConnectionRow(connection: connection)
            }
            if all.count > Self.connectionLimit {
                Button(state.showAllConnections ? "Daha az göster" : "Tümünü göster (\(all.count))") {
                    state.showAllConnections.toggle()
                }
                .buttonStyle(.link).font(.caption)
            }
            Text("Bağlantılar yalnızca bu sayfa açıkken 10 saniyede bir okunur. Nöbet bunları diske yazmaz.")
                .font(.nobetFootnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var baselineCard: some View {
        let baseline = model.baseline
        let status = baseline.learned
            ? "Öğrenilen: \(baseline.known.count) · Güvenilir: \(baseline.trusted.count)"
            : "İlk tarama bekleniyor"
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                CardHeader(symbol: "scope", title: "Taban çizgisi", trailing: status)
                Button("Sıfırla") { state.confirmReset = true }
                    .glassButton()
                    .controlSize(.small)
                    .disabled(!baseline.learned)
            }
            Text("İlk tarama mevcut dinleyenleri sessizce öğrenir. Sonra yeni bir süreç dinlemeye başlarsa uyarı gelir. Zararlı bir süreç ilk taramadan önce çalışıyorsa yeni sayılmaz.")
                .font(.nobetFootnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

private struct HealthCard: View {
    let health: NetworkHealth
    let external: Int
    let newCount: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(symbol: health.level == .ok ? "checkmark.circle" : "exclamationmark.circle", title: health.headline)
            HStack(spacing: 18) {
                stat("Dinleyen", health.listening)
                stat("Ağa açık", health.exposed)
                stat("Yeni", newCount)
                stat("Dış bağlantı", external)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func stat(_ title: String, _ value: Int) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: String(value)).font(.title3.monospacedDigit().weight(.semibold))
            Text(title).font(.nobetFootnote).foregroundStyle(.secondary)
        }
    }
}

private struct ListenerRow: View {
    let listener: NetworkListener
    let risks: [NetworkRisk]
    let trusted: Bool
    @ObservedObject var model: NetworkModel

    private var name: String { listener.port.process.isEmpty ? "bilinmeyen" : listener.port.process }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(name).font(.caption.weight(.medium)).lineLimit(1)
                    Text(verbatim: listener.port.detail).font(.nobetFootnote.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if listener.isProjectPort {
                    Text("Proje").font(.nobetFootnote).foregroundStyle(.secondary)
                }
                Text(listener.port.scope.label)
                    .font(.nobetFootnote.weight(.semibold))
                    .foregroundStyle(listener.port.scope == .all ? Color.orange : Color.secondary)
                if let path = listener.identity.path {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                        Image(systemName: "folder")
                    }
                    .glassButton()
                    .controlSize(.small)
                    .help("Finder'da göster")
                    .accessibilityLabel("\(name) dosyasını Finder'da göster")
                }
                Button { model.request(terminating: listener) } label: { Image(systemName: "xmark.circle") }
                    .glassButton()
                    .controlSize(.small)
                    .help("Süreci sonlandır (SIGTERM)")
                    .accessibilityLabel("\(name) sürecini sonlandır")
            }
            HStack(spacing: 8) {
                Text(listener.identity.signature.label).font(.nobetFootnote).foregroundStyle(.secondary)
                if let path = listener.identity.path {
                    Text(verbatim: (path as NSString).abbreviatingWithTildeInPath)
                        .font(.nobetFootnote)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            ForEach(risks, id: \.self) { risk in
                Label(risk.title, systemImage: risk.severity.symbol)
                    .font(.nobetFootnote.weight(.semibold))
                    .foregroundStyle(risk.severity == .high ? Color.red : Color.orange)
            }
            if !listener.isProjectPort {
                Button(trusted ? "Güvenilir işareti kaldır" : "Güvenilir işaretle") {
                    if trusted { model.untrust(listener) } else { model.trust(listener) }
                }
                .buttonStyle(.link)
                .font(.nobetFootnote)
            }
        }
    }
}

private struct ConnectionRow: View {
    let connection: NetworkConnection

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 0) {
                Text(connection.process.isEmpty ? "bilinmeyen" : connection.process).font(.caption).lineLimit(1)
                Text(verbatim: connection.detail)
                    .font(.nobetFootnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Text(connection.reach.label)
                .font(.nobetFootnote.weight(connection.reach == .external ? .semibold : .regular))
                .foregroundStyle(.secondary)
        }
    }
}
