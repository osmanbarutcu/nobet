import Foundation
import Testing
@testable import Nobet

struct ServerComparisonTests {
    private func profile(_ id: String) -> SSHProfile {
        SSHProfile.make(name: id, host: "\(id).example.com", port: 22, user: "root", auth: .key, services: [], id: id)!
    }

    private func metrics(disk: Int, available: Int, load: Double, uptime: Int) -> RemoteMetrics {
        RemoteMetrics(disks: [DiskUsage(mount: "/data", usedPercent: 10), DiskUsage(mount: "/", usedPercent: disk)],
                      memory: MemoryUsage(totalMB: 1000, availableMB: available, swapTotalMB: 0, swapUsedMB: 0),
                      load: [load, 0, 0], cores: 2, uptimeSeconds: uptime, services: [:], failedUnits: [])
    }

    @Test func rowReadsRootDiskMemoryLoadAndUptime() {
        let row = ServerComparison.row(profile("a"), metrics: metrics(disk: 55, available: 250, load: 1.5, uptime: 3 * 86_400 + 7200), issueCount: 2)
        #expect(row.name == "a")
        #expect(row.diskPercent == 55)
        #expect(row.memoryPercent == 75)
        #expect(row.load == 1.5)
        #expect(row.uptimeDays == 3)
        #expect(row.issueCount == 2)
    }

    @Test func unreadServerHasEmptyValues() {
        let row = ServerComparison.row(profile("a"), metrics: nil, issueCount: 0)
        #expect(row.diskPercent == nil && row.memoryPercent == nil && row.load == nil && row.uptimeDays == nil)
    }

    @Test func sortingPutsTheHighestValueFirstAndEmptyLast() {
        let rows = [
            ServerComparison.row(profile("a"), metrics: metrics(disk: 30, available: 500, load: 1, uptime: 1), issueCount: 0),
            ServerComparison.row(profile("b"), metrics: nil, issueCount: 0),
            ServerComparison.row(profile("c"), metrics: metrics(disk: 80, available: 500, load: 1, uptime: 1), issueCount: 0),
        ]
        #expect(ServerComparison.sorted(rows, by: .disk).map(\.name) == ["c", "a", "b"])
        #expect(ServerComparison.sorted(rows, by: .name).map(\.name) == ["a", "b", "c"])
    }

    @Test func sortKeysHaveTurkishTitles() {
        #expect(ServerComparison.SortKey.allCases.map(\.title) == ["Ad", "Disk", "Bellek", "Yük", "Sorun"])
    }
}

struct ServerViewModeTests {
    @Test func unknownStoredValueFallsBackToCards() {
        #expect(ServerViewMode(stored: "yok") == .cards)
        #expect(ServerViewMode(stored: "table") == .table)
        #expect(ServerViewMode.allCases.map(\.title) == ["Kart", "Tablo"])
    }
}

struct PanelGaugeTests {
    private func metrics(load: [Double]?, cores: Int?) -> RemoteMetrics {
        RemoteMetrics(disks: [DiskUsage(mount: "/data", usedPercent: 10), DiskUsage(mount: "/", usedPercent: 62)],
                      memory: MemoryUsage(totalMB: 1000, availableMB: 400, swapTotalMB: 0, swapUsedMB: 0),
                      load: load, cores: cores, uptimeSeconds: nil, services: [:], failedUnits: [])
    }

    @Test func cpuIsOneMinuteLoadPerCoreAsPercent() {
        #expect(metrics(load: [1.0, 0, 0], cores: 4).cpuPercent == 25)
    }

    @Test func cpuIsCappedAtOneHundred() {
        #expect(metrics(load: [9.0, 0, 0], cores: 2).cpuPercent == 100)
    }

    @Test func cpuIsNilWithoutLoadOrCores() {
        #expect(metrics(load: nil, cores: 4).cpuPercent == nil)
        #expect(metrics(load: [1, 0, 0], cores: nil).cpuPercent == nil)
        #expect(metrics(load: [1, 0, 0], cores: 0).cpuPercent == nil)
    }

    @Test func rootDiskIsPreferredOverOtherMounts() {
        #expect(metrics(load: nil, cores: nil).mainDiskPercent == 62)
    }

    @Test func gaugeLevelFollowsThresholds() {
        let thresholds = ServerThresholds.standard
        #expect(PanelGauge.disk(percent: 85, thresholds: thresholds) == .warning)
        #expect(PanelGauge.disk(percent: 95, thresholds: thresholds) == .critical)
        #expect(PanelGauge.disk(percent: 40, thresholds: thresholds) == .ok)
        #expect(PanelGauge.memory(percent: 95, thresholds: thresholds) == .critical)
        #expect(PanelGauge.memory(percent: 50, thresholds: thresholds) == .ok)
        #expect(PanelGauge.cpu(percent: 100) == .critical)
        #expect(PanelGauge.cpu(percent: 80) == .warning)
        #expect(PanelGauge.cpu(percent: 30) == .ok)
    }
}
