import SwiftUI

/// Menü çubuğundan açılan panel. Modül durumu, açık sorunlar, sunucu ve site çizgileri.
struct PanelView: View {
    @ObservedObject var model: NobetModel
    @ObservedObject private var center = AlertCenter.shared
    @ObservedObject private var servers = ServerModel.shared
    @ObservedObject private var remote = RemoteModel.shared
    @Environment(\.openWindow) private var openWindow
    @AppStorage(PanelLayout.key) private var layoutName = PanelLayout.standard.rawValue

    /// Panelin uzamaması için üst sınırlar.
    private let issueLimit = 4
    private let serverLimit = 3
    private let siteLimit = 4

    private static let modules: [(key: String, title: String, symbol: String)] = [
        ("dev", "Geliştirme", "hammer"),
        ("servers", "Web siteleri", "globe"),
        ("remote", "SSH sunucuları", "server.rack"),
        ("secrets", "Sırlar", "key.viewfinder"),
        ("sbom", "Bağımlılıklar", "shippingbox"),
    ]

    private var layout: PanelLayout { PanelLayout(stored: layoutName) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header
            statusRows
            issuesCard
            if layout.showsServers, !remote.profiles.isEmpty { serversCard }
            if layout.showsSites, !servers.sites.isEmpty { sitesCard }
            actions
        }
        .padding(12)
        .frame(width: 360)
        .containerBackground(for: .window) { AmbientBackground() }
    }

    // MARK: Başlık

    /// Durum başlığı, temiz modül halkası ve son 24 saatin sorun şeridi tek cam kartta.
    private var header: some View {
        let worst = center.worstVisibleSeverity
        let open = center.visibleActive.count
        let tint: Color = worst == .high ? .red : worst == nil ? .green : .orange
        let clean = Self.modules.filter { center.visibleCount(module: $0.key) == 0 }.count
        let started = AlertTimeline.hourlyStarts(center.history, now: Date())
        let total = started.reduce(0, +)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.10), lineWidth: 4)
                    Circle()
                        .trim(from: 0, to: Double(clean) / Double(Self.modules.count))
                        .stroke(tint.gradient, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .nobetAnimation(.easeOut(duration: 0.5), value: clean)
                    Image(systemName: worst?.symbol ?? "checkmark.seal.fill")
                        .font(.title3)
                        .foregroundStyle(tint)
                }
                .frame(width: 46, height: 46)
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(StatusLabel.hero(openCount: open, worst: worst)).font(.callout.weight(.semibold)).lineLimit(2)
                    Text("\(clean)/\(Self.modules.count) modül temiz").font(.nobetFootnote).foregroundStyle(.secondary).nobetNumeric(clean)
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            HStack {
                Text("Son 24 saat").font(.nobetFootnote).foregroundStyle(.secondary)
                Spacer()
                Text(total == 0 ? "Sorun başlamadı" : "\(total) sorun başladı").font(.nobetFootnote.monospacedDigit()).foregroundStyle(.secondary)
            }
            AlertStrip(buckets: started, height: 20)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16, tint: worst == nil ? nil : tint)
    }

    // MARK: Modül çipleri

    private var statusRows: some View {
        GlassGroup(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(Self.modules, id: \.key) { module in
                    let count = center.visibleCount(module: module.key)
                    let tint: Color = count == 0 ? .secondary : .orange
                    VStack(spacing: 3) {
                        Image(systemName: module.symbol).font(.callout).frame(height: 18)
                        Text(count == 0 ? "Tamam" : "\(count)").font(.nobetFootnote.weight(.medium).monospacedDigit()).nobetNumeric(count)
                    }
                    .foregroundStyle(tint)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .glassCard(cornerRadius: 12, tint: count == 0 ? nil : .orange)
                    .help("\(module.title): \(count == 0 ? "sorun yok" : "\(count) sorun")")
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(module.title), \(count == 0 ? "sorun yok" : "\(count) sorun")")
                }
            }
        }
    }

    // MARK: Sorunlar

    @ViewBuilder
    private var issuesCard: some View {
        let issues = center.visibleActive.sorted { $0.severity > $1.severity }
        if !issues.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                CardHeader(symbol: "exclamationmark.bubble", title: "Açık sorunlar", trailing: "\(issues.count)")
                ForEach(issues.prefix(issueLimit)) { issue in
                    HStack(spacing: 8) {
                        Image(systemName: issue.severity.symbol)
                            .font(.caption)
                            .foregroundStyle(issue.severity == .high ? Color.red : issue.severity == .medium ? Color.orange : Color.secondary)
                            .frame(width: 16)
                            .accessibilityLabel(issue.severity.label)
                        Text(issue.title).lineLimit(1)
                        Spacer(minLength: 4)
                        Text(issue.subject).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle).frame(maxWidth: 110, alignment: .trailing)
                    }
                    .font(.caption)
                }
                if issues.count > issueLimit {
                    Text("+\(issues.count - issueLimit) sorun daha").font(.nobetFootnote).foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(cornerRadius: 16)
        }
    }

    // MARK: Sunucular

    private var serversCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            serversHeader
            ForEach(remote.profiles.prefix(serverLimit)) { profile in serverRow(profile) }
            if remote.profiles.count > serverLimit {
                Text("+\(remote.profiles.count - serverLimit) sunucu daha").font(.nobetFootnote).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16)
    }

    /// Başlık, canlı "Son okuma" süresi ve sunucu sayısı. Süre her saniye kendiliğinden güncellenir.
    private var serversHeader: some View {
        let last = remote.history.values.compactMap { $0.last?.date }.max()
        return HStack(spacing: 6) {
            Image(systemName: "server.rack").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text("SSH sunucuları").font(.subheadline.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 4)
            if let last {
                (Text("Son okuma: ") + Text(last, style: .relative) + Text(" önce"))
                    .font(.nobetFootnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .environment(\.locale, Locale(identifier: "tr_TR"))
            }
            Text("\(remote.profiles.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func serverRow(_ profile: SSHProfile) -> some View {
        let metrics = remote.metrics(for: profile)
        let thresholds = profile.thresholds ?? .standard
        let failing = !remote.issues(for: profile).isEmpty
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(failing ? Color.orange : Color.green).frame(width: 7, height: 7).accessibilityHidden(true)
                Text(profile.name).font(.caption.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                if metrics == nil { Text("okuma bekleniyor").font(.nobetFootnote).foregroundStyle(.secondary) }
            }
            let samples = remote.history[profile.id] ?? []
            HStack(spacing: 10) {
                gauge("Disk", metrics?.mainDiskPercent, trend: MetricHistory.values(samples) { $0.diskPercent.map(Double.init) },
                      level: { PanelGauge.disk(percent: $0, thresholds: thresholds) })
                gauge("Bellek", metrics?.memory?.usedPercent, trend: MetricHistory.values(samples) { $0.memoryPercent.map(Double.init) },
                      level: { PanelGauge.memory(percent: $0, thresholds: thresholds) })
                gauge("CPU", metrics?.cpuPercent, trend: [], level: { PanelGauge.cpu(percent: $0) })
            }
        }
    }

    /// Başlık, eğilim grafiği, yüzde ve eşik rengiyle çubuk. Değer yoksa tire ve boş çubuk.
    /// `trend` iki değerden azsa grafik çizilmez.
    private func gauge(_ title: String, _ percent: Int?, trend: [Double], level: (Int) -> GaugeLevel) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 3) {
                Text(title).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                AreaSpark(values: trend, range: 0...100, color: percent.map { color(level($0)) } ?? .secondary, width: 26, height: 11)
                Text(percent.map { "%\($0)" } ?? "-").fontWeight(.semibold).nobetNumeric(percent)
            }
            .font(.nobetFootnote.monospacedDigit())
            UsageBar(percent: Double(percent ?? 0), height: 5, color: percent.map { color(level($0)) } ?? Color.secondary.opacity(0.3))
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(percent.map { "yüzde \($0)" } ?? "okunamadı")
    }

    private func color(_ level: GaugeLevel) -> Color {
        switch level {
        case .ok: return .green
        case .warning: return .orange
        case .critical: return .red
        }
    }

    // MARK: Web siteleri

    private var sitesCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            CardHeader(symbol: "globe", title: "Web siteleri", trailing: "\(servers.sites.count)")
            ForEach(servers.sites.prefix(siteLimit)) { site in
                let samples = servers.history[site.id] ?? []
                HStack(spacing: 8) {
                    Circle().fill(statusColor(SiteHistory.uptimePercent(samples))).frame(width: 7, height: 7).accessibilityHidden(true)
                    Text(site.name).font(.caption).lineLimit(1).frame(maxWidth: 110, alignment: .leading)
                    AreaSpark(values: SiteHistory.latencies(samples), range: nil, color: .accentColor, width: 80, height: 16)
                    Spacer(minLength: 4)
                    Text(SiteStatusText.uptime(samples)).font(.nobetFootnote.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if servers.sites.count > siteLimit {
                Text("+\(servers.sites.count - siteLimit) site daha").font(.nobetFootnote).foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(cornerRadius: 16)
    }

    private func statusColor(_ percent: Double?) -> Color {
        switch UptimeStrip.level(percent) {
        case .unknown: return Color.secondary.opacity(0.4)
        case .good: return .green
        case .degraded: return .orange
        case .down: return .red
        }
    }

    // MARK: Eylemler

    private var actions: some View {
        HStack(spacing: 8) {
            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Label("Ana pencere", systemImage: "macwindow")
            }
            .glassProminentButton()
            Button {
                servers.refresh()
                remote.refresh()
            } label: { Image(systemName: "arrow.clockwise") }
                .glassButton()
                .help("Sunucuları şimdi oku")
                .accessibilityLabel("Sunucuları şimdi oku")
            Spacer()
            Button { NSApplication.shared.terminate(nil) } label: { Image(systemName: "power") }
                .glassButton()
                .help("Nöbet'ten çık")
                .accessibilityLabel("Çık")
        }
        .controlSize(.regular)
    }
}

/// Panel ve kart metinleri.
enum SiteStatusText {
    /// `%99,8 ayakta` gibi. Örnek yoksa tire.
    static func uptime(_ samples: [SiteSample]) -> String {
        guard let percent = SiteHistory.uptimePercent(samples) else { return "-" }
        let text = percent == 100 ? "100" : String(format: "%.1f", percent).replacingOccurrences(of: ".", with: ",")
        return "%\(text) ayakta"
    }
}
