import Charts
import SwiftUI

/// Genel sayfa: modül durumu, açık sorunlar ve son olaylar.
struct GeneralPage: View {
    @ObservedObject var center: AlertCenter
    @ObservedObject var model: NobetModel

    private static let modules: [(key: String, title: String, symbol: String)] = [
        ("dev", "Geliştirme", "hammer"),
        ("servers", "Web siteleri", "globe"),
        ("remote", "SSH sunucuları", "server.rack"),
        ("secrets", "Sırlar", "key.viewfinder"),
        ("net", "Ağ", "network"),
        ("sbom", "Bağımlılıklar", "shippingbox"),
    ]
    static let eventLimit = 20
    @StateObject private var onboarding = Onboarding()
    @StateObject private var chartHover = ChartHover()
    @AppStorage("mainSection") private var storedSection = NobetSection.general.rawValue
    @StateObject private var issueFilter = FilterModel(store: SavedFilters(key: "alerts.savedFilters.issues"))
    @StateObject private var eventFilter = FilterModel(store: SavedFilters(key: "alerts.savedFilters.events"), sort: .date)

    var body: some View {
        PageContainer {
                if onboarding.isVisible { OnboardingCard(onboarding: onboarding) }
                summaryCard
                timelineCard
                activeCard
                historyCard
        }
    }

    /// Durum başlığı ve modül kutuları tek kartta. Kutuya tıklayınca modülün sayfası açılır.
    private var summaryCard: some View {
        let worst = center.worstVisibleSeverity
        let open = center.visibleActive.count
        let tint: Color = worst == .high ? .red : worst == nil ? .green : .orange
        return VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: worst?.symbol ?? "checkmark.seal.fill")
                    .font(.title)
                    .foregroundStyle(tint)
                    .frame(width: 52, height: 52)
                    .background(tint.opacity(0.15), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(StatusLabel.hero(openCount: open, worst: worst)).font(.title3.weight(.semibold))
                    Text(open == 0 ? "Tüm modüller temiz" : "\(Self.modules.filter { center.visibleCount(module: $0.key) > 0 }.count) modülde sorun var")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if open > 0 {
                    SeverityDonut(counts: [Severity.high, .medium, .info].map { level in
                        (severity: level, count: center.visibleActive.filter { $0.severity == level }.count)
                    })
                }
            }
            .nobetAnimation(.easeInOut(duration: 0.3), value: open)
            HStack(spacing: 8) {
                ForEach(Self.modules, id: \.key) { module in moduleTile(module) }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func moduleTile(_ module: (key: String, title: String, symbol: String)) -> some View {
        let count = center.visibleCount(module: module.key)
        let tint: Color = count == 0 ? .secondary : .orange
        return Button { storedSection = ModuleNames.section(module.key).rawValue } label: {
            VStack(spacing: 4) {
                Image(systemName: module.symbol).font(.title3).frame(height: 22)
                Text(module.title).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
                Text(count == 0 ? "Tamam" : "\(count) sorun").font(.nobetFootnote.weight(.semibold).monospacedDigit())
            }
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(tint.opacity(count == 0 ? 0.08 : 0.16), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("\(module.title) sayfasını aç")
        .accessibilityLabel("\(module.title), \(count == 0 ? "sorun yok" : "\(count) sorun"). Sayfayı aç.")
    }

    /// Son 24 saatte saat başına başlayan sorun sayısı. Boş saat çıplak eksen olarak görünür.
    private var timelineCard: some View {
        let now = Date()
        let buckets = AlertTimeline.hourlyStarts(center.history, now: now)
        let total = buckets.reduce(0, +)
        return CollapsibleCard(id: "general.timeline", symbol: "chart.bar", title: "Son 24 saat",
                               trailing: total == 0 ? "Sorun başlamadı" : "\(total) sorun başladı") {
            let top = max(3, buckets.max() ?? 0)
            Text(hoverText(buckets: buckets, now: now))
                .font(.caption).foregroundStyle(.secondary).lineLimit(1).frame(height: 14, alignment: .leading)
            Chart(Array(buckets.enumerated()), id: \.offset) { index, count in
                BarMark(x: .value("Saat", index), yStart: .value("Alt", 0), yEnd: .value("En çok", top), width: .fixed(10))
                    .foregroundStyle(Color.primary.opacity(chartHover.selected == index ? 0.12 : 0.05))
                    .cornerRadius(2)
                BarMark(x: .value("Saat", index), yStart: .value("Alt", 0), yEnd: .value("Sorun", count), width: .fixed(10))
                    .foregroundStyle(chartHover.selected == index ? Color.red : Color.orange)
                    .cornerRadius(2)
            }
            .chartXAxis {
                AxisMarks(values: [0, 6, 12, 18]) { value in
                    AxisValueLabel {
                        if let index = value.as(Int.self) {
                            Text("\(24 - index) sa önce").font(.nobetFootnote)
                        }
                    }
                }
            }
            .chartYAxis { AxisMarks(values: .automatic(desiredCount: 3)) }
            .chartXScale(domain: -1...24)
            .chartYScale(domain: 0...top)
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let location):
                                guard let frame = proxy.plotFrame else { return }
                                let x = location.x - geometry[frame].origin.x
                                let index = proxy.value(atX: x, as: Double.self).map { Int($0.rounded()) }
                                chartHover.selected = index.flatMap { (0..<buckets.count).contains($0) ? $0 : nil }
                            case .ended:
                                chartHover.selected = nil
                            }
                        }
                }
            }
            .frame(height: 72)
            .accessibilityLabel("Son 24 saatte saat başına başlayan sorun sayısı. Toplam \(total).")
        }
    }

    /// Grafiğin üstündeki satır. Fare bir çubuğun üzerindeyse saat ve sorun adları, değilse ipucu.
    private func hoverText(buckets: [Int], now: Date) -> String {
        guard let index = chartHover.selected, buckets.indices.contains(index) else { return "Ayrıntı için bir çubuğun üzerine gelin." }
        let titles = AlertTimeline.titles(center.history, bucket: index, now: now)
        let label = AlertTimeline.label(bucket: index)
        return titles.isEmpty ? "\(label): sorun başlamadı" : "\(label): " + titles.joined(separator: ", ")
    }

    private var activeCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(symbol: "exclamationmark.triangle", title: "Açık sorunlar")
            FilterBar(model: issueFilter, showsRange: false)
            let shown = issueFilter.sort.sorted(center.active.filter {
                issueFilter.filter.matches(issue: $0, snoozed: center.isSnoozed($0.key))
            })
            if shown.isEmpty {
                Text(center.active.isEmpty ? "Açık sorun yok." : "Süzgece uyan sorun yok.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(issueFilter.pageSize.slice(shown, page: issueFilter.page)) { issue in
                ActiveIssueRow(center: center, issue: issue)
            }
            if shown.count > PageSize.ten.rawValue { PagerBar(model: issueFilter, total: shown.count) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardHeader(symbol: "clock.arrow.circlepath", title: "Son olaylar")
                Menu("Dışa aktar") {
                    Button("CSV") { ExportSaver.save(AlertExport.csv(shownEvents), name: "nobet-olaylar.csv") }
                    Button("JSON") { ExportSaver.save(AlertExport.json(shownEvents), name: "nobet-olaylar.json") }
                }
                .menuStyle(.borderlessButton).fixedSize().font(.caption)
                .disabled(shownEvents.isEmpty)
            }
            FilterBar(model: eventFilter)
            if shownEvents.isEmpty {
                Text(center.history.isEmpty ? "Henüz olay yok." : "Süzgece uyan olay yok.").font(.callout).foregroundStyle(.secondary)
            }
            let pageEvents = eventFilter.pageSize.slice(shownEvents, page: eventFilter.page)
            let byDate = eventFilter.sort == .date
            ForEach(byDate ? DayGrouping.groups(pageEvents, now: Date()) : [DayGrouping.Group(title: "", events: pageEvents)], id: \.title) { group in
                if !group.title.isEmpty {
                    Text(group.title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
                }
                ForEach(group.events) { event in
                    HStack(spacing: 8) {
                        Circle().fill(event.kind == .started ? Color.orange : Color.green).frame(width: 7, height: 7).accessibilityHidden(true)
                        Text(event.kind == .started ? "Başladı" : "Çözüldü")
                            .foregroundStyle(event.kind == .started ? Color.orange : Color.green)
                            .frame(width: 56, alignment: .leading)
                        Image(systemName: ModuleNames.symbol(event.issue.module)).font(.caption).foregroundStyle(.secondary).frame(width: 16)
                        Text("\(event.issue.title) · \(event.issue.subject)").lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(byDate ? Self.timeText(event.date) : event.date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(Locale(identifier: "tr_TR"))))
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    .font(.callout)
                }
            }
            if shownEvents.count > PageSize.ten.rawValue { PagerBar(model: eventFilter, total: shownEvents.count) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private static func timeText(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(Locale(identifier: "tr_TR")))
    }

    /// Süzgeçten geçen ve seçili sıraya dizilen olaylar. Dışa aktarma da bunu kullanır.
    private var shownEvents: [AlertEvent] {
        let now = Date()
        return eventFilter.sort.sorted(center.history.filter {
            eventFilter.filter.matches(event: $0, snoozed: center.isSnoozed($0.issue.key), now: now)
        })
    }
}


/// `@State` bu araç zincirinde derlenmez. Not taslağı küçük bir nesnede durur.
final class NoteDraft: ObservableObject {
    @Published var shown = false
    @Published var text = ""
}

/// Sorun için "Ertele" menüsü. Ertelenmişse kalan süreyi ve "Geri al" düğmesini gösterir.
struct SnoozeControl: View {
    @ObservedObject var center: AlertCenter
    let key: String

    var body: some View {
        if let remaining = center.snoozeRemaining(key: key) {
            HStack(spacing: 6) {
                Text(SnoozeChoice.remainingText(seconds: remaining)).font(.caption).foregroundStyle(.secondary)
                Button("Geri al") { center.unsnooze(key: key) }
                    .buttonStyle(.link).font(.caption)
            }
        } else {
            Menu("Ertele") {
                ForEach(SnoozeChoice.allCases, id: \.self) { choice in
                    Button(choice.title) { center.snooze(key: key, for: choice.seconds) }
                }
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .font(.caption)
        }
    }
}

/// Kayıt penceresi açar ve metni seçilen dosyaya yazar. Dosya yalnızca sahibine açıktır.
enum ExportSaver {
    @MainActor
    static func save(_ text: String, name: String) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = name
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(text.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            NSSound.beep()
        }
    }
}

final class RowHover: ObservableObject {
    @Published var on = false
}

/// Açık sorun satırı: önem ve modül simgesi, başlık, konu. Eylemler tek "⋯" menüsünde toplanır.
struct ActiveIssueRow: View {
    @ObservedObject var center: AlertCenter
    let issue: AlertIssue
    @StateObject private var hover = RowHover()
    @StateObject private var draft = NoteDraft()

    var body: some View {
        let remaining = center.snoozeRemaining(key: issue.key)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Image(systemName: issue.severity.symbol)
                    .foregroundStyle(issue.severity == .high ? Color.red : Color.orange)
                    .frame(width: 18)
                    .accessibilityLabel(issue.severity.label)
                Image(systemName: ModuleNames.symbol(issue.module))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .help(ModuleNames.title(issue.module))
                    .accessibilityLabel(ModuleNames.title(issue.module))
                Text(issue.title)
                Spacer(minLength: 8)
                Text(issue.subject).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                if let remaining {
                    Text(SnoozeChoice.remainingText(seconds: remaining)).font(.caption).foregroundStyle(.secondary)
                }
                actions(snoozed: remaining != nil)
            }
            .font(.callout)
            if let note = center.note(for: issue.key) {
                Text(verbatim: "Not: \(note)").font(.caption).foregroundStyle(.secondary).padding(.leading, 42)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onHover { hover.on = $0 }
    }

    private func actions(snoozed: Bool) -> some View {
        Menu {
            Button(center.note(for: issue.key) == nil ? "Not ekle…" : "Notu düzenle…") {
                draft.text = center.note(for: issue.key) ?? ""
                draft.shown = true
            }
            if snoozed {
                Button("Ertelemeyi geri al") { center.unsnooze(key: issue.key) }
            } else {
                Menu("Ertele") {
                    ForEach(SnoozeChoice.allCases, id: \.self) { choice in
                        Button(choice.title) { center.snooze(key: issue.key, for: choice.seconds) }
                    }
                }
            }
        } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .opacity(hover.on || snoozed ? 1 : 0.4)
            .help("Not ve erteleme")
            .accessibilityLabel("\(issue.title) eylemleri")
            .popover(isPresented: $draft.shown) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Not (en çok \(AlertCenter.noteLimit) karakter)").font(.caption).foregroundStyle(.secondary)
                    TextField("Örn. bakım penceresi", text: $draft.text).frame(width: 260)
                    HStack {
                        Spacer()
                        Button("Kaydet") { center.setNote(draft.text, for: issue.key); draft.shown = false }
                            .keyboardShortcut(.defaultAction)
                    }
                }
                .padding(12)
            }
    }
}

final class ChartHover: ObservableObject {
    @Published var selected: Int?
}
