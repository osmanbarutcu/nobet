import Charts
import SwiftUI

/// Ekleme formunun ve silme onayının durumu. `@State` bu araç zincirinde derlenmez.
private final class RemoteFormState: ObservableObject {
    @Published var name = ""
    @Published var host = ""
    @Published var port = "22"
    @Published var user = "root"
    @Published var auth: SSHAuth = .password
    @Published var services = ""
    @Published var backupPath = ""
    @Published var keyPath = ""
    @Published var platform = RemotePlatform.linux
    @Published var password = ""
    @Published var pendingRemoval: SSHProfile?
    /// Doluysa form yeni sunucu yerine bu profili düzenler.
    @Published var editingId: String?
    /// Ekleme formu yalnızca istenince açılır.
    @Published var shown = false
    @Published var diskMedium = ""
    @Published var diskHigh = ""
    @Published var memoryLow = ""
    @Published var loadPerCore = ""

    func reset() {
        shown = false
        editingId = nil
        name = ""
        host = ""
        port = "22"
        user = "root"
        auth = .password
        services = ""
        backupPath = ""
        keyPath = ""
        platform = .linux
        password = ""
        diskMedium = ""
        diskHigh = ""
        memoryLow = ""
        loadPerCore = ""
    }

    func load(_ profile: SSHProfile) {
        shown = true
        editingId = profile.id
        name = profile.name
        host = profile.host
        port = String(profile.port)
        user = profile.user
        auth = profile.auth
        services = profile.services.joined(separator: ", ")
        backupPath = profile.backupPath ?? ""
        keyPath = profile.keyPath ?? ""
        platform = profile.platform ?? .linux
        password = ""
        let limits = profile.thresholds ?? .standard
        diskMedium = String(limits.diskMedium)
        diskHigh = String(limits.diskHigh)
        memoryLow = String(limits.memoryLowPercent)
        loadPerCore = String(limits.loadPerCore)
    }

    /// Dört alan da standart değerse `nil` verir, profil standart eşikleri kullanır. Okunamayan sayı geçersiz eşik üretir.
    var thresholds: ServerThresholds? {
        let value = ServerThresholds(diskMedium: Int(diskMedium) ?? 0, diskHigh: Int(diskHigh) ?? 0,
                                     memoryLowPercent: Int(memoryLow) ?? 0, loadPerCore: Double(loadPerCore.replacingOccurrences(of: ",", with: ".")) ?? 0)
        return editingId == nil || value == .standard ? nil : value
    }
}

/// SSH ile uzak sunucu durumu: disk, bellek, yük, açık kalma süresi ve seçilen servisler. Yalnızca salt okunur komutlar çalışır.
struct RemoteServersView: View {
    @ObservedObject var model: RemoteModel
    @StateObject private var form = RemoteFormState()
    @StateObject private var arrangement = ArrangementModel()
    @AppStorage(ServerViewMode.key) private var viewMode = ServerViewMode.cards.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            if form.shown { addCard }
            if model.profiles.count > 1 {
                Picker("Görünüm", selection: $viewMode) {
                    ForEach(ServerViewMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }
                .pickerStyle(.segmented).frame(maxWidth: 200)
            }
            if ServerViewMode(stored: viewMode) == .table, model.profiles.count > 1 {
                ComparisonTable(model: model)
            } else {
            ForEach(arrangement.value.sections(model.profiles), id: \.title) { section in
                if !section.title.isEmpty {
                    Text(section.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.horizontal, 4)
                }
                ForEach(section.profiles) { profile in
                    ProfileCard(profile: profile, model: model, arrangement: arrangement,
                                onEdit: { form.load(profile) }, onRemove: { form.pendingRemoval = profile })
                }
            }
            }
        }
        .onAppear { if !model.checked && !model.profiles.isEmpty { model.refresh() } }
        .alert(
            "\(form.pendingRemoval?.name ?? "") izlemeden çıkarılsın mı?",
            isPresented: Binding(get: { form.pendingRemoval != nil }, set: { if !$0 { form.pendingRemoval = nil } }),
            presenting: form.pendingRemoval
        ) { profile in
            Button("İptal", role: .cancel) { form.pendingRemoval = nil }
            Button("Çıkar", role: .destructive) {
                form.pendingRemoval = nil
                model.removeProfile(profile)
            }
        } message: { _ in
            Text("Kayıtlı parola Anahtar Zinciri'nden de silinir. Sunucuya dokunulmaz.")
        }
    }

    private var header: some View {
        let issueCount = model.profiles.reduce(0) { $0 + RemoteHealth.alertCount(model.issues(for: $1)) }
        let summary = "\(model.profiles.count) sunucu · \(issueCount) uyarı"
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                CardHeader(symbol: "terminal", title: "SSH ile sunucu durumu", trailing: model.profiles.isEmpty ? "" : summary)
                InfoButton(text: "Nöbet 5 dakikada bir sabit, salt okunur komutlar çalıştırır: df, free, /proc, systemctl, sshd -T, ss, lastb, docker ps, pg_isready, mysqladmin ping, find. Hiçbir şeyi değiştirmez. Önerilen komutları yalnızca siz çalıştırırsınız. Parola yalnızca Anahtar Zinciri'nde durur. Linux ve systemd gerekir.")
                if model.checking { ProgressView().controlSize(.small) }
                Button { model.refresh() } label: { Image(systemName: "arrow.clockwise") }
                    .glassButton()
                    .controlSize(.small)
                    .disabled(model.checking || model.profiles.isEmpty)
                    .help("Şimdi oku")
                    .accessibilityLabel("SSH sunucularını şimdi oku")
                AddToggleButton(isOpen: form.shown, title: "SSH sunucusu ekle") {
                    if form.shown { form.reset(); model.clearError() } else { form.shown = true }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var addCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(symbol: form.editingId == nil ? "plus.circle" : "pencil", title: form.editingId == nil ? "SSH sunucusu ekle" : "SSH sunucusunu düzenle")
            HStack(spacing: 8) {
                TextField("Ad (isteğe bağlı)", text: $form.name).frame(maxWidth: 140)
                TextField("sunucu.example.com", text: $form.host)
                TextField("Port", text: $form.port).frame(width: 56)
                TextField("Kullanıcı", text: $form.user).frame(width: 100)
            }
            HStack(spacing: 8) {
                Picker("Sistem", selection: $form.platform) {
                    ForEach(RemotePlatform.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
                .help("Windows için sunucuda OpenSSH ve PowerShell gerekir. Gerçek Windows sunucuda doğrulanmadı.")
                Picker("Kimlik", selection: $form.auth) {
                    Text("Parola").tag(SSHAuth.password)
                    Text("Anahtar (ssh-agent)").tag(SSHAuth.key)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                if form.auth == .password {
                    SecureField(form.editingId == nil ? "Parola" : "Parola (boşsa değişmez)", text: $form.password)
                } else {
                    TextField("Anahtar dosyası (isteğe bağlı): ~/.ssh/id_ed25519_uretim", text: $form.keyPath)
                        .help("Boşsa ssh-agent ve varsayılan dosya adları denenir. Yalnızca yol saklanır, anahtar içeriği saklanmaz.")
                }
            }
            HStack(spacing: 8) {
                TextField("İzlenecek servisler, virgülle: nginx, mariadb, postgresql", text: $form.services)
                TextField("Yedek klasörü (isteğe bağlı): /var/backups", text: $form.backupPath)
                if form.editingId != nil {
                    Button("İptal") {
                        form.reset()
                        model.clearError()
                    }
                    .glassButton()
                }
                Button(form.editingId == nil ? "Ekle" : "Kaydet") {
                    let services = form.services.split(separator: ",").map { String($0) }
                    if let id = form.editingId {
                        if model.updateProfile(id: id, name: form.name, host: form.host, port: Int(form.port) ?? 0, user: form.user,
                                               auth: form.auth, services: services, thresholds: form.thresholds, backupPath: form.backupPath,
                                               platform: form.platform, keyPath: form.keyPath, password: form.password) {
                            form.reset()
                        }
                    } else {
                        model.addProfile(name: form.name, host: form.host, port: Int(form.port) ?? 0, user: form.user, auth: form.auth,
                                         services: services, backupPath: form.backupPath, platform: form.platform, keyPath: form.keyPath, password: form.password)
                        if model.errorText == nil { form.reset() }
                    }
                }
                .glassButton()
                .disabled(form.host.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .textFieldStyle(.roundedBorder)
            if form.editingId != nil {
                HStack(spacing: 8) {
                    Text("Eşikler").foregroundStyle(.secondary)
                    TextField("Disk orta %", text: $form.diskMedium).frame(width: 90)
                    TextField("Disk yüksek %", text: $form.diskHigh).frame(width: 100)
                    TextField("Bellek az %", text: $form.memoryLow).frame(width: 90)
                    TextField("Yük/çekirdek", text: $form.loadPerCore).frame(width: 90)
                }
                .textFieldStyle(.roundedBorder)
            }
            if let error = model.errorText {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .textFieldStyle(.roundedBorder)
        .font(.caption)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}

private struct ProfileCard: View {
    let profile: SSHProfile
    @ObservedObject var model: RemoteModel
    @ObservedObject var arrangement: ArrangementModel
    @ObservedObject private var center = AlertCenter.shared
    @StateObject private var groupEdit = GroupEditState()
    @StateObject private var packageView = PackageViewState()
    @StateObject private var timelineState = TimelineState()
    let onEdit: () -> Void
    let onRemove: () -> Void

    private static let packageRowLimit = 200

    private var packagePopover: some View {
        let items = model.inventory[profile.id] ?? []
        let shown = PackageInventory.filter(items, text: packageView.text)
        return VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: "\(profile.name): kurulu paketler").font(.callout.weight(.semibold))
            TextField("Paket ara", text: $packageView.text).textFieldStyle(.roundedBorder)
            if model.loadingInventory.contains(profile.id) {
                Text("Okunuyor.").font(.caption).foregroundStyle(.secondary)
            } else if let error = model.inventoryErrors[profile.id] {
                Text(verbatim: error).font(.caption).foregroundStyle(.orange)
            } else {
                Text(verbatim: "\(shown.count) paket" + (shown.count > Self.packageRowLimit ? ", ilk \(Self.packageRowLimit) gösteriliyor" : ""))
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(shown.prefix(Self.packageRowLimit)) { item in
                            Text(verbatim: "\(item.name)  \(item.version)").font(.caption.monospaced()).lineLimit(1)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 220)
            }
            HStack {
                Spacer()
                Button("Yenile") { Task { await model.loadInventory(profile) } }
                    .disabled(model.loadingInventory.contains(profile.id))
            }
        }
        .padding(12)
        .frame(width: 360)
    }

    /// Bu sunucunun son 5 olayı. Olay yoksa görünmez.
    @ViewBuilder private var timeline: some View {
        let events = ServerTimeline.events(center.history, module: "remote", subject: profile.name)
        if !events.isEmpty {
            DisclosureGroup(isExpanded: $timelineState.expanded) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(events) { event in
                        Text(verbatim: "\(event.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "tr_TR")))) · \(event.kind == .started ? "başladı" : "çözüldü") · \(event.issue.title)")
                            .font(.nobetFootnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                .padding(.top, 2)
            } label: {
                Text(verbatim: "Son olaylar (\(events.count))").font(.nobetFootnote.weight(.medium))
            }
        }
    }

    var body: some View {
        let metrics = model.metrics(for: profile)
        let issues = model.issues(for: profile)
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 0) {
                    Text(profile.name).font(.callout.weight(.medium)).lineLimit(1)
                    Text(verbatim: "\(profile.user)@\(profile.host)\(profile.port == 22 ? "" : ":\(profile.port)")")
                        .font(.nobetFootnote)
                        .foregroundStyle(.secondary)
                }
                statusBadge(issues)
                Spacer(minLength: 6)
                Menu {
                    Button("Yukarı taşı") { arrangement.move(profile.id, by: -1, in: model.profiles) }
                    Button("Aşağı taşı") { arrangement.move(profile.id, by: 1, in: model.profiles) }
                    Button("Grubu ayarla…") {
                        groupEdit.text = arrangement.value.group(for: profile.id) ?? ""
                        groupEdit.shown = true
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("Sıra ve grup")
                    .accessibilityLabel("\(profile.name) sırası ve grubu")
                    .popover(isPresented: $groupEdit.shown) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Grup adı (boş bırakınca gruptan çıkar)").font(.caption).foregroundStyle(.secondary)
                            TextField("Örn. Üretim", text: $groupEdit.text).frame(width: 220)
                            HStack {
                                Spacer()
                                Button("Kaydet") {
                                    arrangement.setGroup(groupEdit.text, for: profile.id)
                                    groupEdit.shown = false
                                }
                                .keyboardShortcut(.defaultAction)
                            }
                        }
                        .padding(12)
                    }
                Button {
                    packageView.shown = true
                    if model.inventory[profile.id] == nil { Task { await model.loadInventory(profile) } }
                } label: { Image(systemName: "shippingbox") }
                    .glassButton()
                    .controlSize(.small)
                    .help("Kurulu paketler (salt okunur)")
                    .accessibilityLabel("\(profile.name) kurulu paketleri")
                    .popover(isPresented: $packageView.shown) { packagePopover }
                Button(action: onEdit) { Image(systemName: "pencil") }
                    .glassButton()
                    .controlSize(.small)
                    .help("Düzenle")
                    .accessibilityLabel("\(profile.name) sunucusunu düzenle")
                Button(action: onRemove) { Image(systemName: "trash") }
                    .glassButton()
                    .controlSize(.small)
                    .help("İzlemeden çıkar")
                    .accessibilityLabel("\(profile.name) sunucusunu çıkar")
            }
            if let metrics {
                HStack(alignment: .top, spacing: 20) {
                    gauges(for: profile, metrics: metrics)
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(facts(metrics), id: \.text) { fact in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Image(systemName: fact.symbol).font(.nobetFootnote).foregroundStyle(.tertiary).frame(width: 14)
                                Text(verbatim: fact.text).font(.nobetFootnote.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .accessibilityElement(children: .combine)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                trends(for: profile)
            } else if model.results[profile.id] == nil {
                Text("Okuma bekleniyor.").font(.nobetFootnote).foregroundStyle(.secondary)
            }
            timeline
            ForEach(issues.indices, id: \.self) { index in
                RemoteIssueRow(issue: issues[index], color: color(issues[index].severity),
                               snoozeKey: RemoteModel.alertKey(profile: profile, issue: issues[index]))
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(tint: issues.isEmpty ? nil : dotColor(issues))
    }

    /// Başlıktaki durum rozeti. Renk tek başına taşımaz: simge ve yazı da var.
    private func statusBadge(_ issues: [RemoteIssue]) -> some View {
        let waiting = model.results[profile.id] == nil
        let tint = dotColor(issues)
        let symbol = waiting ? "clock" : (issues.isEmpty ? "checkmark.circle.fill" : (issues.map(\.severity).max()?.symbol ?? "exclamationmark.triangle.fill"))
        let text = waiting ? "Bekleniyor" : (issues.isEmpty ? "Sağlıklı" : "\(issues.count) uyarı")
        return Label(text, systemImage: symbol)
            .font(.nobetFootnote.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 2)
            .foregroundStyle(tint)
            .background(tint.opacity(0.15), in: Capsule())
            .accessibilityLabel("Durum: \(text)")
    }

    /// Kartın sağındaki olgu satırları. Her satır simge ve metin taşır. Veri yoksa satır eklenmez.
    private func facts(_ metrics: RemoteMetrics) -> [(symbol: String, text: String)] {
        var rows: [(symbol: String, text: String)] = [("desktopcomputer", summary(metrics))]
        if !metrics.services.isEmpty {
            rows.append(("gearshape.2", metrics.services.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.rawValue)" }.joined(separator: " · ")))
        }
        if let containers = metrics.containers, !containers.isEmpty {
            let running = containers.filter { $0.state == "running" }.count
            rows.append(("shippingbox", "konteyner: \(running) çalışıyor, \(containers.count - running) çalışmıyor"))
        }
        if let databases = metrics.databases, !databases.isEmpty {
            rows.append(("cylinder", "veritabanı: " + databases.map { "\($0.engine.title) \($0.up ? "yanıt veriyor" : "yanıt vermiyor")" }.joined(separator: " · ")))
        }
        if let backup = metrics.backup {
            rows.append(("externaldrive", backup.newestEpoch.map { "son yedek: \(max(0, backup.serverEpoch - $0) / 3600) saat önce" } ?? "yedek dosyası yok"))
        }
        if let ms = model.responseMs[profile.id] { rows.append(("timer", "okuma süresi: \(ResponseTimeText.make(ms: ms))")) }
        if let last = model.reboots[profile.id]?.last {
            rows.append(("arrow.clockwise.circle", "son yeniden başlatma: \(last.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "tr_TR"))))"))
        }
        if let errors = metrics.errorLogs { rows.append(("exclamationmark.bubble", "son 1 saatte hata satırı: \(errors)")) }
        if let security = metrics.security { rows.append(("lock.shield", securitySummary(security))) }
        return rows.filter { !$0.text.isEmpty }
    }

    private func summary(_ metrics: RemoteMetrics) -> String {
        var parts: [String] = []
        if let os = metrics.osName { parts.append(os) }
        if let uptime = metrics.uptimeSeconds { parts.append("açık \(uptime / 86_400) gün") }
        if let root = metrics.disks.first(where: { $0.mount == "/" }) ?? metrics.disks.first { parts.append("disk \(root.mount) %\(root.usedPercent)") }
        if let memory = metrics.memory { parts.append("bellek %\(memory.usedPercent)") }
        if let load = metrics.load { parts.append("yük \(String(format: "%.2f", load[0]))" + (metrics.cores.map { "/\($0) çekirdek" } ?? "")) }
        return parts.isEmpty ? "Veri yok" : parts.joined(separator: " · ")
    }

    @ViewBuilder
    private func gauges(for profile: SSHProfile, metrics: RemoteMetrics) -> some View {
        let thresholds = profile.thresholds ?? .standard
        HStack(spacing: 16) {
            if let disk = metrics.mainDiskPercent {
                ThresholdRing(title: "Disk", percent: disk, medium: thresholds.diskMedium, high: thresholds.diskHigh)
            }
            if let memory = metrics.memory {
                ThresholdRing(title: "Bellek", percent: memory.usedPercent,
                          medium: 100 - thresholds.memoryLowPercent * 2, high: 100 - thresholds.memoryLowPercent)
            }
            if let cpu = metrics.cpuPercent {
                ThresholdRing(title: "CPU", percent: cpu, medium: PanelGauge.cpuMedium, high: PanelGauge.cpuHigh)
            }
        }
    }

    /// Son 24 saatin çizgileri. En az iki örnek yoksa görünmez.
    @ViewBuilder
    private func trends(for profile: SSHProfile) -> some View {
        let samples = model.history[profile.id] ?? []
        let disk = MetricHistory.values(samples) { $0.diskPercent.map(Double.init) }
        let memory = MetricHistory.values(samples) { $0.memoryPercent.map(Double.init) }
        let load = MetricHistory.values(samples) { $0.load }
        if samples.count >= 2 {
            HStack(spacing: 14) {
                trend("disk", disk, range: 0...100)
                trend("bellek", memory, range: 0...100)
                trend("yük", load, range: nil)
                Text("son \(samples.count) okuma").font(.nobetFootnote).foregroundStyle(.secondary)
            }
            BigMetricChart(samples: samples, thresholds: profile.thresholds ?? .standard)
        }
    }

    private func trend(_ title: String, _ values: [Double], range: ClosedRange<Double>?) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.nobetFootnote).foregroundStyle(.secondary)
            AreaSpark(values: values, range: range, color: .accentColor, width: 90, height: 22)
        }
    }

    private func securitySummary(_ security: SecurityPosture) -> String {
        var parts: [String] = []
        if !security.publicPorts.isEmpty { parts.append("dışa açık port: " + security.publicPorts.map(String.init).joined(separator: ", ")) }
        if let failed = security.failedLogins { parts.append("başarısız giriş kaydı: \(failed)") }
        return parts.joined(separator: " · ")
    }

    private func dotColor(_ issues: [RemoteIssue]) -> Color {
        guard model.results[profile.id] != nil else { return Color.secondary.opacity(0.5) }
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

/// `@State` bu araç zincirinde derlenmez. Bu yüzden kopyalama bayrağı küçük bir nesnede durur.
private final class IssueCopyFlag: ObservableObject {
    @Published var done = false
}

/// Sorun satırı. Önerilen komut varsa kopyalanır, uygulama komutu çalıştırmaz.
private struct RemoteIssueRow: View {
    let issue: RemoteIssue
    let color: Color
    let snoozeKey: String
    @StateObject private var copy = IssueCopyFlag()
    @ObservedObject private var center = AlertCenter.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text(verbatim: "\(issue.title). \(issue.detail)").font(.caption).foregroundStyle(color)
                Spacer(minLength: 6)
                SnoozeControl(center: center, key: snoozeKey)
            }
            if let command = issue.suggestion {
                HStack(spacing: 8) {
                    Text(verbatim: command).font(.nobetFootnote.monospaced()).textSelection(.enabled).lineLimit(2)
                    Spacer(minLength: 6)
                    Button(copy.done ? "Kopyalandı" : "Komutu kopyala") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copy.done = true
                    }
                    .glassButton()
                    .controlSize(.small)
                }
            }
        }
    }
}

/// Seçili ölçünün 24 saatlik çizgisi. Eksenler ve son değer görünür.
/// `@State` bu araç zincirinde derlenmez. Seçim küçük bir nesnede durur.
private final class ChartChoice: ObservableObject {
    @Published var kind: MetricChartKind = .disk
    @Published var window = ChartWindow.day
}

private struct BigMetricChart: View {
    let samples: [MetricSample]
    let thresholds: ServerThresholds
    @StateObject private var choice = ChartChoice()

    var body: some View {
        chart
    }

    @ViewBuilder
    private var chart: some View {
        let points = choice.kind.points(choice.window.filter(samples, now: samples.last?.date ?? Date()))
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Picker("Ölçü", selection: $choice.kind) {
                    ForEach(MetricChartKind.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 260)
                Picker("Süre", selection: $choice.window) {
                    ForEach(ChartWindow.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 200)
            }
            if points.count < 2 {
                Text("Bu ölçü için yeterli veri yok.").font(.caption).foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(points, id: \.date) { point in
                        LineMark(x: .value("Saat", point.date), y: .value(choice.kind.title, point.value))
                            .interpolationMethod(.monotone)
                        AreaMark(x: .value("Saat", point.date), y: .value(choice.kind.title, point.value))
                            .foregroundStyle(LinearGradient(colors: [Color.accentColor.opacity(0.28), Color.accentColor.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                    }
                    ForEach(Array(choice.kind.thresholdLines(thresholds).enumerated()), id: \.offset) { index, line in
                        RuleMark(y: .value("Eşik", line))
                            .foregroundStyle((index == 0 ? Color.orange : Color.red).opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                    }
                }
                .chartYScale(domain: choice.kind.yDomain(for: points.map(\.value)))
                .chartYAxis {
                    AxisMarks { value in
                        AxisGridLine()
                        AxisValueLabel { if let number = value.as(Double.self) { Text("\(Int(number))\(choice.kind.unit)") } }
                    }
                }
                .chartXAxis { AxisMarks(values: .automatic(desiredCount: 5)) { _ in AxisGridLine(); AxisValueLabel(format: .dateTime.hour().minute()) } }
                .frame(height: 140)
                if let last = points.last {
                    Text(verbatim: "son değer: \(last.value.formatted(.number.precision(.fractionLength(0...2))))\(choice.kind.unit)")
                        .font(.nobetFootnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Son olaylar listesinin açık/kapalı durumu. Varsayılan kapalı.
private final class TimelineState: ObservableObject {
    @Published var expanded = false
}

/// Grup adı penceresinin durumu.
private final class GroupEditState: ObservableObject {
    @Published var shown = false
    @Published var text = ""
}

/// Paket penceresinin durumu.
private final class PackageViewState: ObservableObject {
    @Published var shown = false
    @Published var text = ""
}
