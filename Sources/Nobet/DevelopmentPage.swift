import SwiftUI

/// Geliştirme ortamı: projeler, DDEV siteleri, konteynerler ve dinleyen portlar. Eylemler onay ister.
struct DevelopmentPage: View {
    @ObservedObject var model: DevModel

    var body: some View {
        PageContainer {
                header
                if model.loaded { HealthCard(health: DevHealth(overview: model.overview)) }
                if model.loaded && model.overview.projects.isEmpty && model.overview.otherPorts.isEmpty {
                    EmptyState(symbol: "hammer", title: "Çalışan proje yok",
                               message: "Dinleyen port veya Docker konteyneri bulunamadı. Bir geliştirme sunucusu başlatınca burada görünür.")
                }
                if !model.overview.conflicts.isEmpty {
                    ConflictCard(conflicts: model.overview.conflicts)
                }
                ForEach(model.overview.projects) { project in
                    ProjectCard(project: project, model: model)
                }
                if !model.overview.otherPorts.isEmpty {
                    OtherPortsCard(ports: model.overview.otherPorts)
                }
                SBOMCard(roots: sbomRoots)
        }
        .onAppear { model.reload() }
        .alert(
            model.pending?.summary ?? "",
            isPresented: Binding(get: { model.pending != nil }, set: { if !$0 { model.cancel() } }),
            presenting: model.pending
        ) { action in
            Button("İptal", role: .cancel) { model.cancel() }
            Button("Onayla", role: .destructive) { model.confirm(action) }
        } message: { _ in
            Text("İşlem onaydan hemen sonra çalışır.")
        }
    }

    /// SBOM taraması proje klasörlerine ve Sırlar'a eklenen klasörlere bakar.
    private var sbomRoots: [String] {
        model.overview.projects.compactMap(\.root) + SecretsModel.shared.folders
    }

    private var header: some View {
        let overview = model.overview
        let summary = "\(overview.projects.count) proje · \(DevHealth(overview: overview).exposed) ağa açık port"
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                CardHeader(symbol: "hammer", title: "Geliştirme ortamı", trailing: model.loaded ? summary : "")
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
            Text("Ağa açık: bağlı her ağdan erişilen port. Yerel: yalnızca bu Mac. Yönetici yetkisi olmadan yalnızca sizin süreçleriniz görünür.")
                .font(.nobetFootnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

private struct StatusDot: View {
    let running: Bool

    var body: some View {
        Circle()
            .fill(running ? Color.green : Color.secondary.opacity(0.5))
            .frame(width: 8, height: 8)
            .accessibilityHidden(true)
    }
}

private struct ProjectCard: View {
    let project: DevProject
    @ObservedObject var model: DevModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(symbol: "folder", title: project.name)
            if let root = project.root {
                Text(verbatim: (root as NSString).abbreviatingWithTildeInPath)
                    .font(.nobetFootnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            ForEach(project.ddevSites, id: \.name) { site in
                row(running: site.running, title: "DDEV · \(site.name)", detail: site.running ? "çalışıyor" : "durdu",
                    actionTitle: site.running ? "Durdur" : "Başlat",
                    action: site.running ? .ddevStop(site.name) : .ddevStart(site.name))
            }
            ForEach(project.standaloneContainers) { container in
                row(running: container.isRunning, title: container.name,
                    detail: container.portSummary.isEmpty ? container.status : "\(container.status) · \(container.portSummary)",
                    actionTitle: container.isRunning ? "Durdur" : "Başlat",
                    action: container.isRunning ? .stopContainer(container.id) : .startContainer(container.id))
            }
            ForEach(project.ports) { port in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(port.process.isEmpty ? "bilinmeyen" : port.process).font(.caption).lineLimit(1)
                        Text(verbatim: port.detail).font(.nobetFootnote.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Text(port.scope.label)
                        .font(.nobetFootnote.weight(.semibold))
                        .foregroundStyle(port.scope == .all ? Color.orange : Color.secondary)
                    Button { model.request(.terminate(pid: port.pid)) } label: { Image(systemName: "xmark.circle") }
                        .glassButton()
                        .controlSize(.small)
                        .help("Süreci sonlandır (SIGTERM)")
                        .accessibilityLabel("\(port.process) sürecini sonlandır")
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func row(running: Bool, title: String, detail: String, actionTitle: String, action: DevAction) -> some View {
        HStack(spacing: 8) {
            StatusDot(running: running)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption).lineLimit(1)
                Text(detail).font(.nobetFootnote).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 6)
            Button(actionTitle) { model.request(action) }
                .glassButton()
                .controlSize(.small)
        }
    }
}

private struct OtherPortsCard: View {
    let ports: [ListeningPort]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(symbol: "network", title: "Diğer portlar", trailing: "\(ports.count)")
            ForEach(ports) { port in
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(port.process.isEmpty ? "bilinmeyen" : port.process).font(.caption).lineLimit(1)
                        Text(verbatim: port.detail).font(.nobetFootnote.monospacedDigit()).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 6)
                    Text(port.scope.label)
                        .font(.nobetFootnote.weight(.semibold))
                        .foregroundStyle(port.scope == .all ? Color.orange : Color.secondary)
                }
            }
            Text("Bu portlar bir projeye bağlanamadı. Sistem servisleri olabilir. Nöbet bunları sonlandırmaz.")
                .font(.nobetFootnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

private struct ConflictCard: View {
    let conflicts: [PortConflict]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(symbol: "exclamationmark.triangle", title: "Port çakışması", trailing: "\(conflicts.count)")
            ForEach(conflicts) { conflict in
                HStack {
                    Text(verbatim: ":\(conflict.port)").font(.callout.monospacedDigit())
                    Spacer()
                    Text(conflict.processes.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Aynı portu birden çok süreç dinliyor. Süreç grupları bilerek bunu yapabilir. Nöbet süreç sonlandırmaz.")
                .font(.nobetFootnote).foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

private struct HealthCard: View {
    let health: DevHealth

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(symbol: health.level == .ok ? "checkmark.circle" : "exclamationmark.circle", title: health.headline)
            HStack(spacing: 18) {
                stat("Proje", health.projects)
                stat("Dinleyen port", health.listening)
                stat("Ağa açık", health.exposed)
                stat("Çakışma", health.conflicts)
                stat("Çalışan konteyner", health.containersRunning)
                stat("Duran konteyner", health.containersStopped)
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

/// `@State` bu araç zincirinde derlenmez. Süzgeç ve genişleme durumu küçük bir nesnede durur.
private final class SBOMViewState: ObservableObject {
    @Published var filter = SBOMFilter()
    @Published var expanded = false
}

private struct SBOMCard: View {
    let roots: [String]
    @ObservedObject private var sbom = SBOMModel.shared
    @StateObject private var state = SBOMViewState()

    var body: some View {
        let shown = state.filter.apply(sbom.components, vulnerabilities: sbom.vulnerabilities)
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardHeader(symbol: "shippingbox", title: "Bağımlılıklar (SBOM)",
                           trailing: sbom.scanned ? "\(sbom.components.count) bileşen · \(sbom.vulnerabilities.count) açıklı" : "")
                if sbom.scanning { ProgressView().controlSize(.small) }
                Button("Tara") { sbom.rescan(roots: roots) }.glassButton().controlSize(.small).disabled(sbom.scanning)
                Button("CycloneDX aktar") {
                    ExportSaver.save(CycloneDX.json(sbom.components, date: Date()), name: "nobet-sbom.cdx.json")
                }
                .glassButton().controlSize(.small).disabled(sbom.components.isEmpty)
            }
            Toggle("Bilinen açıkları sorgula (OSV.dev)", isOn: Binding(get: { sbom.lookupEnabled },
                                                                     set: { sbom.setLookup($0, roots: roots) }))
                .toggleStyle(RightSwitchStyle()).controlSize(.small)
            Text("Açık sorgusu açıkken yalnızca ekosistem, paket adı ve sürüm internete gider. Dosya yolu ve içerik gitmez. Swift paketleri sorgulanmaz.")
                .font(.nobetFootnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if sbom.lookupFailed {
                Text("Açık sorgusu yanıt vermedi. Önceki sonuç gösteriliyor.").font(.caption).foregroundStyle(.orange)
            }
            if !sbom.scanned {
                Text("Henüz taranmadı. Tara düğmesine basın.").font(.callout).foregroundStyle(.secondary)
            } else if sbom.components.isEmpty {
                EmptyState(symbol: "shippingbox", title: "Kilit dosyası bulunamadı",
                           message: "package-lock.json, composer.lock, Package.resolved veya requirements.txt aranır.")
            } else {
                filterRow
                ForEach(shown.prefix(state.expanded ? shown.count : 8), id: \.self) { item in
                    HStack {
                        if let ids = sbom.vulnerabilities[item] {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                .accessibilityLabel("Açığı var")
                            Text(verbatim: "\(item.name) \(item.version)")
                            Spacer()
                            Text(verbatim: ids.prefix(3).joined(separator: ", ") + (ids.count > 3 ? " +\(ids.count - 3)" : ""))
                                .font(.nobetFootnote).foregroundStyle(.secondary).lineLimit(1)
                        } else {
                            Text(verbatim: "\(item.name) \(item.version)")
                            Spacer()
                        }
                        Text(item.ecosystem.title).font(.nobetFootnote).foregroundStyle(.secondary)
                    }
                    .font(.callout)
                }
                if shown.count > 8 {
                    Button(state.expanded ? "Daha az göster" : "Tümünü göster (\(shown.count))") { state.expanded.toggle() }
                        .buttonStyle(.link).font(.caption)
                }
                if shown.isEmpty { Text("Süzgece uyan bileşen yok.").font(.callout).foregroundStyle(.secondary) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
        .onAppear { if !sbom.scanned && !sbom.scanning { sbom.rescan(roots: roots) } }
    }

    private var filterRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Ara", text: Binding(get: { state.filter.text }, set: { state.filter.text = $0 }))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                Menu("Ekosistem") {
                    ForEach(SBOMComponent.Ecosystem.allCases, id: \.self) { kind in
                        Toggle(kind.title, isOn: Binding(get: { state.filter.ecosystems.contains(kind) }, set: { on in
                            var next = state.filter
                            if on { next.ecosystems.insert(kind) } else { next.ecosystems.remove(kind) }
                            state.filter = next
                        }))
                    }
                }
                .menuStyle(.borderlessButton).fixedSize()
                Toggle("Yalnızca açığı olanlar", isOn: Binding(get: { state.filter.onlyVulnerable }, set: { state.filter.onlyVulnerable = $0 }))
                    .toggleStyle(RightSwitchStyle()).controlSize(.small).fixedSize()
            }
            .font(.caption)
            if state.filter.isActive {
                HStack(spacing: 6) {
                    ForEach(state.filter.chips) { chip in
                        Button { state.filter = state.filter.removing(chip.dimension) } label: {
                            HStack(spacing: 4) { Text(chip.title); Image(systemName: "xmark") }
                                .font(.nobetFootnote).padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Capsule().fill(Color.secondary.opacity(0.15)))
                        }
                        .buttonStyle(.plain)
                    }
                    Button("Temizle") { state.filter = state.filter.cleared() }.buttonStyle(.link).font(.caption)
                }
            }
        }
    }
}
