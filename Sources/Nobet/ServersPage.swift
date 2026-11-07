import Charts
import SwiftUI

/// Ekleme formunun ve silme onayının durumu. `@State` bu araç zincirinde derlenmez.
private final class ServersFormState: ObservableObject {
    @Published var name = ""
    @Published var host = ""
    @Published var port = "443"
    @Published var pendingRemoval: ServerSite?
    /// Doluysa form yeni site yerine bu siteyi düzenler.
    @Published var editingId: String?
    /// Ekleme formu yalnızca istenince açılır.
    @Published var shown = false

    func reset() {
        shown = false
        editingId = nil
        name = ""
        host = ""
        port = "443"
    }

    func load(_ site: ServerSite) {
        shown = true
        editingId = site.id
        name = site.name
        host = site.host
        port = String(site.port)
    }
}

/// Sunucu izleme: alan adı, HTTP durumu, yanıt süresi ve SSL bitiş tarihi. Yalnızca dışarıdan, tek HEAD isteğiyle bakar.
struct ServersPage: View {
    @ObservedObject var model: ServerModel
    @StateObject private var form = ServersFormState()

    var body: some View {
        PageContainer {
                header
                if form.shown { addCard }
                if model.sites.isEmpty && !form.shown {
                    EmptyCard(symbol: "globe", title: "Henüz site yok",
                              message: "Alan adı ekleyin. Nöbet HTTP durumunu, yanıt süresini ve SSL bitişini izler.",
                              actionTitle: "Site ekle") { form.shown = true }
                }
                certCard
                ForEach(model.sites) { site in
                    SiteCard(site: site, model: model, onEdit: { form.load(site) }, onRemove: { form.pendingRemoval = site })
                }
                RemoteServersView(model: RemoteModel.shared)
        }
        .onAppear { if !model.checked && !model.sites.isEmpty { model.refresh() } }
        .alert(
            "\(form.pendingRemoval?.name ?? "") izlemeden çıkarılsın mı?",
            isPresented: Binding(get: { form.pendingRemoval != nil }, set: { if !$0 { form.pendingRemoval = nil } }),
            presenting: form.pendingRemoval
        ) { site in
            Button("İptal", role: .cancel) { form.pendingRemoval = nil }
            Button("Çıkar", role: .destructive) {
                form.pendingRemoval = nil
                model.removeSite(site)
            }
        } message: { _ in
            Text("Yalnızca izleme listesinden silinir. Sunucuya dokunulmaz.")
        }
    }

    private var header: some View {
        let issueCount = model.sites.reduce(0) { $0 + SiteHealth.alertCount(model.issues(for: $1)) }
        let summary = "\(model.sites.count) site · \(issueCount) uyarı"
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                CardHeader(symbol: "server.rack", title: "Sunucular", trailing: model.sites.isEmpty ? "" : summary)
                InfoButton(text: "Nöbet her siteye 5 dakikada bir tek HTTPS HEAD isteği atar. Parola veya anahtar kullanmaz. Sertifikası 14 günden az kalan site uyarı verir.")
                if model.checking { ProgressView().controlSize(.small) }
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .glassButton()
                    .controlSize(.small)
                    .disabled(model.checking || model.sites.isEmpty)
                    .help("Şimdi kontrol et")
                    .accessibilityLabel("Şimdi kontrol et")
                AddToggleButton(isOpen: form.shown, title: "Site ekle") {
                    if form.shown { form.reset(); model.clearError() } else { form.shown = true }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    @ViewBuilder
    private var certCard: some View {
        let entries = CertCalendar.entries(sites: model.sites, results: model.results, now: Date())
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                CardHeader(symbol: "calendar.badge.clock", title: "Sertifika takvimi", trailing: "\(entries.count) site")
                ForEach(entries, id: \.site.id) { entry in
                    HStack {
                        Image(systemName: entry.level == .ok ? "checkmark.shield" : "exclamationmark.shield")
                            .foregroundStyle(entry.level == .critical ? Color.red : entry.level == .warning ? Color.orange : Color.green)
                        Text(entry.site.name)
                        Spacer()
                        Text(entry.expiry.formatted(Date.FormatStyle(date: .abbreviated).locale(Locale(identifier: "tr_TR"))))
                            .foregroundStyle(.secondary)
                        Text(entry.daysLeft < 0 ? "süresi doldu" : "\(entry.daysLeft) gün").monospacedDigit().frame(width: 90, alignment: .trailing)
                    }
                    .font(.callout)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard()
        }
    }

    private var addCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(symbol: form.editingId == nil ? "plus.circle" : "pencil", title: form.editingId == nil ? "Site ekle" : "Siteyi düzenle")
            HStack(spacing: 8) {
                TextField("Ad (isteğe bağlı)", text: $form.name).frame(maxWidth: 160)
                TextField("example.com", text: $form.host)
                TextField("Port", text: $form.port).frame(width: 64)
                if form.editingId != nil {
                    Button("İptal") {
                        form.reset()
                        model.clearError()
                    }
                    .glassButton()
                }
                Button(form.editingId == nil ? "Ekle" : "Kaydet") {
                    if let id = form.editingId {
                        if model.updateSite(id: id, name: form.name, host: form.host, port: Int(form.port) ?? 0) { form.reset() }
                    } else {
                        model.addSite(name: form.name, host: form.host, port: Int(form.port) ?? 0)
                        if model.errorText == nil { form.reset() }
                    }
                }
                .glassButton()
                .disabled(form.host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            .font(.caption)
            if let error = model.errorText {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

private struct SiteCard: View {
    let site: ServerSite
    @ObservedObject var model: ServerModel
    let onEdit: () -> Void
    let onRemove: () -> Void

    var body: some View {
        let result = model.results[site.id]
        let issues = model.issues(for: site)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(dotColor(result, issues)).frame(width: 8, height: 8).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 0) {
                    Text(site.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text(verbatim: site.port == 443 ? site.host : "\(site.host):\(site.port)")
                        .font(.nobetFootnote)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                Button(action: onEdit) { Image(systemName: "pencil") }
                    .glassButton()
                    .controlSize(.small)
                    .help("Düzenle")
                    .accessibilityLabel("\(site.name) sitesini düzenle")
                Button(action: onRemove) { Image(systemName: "trash") }
                    .glassButton()
                    .controlSize(.small)
                    .help("İzlemeden çıkar")
                    .accessibilityLabel("\(site.name) sitesini çıkar")
            }
            if let result {
                Text(verbatim: summary(result))
                    .font(.nobetFootnote.monospacedDigit())
                    .foregroundStyle(.secondary)
                let samples = model.history[site.id] ?? []
                if samples.count >= 2 {
                    HStack(spacing: 8) {
                        Text("yanıt süresi").font(.nobetFootnote).foregroundStyle(.secondary)
                        AreaSpark(values: SiteHistory.latencies(samples), range: nil, color: .accentColor, width: 90, height: 22)
                        Text(verbatim: "\(SiteStatusText.uptime(samples)) · son \(samples.count) kontrol")
                            .font(.nobetFootnote.monospacedDigit()).foregroundStyle(.secondary)
                        if let average = SiteHistory.averageLatencyMs(samples) {
                            Text(verbatim: "ort. \(average) ms").font(.nobetFootnote.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    UptimeStripView(samples: samples)
                    BigSiteChart(samples: samples)
                }
            } else {
                Text("Kontrol bekleniyor.").font(.nobetFootnote).foregroundStyle(.secondary)
            }
            ForEach(issues.indices, id: \.self) { index in
                let issue = issues[index]
                Text(verbatim: "\(issue.kind.title). \(issue.detail)")
                    .font(.caption)
                    .foregroundStyle(color(issue.severity))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func summary(_ result: ProbeResult) -> String {
        var parts: [String] = []
        if let status = result.httpStatus { parts.append("HTTP \(status)") }
        if let latency = result.latencyMs { parts.append("\(latency) ms") }
        if let expiry = result.certExpiry {
            let days = Int(expiry.timeIntervalSinceNow / 86_400)
            parts.append(days >= 0 ? "SSL \(days) gün" : "SSL süresi doldu")
        }
        return parts.isEmpty ? "Yanıt yok" : parts.joined(separator: " · ")
    }

    private func dotColor(_ result: ProbeResult?, _ issues: [ServerIssue]) -> Color {
        guard result != nil else { return Color.secondary.opacity(0.5) }
        guard let worst = issues.map(\.severity).max() else { return .green }
        return color(worst)
    }

    private func color(_ severity: Severity) -> Color {
        switch severity {
        case .high: return .red
        case .medium: return .orange
        case .info: return .secondary
        }
    }
}

/// `@State` bu araç zincirinde derlenmez. Açık/kapalı durumu küçük bir nesnede durur.
private final class SiteChartFlag: ObservableObject {
    @Published var expanded = false
}

/// Yanıt süresinin 24 saatlik çizgisi. Başarısız kontroller kırmızı nokta olur.
private struct BigSiteChart: View {
    let samples: [SiteSample]
    @StateObject private var flag = SiteChartFlag()

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(flag.expanded ? "Grafiği gizle" : "Grafiği göster") { flag.expanded.toggle() }
                .buttonStyle(.link).font(.caption)
            if flag.expanded { chart }
        }
    }

    @ViewBuilder
    private var chart: some View {
        let points = SiteHistory.latencyPoints(samples)
        let downs = SiteHistory.downtimeDates(samples)
        if points.isEmpty {
            Text("Yanıt süresi verisi yok.").font(.caption).foregroundStyle(.secondary)
        } else {
            Chart {
                ForEach(points, id: \.date) { point in
                    LineMark(x: .value("Saat", point.date), y: .value("ms", point.value))
                        .interpolationMethod(.monotone)
                }
                ForEach(downs, id: \.self) { date in
                    PointMark(x: .value("Saat", date), y: .value("ms", 0)).foregroundStyle(.red)
                }
            }
            .chartYScale(domain: SiteHistory.latencyDomain(points.map(\.value)))
            .chartYAxis {
                AxisMarks { value in
                    AxisGridLine()
                    AxisValueLabel { if let number = value.as(Double.self) { Text("\(Int(number)) ms") } }
                }
            }
            .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute()) } }
            .frame(height: 140)
            Text(verbatim: downs.isEmpty ? "Kesinti yok." : "Kırmızı nokta: \(downs.count) başarısız kontrol")
                .font(.nobetFootnote).foregroundStyle(.secondary)
        }
    }
}

/// 24 saatlik uptime şeridi. Her kutu bir saat. Renk yanında erişilebilirlik metni de taşır.
private struct UptimeStripView: View {
    let samples: [SiteSample]

    var body: some View {
        let cells = UptimeStrip.cells(samples, now: samples.last?.date ?? Date())
        HStack(spacing: 2) {
            Text("24 sa").font(.nobetFootnote).foregroundStyle(.secondary)
            ForEach(cells.indices, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2)
                    .fill(color(UptimeStrip.level(cells[index])))
                    .frame(width: 8, height: 14)
                    .help(cells[index].map { "\(24 - index) saat önce: %\(Int($0.rounded())) ayakta" } ?? "\(24 - index) saat önce: veri yok")
            }
            Text("şimdi").font(.nobetFootnote).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Son 24 saatin saatlik uptime şeridi")
    }

    private func color(_ level: UptimeStrip.Level) -> Color {
        switch level {
        case .unknown: return Color.secondary.opacity(0.2)
        case .good: return .green
        case .degraded: return .orange
        case .down: return .red
        }
    }
}
