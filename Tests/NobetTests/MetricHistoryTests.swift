import Foundation
import Testing
@testable import Nobet

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func sample(_ minutes: Double, disk: Int? = 50) -> MetricSample {
    MetricSample(date: t0.addingTimeInterval(minutes * 60), diskPercent: disk, memoryPercent: 40, load: 0.5)
}

private func metrics(disk: Int, available: Int = 600, load: Double = 1.5) -> RemoteMetrics {
    RemoteMetrics(disks: [DiskUsage(mount: "/data", usedPercent: 10), DiskUsage(mount: "/", usedPercent: disk)],
                  memory: MemoryUsage(totalMB: 1000, availableMB: available, swapTotalMB: 0, swapUsedMB: 0),
                  load: [load, 1, 1], cores: 2, uptimeSeconds: nil, services: [:], failedUnits: [])
}

struct MetricHistoryTests {
    @Test func sampleTakesRootDiskMemoryAndLoad() {
        let value = MetricSample(metrics: metrics(disk: 63), date: t0)
        #expect(value.diskPercent == 63)
        #expect(value.memoryPercent == 40)
        #expect(value.load == 1.5)
    }

    @Test func sampleFallsBackToFirstDiskAndHandlesMissingData() {
        let noRoot = RemoteMetrics(disks: [DiskUsage(mount: "/data", usedPercent: 7)], memory: nil, load: nil, cores: nil,
                                   uptimeSeconds: nil, services: [:], failedUnits: [])
        let value = MetricSample(metrics: noRoot, date: t0)
        #expect(value.diskPercent == 7)
        #expect(value.memoryPercent == nil)
        #expect(value.load == nil)
    }

    @Test func newestSampleIsLastAndOrderIsKept() {
        let result = MetricHistory.appending(sample(10), to: [sample(0), sample(5)])
        #expect(result.map(\.date) == [sample(0), sample(5), sample(10)].map(\.date))
    }

    @Test func samplesOlderThanTwentyFourHoursAreDropped() {
        let old = [sample(0), sample(30)]
        let result = MetricHistory.appending(sample(25 * 60), to: old)
        #expect(result.map(\.date) == [sample(25 * 60).date])
    }

    @Test func sampleExactlyAtTheWindowEdgeStays() {
        let result = MetricHistory.appending(sample(24 * 60), to: [sample(0)])
        #expect(result.count == 2)
    }

    @Test func historyIsCappedAtTheLimit() {
        var history: [MetricSample] = []
        for index in 0..<(MetricHistory.limit + 50) { history = MetricHistory.appending(sample(Double(index) * 0.1), to: history) }
        #expect(history.count == MetricHistory.limit)
        #expect(history.last?.date == sample(Double(MetricHistory.limit + 49) * 0.1).date)
    }

    @Test func valuesSkipMissingEntries() {
        let history = [sample(0, disk: 10), sample(5, disk: nil), sample(10, disk: 30)]
        #expect(MetricHistory.values(history) { $0.diskPercent.map(Double.init) } == [10, 30])
    }
}

struct SparklineTests {
    @Test func valuesAreScaledToZeroOne() {
        #expect(Sparkline.normalized([10, 20, 30]) == [0, 0.5, 1])
    }

    @Test func flatSeriesSitsInTheMiddle() {
        #expect(Sparkline.normalized([5, 5, 5]) == [0.5, 0.5, 0.5])
    }

    @Test func fewerThanTwoPointsGiveNoLine() {
        #expect(Sparkline.normalized([]).isEmpty)
        #expect(Sparkline.normalized([4]).isEmpty)
    }

    @Test func percentSeriesUsesAFixedScaleSoSmallChangesStayFlat() {
        // %50 -> %51 çizgiyi zirveye taşımamalı. Yüzde serisi 0-100 ölçeğinde çizilir.
        let points = Sparkline.normalized([50, 51], range: 0...100)
        #expect(points == [0.5, 0.51])
    }
}

struct RemoteHistoryModelTests {
    private func makeDefaults() -> UserDefaults {
        let name = "nobet-history-test-\(UUID().uuidString)"
        let defaults = TestDefaults.make(name)
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test @MainActor func everyCheckAddsOneSampleForASuccessfulServer() async {
        let collector = FakeCollector(results: ["a.com": .success(metrics(disk: 42))])
        let clock = Clock(t0)
        let model = RemoteModel(nobet: NobetModel(), defaults: makeDefaults(), secrets: FakeSecrets(), collector: collector, now: { clock.date })
        model.addProfile(name: "A", host: "a.com", port: 22, user: "root", auth: .key, services: [], password: "")
        await model.checkAll()
        clock.date = t0.addingTimeInterval(300)
        await model.checkAll()
        let id = model.profiles[0].id
        // `addProfile` arka planda kendi okumasını da başlatır. Bu yüzden en az iki örnek beklenir.
        #expect((model.history[id]?.count ?? 0) >= 2)
        #expect(model.history[id]?.last?.diskPercent == 42)
    }

    @Test @MainActor func failedChecksAddNothing() async {
        let collector = FakeCollector(results: [:])
        let model = RemoteModel(nobet: NobetModel(), defaults: makeDefaults(), secrets: FakeSecrets(), collector: collector, now: { t0 })
        model.addProfile(name: "A", host: "a.com", port: 22, user: "root", auth: .key, services: [], password: "")
        await model.checkAll()
        #expect(model.history[model.profiles[0].id] == nil)
    }

    @Test @MainActor func removingAServerDropsItsHistory() async {
        let collector = FakeCollector(results: ["a.com": .success(metrics(disk: 42))])
        let model = RemoteModel(nobet: NobetModel(), defaults: makeDefaults(), secrets: FakeSecrets(), collector: collector, now: { t0 })
        model.addProfile(name: "A", host: "a.com", port: 22, user: "root", auth: .key, services: [], password: "")
        await model.checkAll()
        let profile = model.profiles[0]
        model.removeProfile(profile)
        #expect(model.history[profile.id] == nil)
    }

    @Test @MainActor func historyIsNeverWrittenToDisk() async {
        let defaults = makeDefaults()
        let collector = FakeCollector(results: ["a.com": .success(metrics(disk: 42))])
        let model = RemoteModel(nobet: NobetModel(), defaults: defaults, secrets: FakeSecrets(), collector: collector, now: { t0 })
        model.addProfile(name: "A", host: "a.com", port: 22, user: "root", auth: .key, services: [], password: "")
        await model.checkAll()
        let keys = defaults.dictionaryRepresentation().keys.filter { !$0.hasPrefix("NS") && !$0.hasPrefix("Apple") }
        #expect(keys.allSatisfy { !$0.lowercased().contains("history") })
    }
}

/// Testte ilerletilebilen saat. `now` kapanışı bunu okur.
private final class Clock: @unchecked Sendable {
    var date: Date
    init(_ date: Date) { self.date = date }
}

struct MetricChartTests {
    @Test func percentKindsUseAFixedZeroToHundredAxis() {
        #expect(MetricChartKind.disk.yDomain(for: [10, 20]) == 0...100)
        #expect(MetricChartKind.memory.yDomain(for: []) == 0...100)
    }

    @Test func loadAxisGrowsWithThePeakAndHasAFloor() {
        #expect(MetricChartKind.load.yDomain(for: [0.1, 0.4]) == 0...1)
        #expect(MetricChartKind.load.yDomain(for: [0.5, 3.2]) == 0...4)
    }

    @Test func pointsSkipMissingValuesAndKeepDates() {
        let history = [sample(0, disk: 10), sample(5, disk: nil), sample(10, disk: 30)]
        let points = MetricChartKind.disk.points(history)
        #expect(points.map(\.value) == [10, 30])
        #expect(points.map(\.date) == [sample(0).date, sample(10).date])
    }

    @Test func titlesAndUnitsAreTurkish() {
        #expect(MetricChartKind.allCases.map(\.title) == ["Disk", "Bellek", "Yük"])
        #expect(MetricChartKind.disk.unit == "%")
        #expect(MetricChartKind.load.unit == "")
    }
}

struct GaugeLevelTests {
    @Test func levelFollowsTheThresholds() {
        #expect(GaugeLevel.of(percent: 50, medium: 80, high: 90) == .ok)
        #expect(GaugeLevel.of(percent: 80, medium: 80, high: 90) == .warning)
        #expect(GaugeLevel.of(percent: 89, medium: 80, high: 90) == .warning)
        #expect(GaugeLevel.of(percent: 90, medium: 80, high: 90) == .critical)
    }

    @Test func fractionIsClampedToZeroOne() {
        #expect(GaugeLevel.fraction(percent: -5) == 0)
        #expect(GaugeLevel.fraction(percent: 40) == 0.4)
        #expect(GaugeLevel.fraction(percent: 140) == 1)
    }
}

struct ChartWindowTests {
    @Test func windowKeepsOnlyRecentSamples() {
        let samples = [sample(0), sample(60), sample(23 * 60), sample(24 * 60)]
        let now = sample(24 * 60).date
        #expect(ChartWindow.hour.filter(samples, now: now).count == 1)
        #expect(ChartWindow.sixHours.filter(samples, now: now).count == 2)
        #expect(ChartWindow.day.filter(samples, now: now).count == 3)
    }

    @Test func titlesAreTurkish() {
        #expect(ChartWindow.allCases.map(\.title) == ["1 saat", "6 saat", "24 saat"])
    }

    @Test func thresholdLinesFollowTheServerThresholds() {
        let thresholds = ServerThresholds(diskMedium: 70, diskHigh: 85, memoryLowPercent: 10, loadPerCore: 2)
        #expect(MetricChartKind.disk.thresholdLines(thresholds) == [70, 85])
        #expect(MetricChartKind.memory.thresholdLines(thresholds) == [80, 90])
        #expect(MetricChartKind.load.thresholdLines(thresholds).isEmpty)
    }
}

struct RebootDetectorTests {
    @Test func uptimeDroppingMeansARestart() {
        #expect(RebootDetector.rebooted(previous: 5000, current: 40))
        #expect(!RebootDetector.rebooted(previous: 5000, current: 5300))
    }

    @Test func missingValuesAreNeverARestart() {
        #expect(!RebootDetector.rebooted(previous: nil, current: 40))
        #expect(!RebootDetector.rebooted(previous: 5000, current: nil))
    }

    @Test func smallBackwardsJitterIsIgnored() {
        #expect(!RebootDetector.rebooted(previous: 5000, current: 4990))
    }

    @Test func restartTimeIsNowMinusUptime() {
        #expect(RebootDetector.rebootDate(now: t0, uptime: 120) == t0.addingTimeInterval(-120))
    }

    @Test func historyKeepsTheLatestTenAndDropsOldOnes() {
        var dates: [Date] = []
        for index in 0..<12 { dates = RebootDetector.appending(t0.addingTimeInterval(Double(index)), to: dates) }
        #expect(dates.count == 10)
        #expect(dates.first == t0.addingTimeInterval(2))
    }
}

struct RemoteRebootModelTests {
    private func makeDefaults() -> UserDefaults {
        let name = "nobet-reboot-test-\(UUID().uuidString)"
        let defaults = TestDefaults.make(name)
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private func withUptime(_ seconds: Int) -> RemoteMetrics {
        var value = metrics(disk: 40)
        value.uptimeSeconds = seconds
        return value
    }

    @Test @MainActor func restartBetweenTwoReadsIsRecorded() async {
        let collector = FakeCollector(results: ["a.com": .success(withUptime(9000))])
        let model = RemoteModel(nobet: NobetModel(), defaults: makeDefaults(), secrets: FakeSecrets(), collector: collector, now: { t0 })
        model.addProfile(name: "A", host: "a.com", port: 22, user: "root", auth: .key, services: [], password: "")
        await model.checkAll()
        // `addProfile` arka planda kendi okumasını da başlatır. Önce o bitsin.
        try? await Task.sleep(nanoseconds: 300_000_000)
        collector.results["a.com"] = .success(withUptime(30))
        await model.checkAll()
        let id = model.profiles[0].id
        #expect(model.reboots[id]?.last == t0.addingTimeInterval(-30))
    }

    @Test @MainActor func steadyUptimeRecordsNothing() async {
        let collector = FakeCollector(results: ["a.com": .success(withUptime(9000))])
        let model = RemoteModel(nobet: NobetModel(), defaults: makeDefaults(), secrets: FakeSecrets(), collector: collector, now: { t0 })
        model.addProfile(name: "A", host: "a.com", port: 22, user: "root", auth: .key, services: [], password: "")
        await model.checkAll()
        await model.checkAll()
        #expect(model.reboots[model.profiles[0].id] == nil)
    }
}

struct RemoteLatencyModelTests {
    private func makeDefaults() -> UserDefaults {
        let name = "nobet-rtt-test-\(UUID().uuidString)"
        let defaults = TestDefaults.make(name)
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test @MainActor func successfulReadRecordsTheResponseTime() async {
        let collector = FakeCollector(results: ["a.com": .success(metrics(disk: 40))])
        let model = RemoteModel(nobet: NobetModel(), defaults: makeDefaults(), secrets: FakeSecrets(), collector: collector, now: { t0 })
        model.addProfile(name: "A", host: "a.com", port: 22, user: "root", auth: .key, services: [], password: "")
        await model.checkAll()
        #expect((model.responseMs[model.profiles[0].id] ?? -1) >= 0)
    }

    @Test @MainActor func failedReadRecordsNoResponseTime() async {
        let collector = FakeCollector(results: [:])
        let model = RemoteModel(nobet: NobetModel(), defaults: makeDefaults(), secrets: FakeSecrets(), collector: collector, now: { t0 })
        model.addProfile(name: "A", host: "a.com", port: 22, user: "root", auth: .key, services: [], password: "")
        await model.checkAll()
        #expect(model.responseMs[model.profiles[0].id] == nil)
    }

    @Test func textShowsMillisecondsOrSeconds() {
        #expect(ResponseTimeText.make(ms: 420) == "420 ms")
        #expect(ResponseTimeText.make(ms: 2300) == "2,3 sn")
    }
}
