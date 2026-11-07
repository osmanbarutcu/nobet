import SwiftUI

/// SSH sunucularını yan yana karşılaştıran tablonun satırları.
enum ServerComparison {
    struct Row: Equatable, Identifiable {
        let id: String
        let name: String
        let diskPercent: Int?
        let memoryPercent: Int?
        let load: Double?
        let uptimeDays: Int?
        let issueCount: Int
    }

    enum SortKey: String, CaseIterable {
        case name, disk, memory, load, issues

        var title: String {
            switch self {
            case .name: return "Ad"
            case .disk: return "Disk"
            case .memory: return "Bellek"
            case .load: return "Yük"
            case .issues: return "Sorun"
            }
        }
    }

    static func row(_ profile: SSHProfile, metrics: RemoteMetrics?, issueCount: Int) -> Row {
        let disk = metrics.flatMap { m in (m.disks.first { $0.mount == "/" } ?? m.disks.first)?.usedPercent }
        return Row(id: profile.id, name: profile.name, diskPercent: disk, memoryPercent: metrics?.memory?.usedPercent,
                   load: metrics?.load?.first, uptimeDays: metrics?.uptimeSeconds.map { $0 / 86_400 }, issueCount: issueCount)
    }

    /// Ad artan sırayla, diğer anahtarlar en yüksek değer önce. Değeri olmayan satır sona gider.
    static func sorted(_ rows: [Row], by key: SortKey) -> [Row] {
        func value(_ row: Row) -> Double? {
            switch key {
            case .name: return nil
            case .disk: return row.diskPercent.map(Double.init)
            case .memory: return row.memoryPercent.map(Double.init)
            case .load: return row.load
            case .issues: return Double(row.issueCount)
            }
        }
        if key == .name { return rows.sorted { $0.name.localizedCompare($1.name) == .orderedAscending } }
        return rows.sorted { left, right in
            switch (value(left), value(right)) {
            case let (l?, r?): return l > r
            case (_?, nil): return true
            default: return false
            }
        }
    }
}

/// Kart ve tablo görünümü arasındaki seçim.
enum ServerViewMode: String, CaseIterable {
    case cards, table

    static let key = "servers.ssh.viewMode"

    init(stored: String?) { self = stored.flatMap(Self.init(rawValue:)) ?? .cards }

    var title: String { self == .cards ? "Kart" : "Tablo" }
}

final class ComparisonState: ObservableObject {
    @Published var sort = ServerComparison.SortKey.name
}

struct ComparisonTable: View {
    @ObservedObject var model: RemoteModel
    @StateObject private var state = ComparisonState()

    var body: some View {
        let rows = ServerComparison.sorted(
            model.profiles.map { ServerComparison.row($0, metrics: model.metrics(for: $0), issueCount: model.issues(for: $0).count) },
            by: state.sort
        )
        VStack(alignment: .leading, spacing: 8) {
            Picker("Sırala", selection: $state.sort) {
                ForEach(ServerComparison.SortKey.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented).frame(maxWidth: 380)
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow {
                    ForEach(["Sunucu", "Disk", "Bellek", "Yük", "Açık kalma", "Sorun"], id: \.self) {
                        Text($0).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                Divider().gridCellColumns(6)
                ForEach(rows) { row in
                    GridRow {
                        Text(row.name).lineLimit(1)
                        Text(percent(row.diskPercent))
                        Text(percent(row.memoryPercent))
                        Text(row.load.map { String(format: "%.2f", $0) } ?? "-")
                        Text(row.uptimeDays.map { "\($0) gün" } ?? "-")
                        Text(row.issueCount == 0 ? "-" : String(row.issueCount)).foregroundStyle(row.issueCount == 0 ? Color.secondary : Color.orange)
                    }
                    .font(.callout.monospacedDigit())
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func percent(_ value: Int?) -> String { value.map { "%\($0)" } ?? "-" }
}

extension RemoteMetrics {
    /// Kök disk, yoksa ilk disk. Yüzde olarak.
    var mainDiskPercent: Int? { (disks.first { $0.mount == "/" } ?? disks.first)?.usedPercent }

    /// 1 dakikalık yükün çekirdek başına yüzdesi, 100'de kesilir. Yük veya çekirdek yoksa `nil`.
    var cpuPercent: Int? {
        guard let load = load?.first, let cores, cores > 0 else { return nil }
        return min(100, Int((load / Double(cores) * 100).rounded()))
    }
}

/// Panel göstergelerinin renk seviyesi. Disk ve bellek profil eşiğini kullanır.
enum PanelGauge {
    static func disk(percent: Int, thresholds: ServerThresholds) -> GaugeLevel {
        GaugeLevel.of(percent: percent, medium: thresholds.diskMedium, high: thresholds.diskHigh)
    }

    /// Bellek eşiği "boş kalan yüzde" olarak tutulur. Kullanım eşiği bunun tersidir.
    static func memory(percent: Int, thresholds: ServerThresholds) -> GaugeLevel {
        GaugeLevel.of(percent: percent, medium: 100 - thresholds.memoryLowPercent * 2, high: 100 - thresholds.memoryLowPercent)
    }

    static let cpuMedium = 70
    static let cpuHigh = 100

    static func cpu(percent: Int) -> GaugeLevel {
        GaugeLevel.of(percent: percent, medium: cpuMedium, high: cpuHigh)
    }
}
