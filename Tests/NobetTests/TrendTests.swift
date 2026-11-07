import Foundation
import Testing
@testable import Nobet

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func site(_ minutes: Double, up: Bool = true, latency: Int? = 100) -> SiteSample {
    SiteSample(date: t0.addingTimeInterval(minutes * 60), up: up, latencyMs: latency)
}

struct SiteHistoryTests {
    @Test func uptimeIsTheShareOfSuccessfulChecks() {
        let samples = [site(0), site(5), site(10, up: false, latency: nil), site(15)]
        #expect(SiteHistory.uptimePercent(samples) == 75)
    }

    @Test func noSamplesMeansUnknownUptime() {
        #expect(SiteHistory.uptimePercent([]) == nil)
    }

    @Test func allUpIsOneHundred() {
        #expect(SiteHistory.uptimePercent([site(0), site(5)]) == 100)
    }

    @Test func averageLatencyIgnoresFailedChecks() {
        let samples = [site(0, latency: 100), site(5, up: false, latency: nil), site(10, latency: 300)]
        #expect(SiteHistory.averageLatencyMs(samples) == 200)
    }

    @Test func averageLatencyIsNilWithoutAnyLatency() {
        #expect(SiteHistory.averageLatencyMs([site(0, up: false, latency: nil)]) == nil)
    }

    @Test func historyKeepsTwentyFourHoursAndCaps() {
        let old = [site(0), site(30)]
        let result = SiteHistory.appending(site(25 * 60), to: old)
        #expect(result.map(\.date) == [site(25 * 60).date])
        var capped: [SiteSample] = []
        for index in 0..<(SiteHistory.limit + 20) { capped = SiteHistory.appending(site(Double(index) * 0.1), to: capped) }
        #expect(capped.count == SiteHistory.limit)
    }

    @Test func latencySeriesSkipsFailures() {
        let samples = [site(0, latency: 120), site(5, up: false, latency: nil), site(10, latency: 80)]
        #expect(SiteHistory.latencies(samples) == [120, 80])
    }
}

struct AlertTimelineTests {
    private func event(_ minutesAgo: Double, kind: AlertEvent.Kind = .started) -> AlertEvent {
        let issue = AlertIssue(key: "k\(minutesAgo)", module: "servers", subject: "a.com", title: "Sorun", severity: .high)
        return AlertEvent(kind: kind, issue: issue, date: t0.addingTimeInterval(-minutesAgo * 60))
    }

    @Test func bucketsAreHourlyOldestFirstAndEndAtNow() {
        let buckets = AlertTimeline.hourlyStarts([event(10), event(30), event(90)], now: t0, hours: 4)
        // Son saat (0-60 dk önce): 2 olay. Bir önceki saat (60-120 dk önce): 1 olay.
        #expect(buckets == [0, 0, 1, 2])
    }

    @Test func resolvedEventsAreNotCounted() {
        #expect(AlertTimeline.hourlyStarts([event(10, kind: .resolved)], now: t0, hours: 3) == [0, 0, 0])
    }

    @Test func eventsOlderThanTheWindowAreIgnored() {
        #expect(AlertTimeline.hourlyStarts([event(5 * 60)], now: t0, hours: 3) == [0, 0, 0])
    }

    @Test func futureEventsAreIgnored() {
        #expect(AlertTimeline.hourlyStarts([event(-30)], now: t0, hours: 3) == [0, 0, 0])
    }

    @Test func boundaryBelongsToTheOlderBucket() {
        // Tam 60 dk önce olan olay, bir önceki saat kutusuna düşer.
        #expect(AlertTimeline.hourlyStarts([event(60)], now: t0, hours: 3) == [0, 1, 0])
    }

    @Test func defaultWindowIsTwentyFourBuckets() {
        #expect(AlertTimeline.hourlyStarts([], now: t0).count == 24)
    }
}

struct SiteModelHistoryTests {
    private func makeDefaults() -> UserDefaults {
        let name = "nobet-sitehist-test-\(UUID().uuidString)"
        let defaults = TestDefaults.make(name)
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    private struct Prober: ServerProbing {
        let result: ProbeResult
        func probe(_ site: ServerSite) async -> ProbeResult { result }
    }

    @Test @MainActor func everyCheckRecordsUpAndLatency() async {
        let ok = ProbeResult(reachable: true, httpStatus: 200, latencyMs: 140, certExpiry: nil, error: nil)
        let model = ServerModel(nobet: NobetModel(), defaults: makeDefaults(), prober: Prober(result: ok), now: { t0 })
        model.addSite(name: "A", host: "a.com", port: 443)
        await model.checkAll()
        await model.checkAll()
        let samples = model.history[model.sites[0].id] ?? []
        #expect(samples.count >= 2)
        #expect(samples.last?.up == true)
        #expect(samples.last?.latencyMs == 140)
    }

    @Test @MainActor func unreachableSiteIsRecordedAsDown() async {
        let down = ProbeResult(reachable: false, httpStatus: nil, latencyMs: nil, certExpiry: nil, error: "x")
        let model = ServerModel(nobet: NobetModel(), defaults: makeDefaults(), prober: Prober(result: down), now: { t0 })
        model.addSite(name: "A", host: "a.com", port: 443)
        await model.checkAll()
        #expect(model.history[model.sites[0].id]?.last?.up == false)
    }

    @Test @MainActor func removedSiteLosesItsHistory() async {
        let ok = ProbeResult(reachable: true, httpStatus: 200, latencyMs: 90, certExpiry: nil, error: nil)
        let model = ServerModel(nobet: NobetModel(), defaults: makeDefaults(), prober: Prober(result: ok), now: { t0 })
        model.addSite(name: "A", host: "a.com", port: 443)
        await model.checkAll()
        let site = model.sites[0]
        model.removeSite(site)
        #expect(model.history[site.id] == nil)
    }
}

struct SiteStatusTextTests {
    @Test func uptimeTextUsesTurkishDecimalComma() {
        let samples = (0..<1000).map { SiteSample(date: t0.addingTimeInterval(Double($0)), up: $0 != 0, latencyMs: 10) }
        #expect(SiteStatusText.uptime(samples) == "%99,9 ayakta")
    }

    @Test func fullUptimeHasNoDecimal() {
        #expect(SiteStatusText.uptime([SiteSample(date: t0, up: true, latencyMs: 5)]) == "%100 ayakta")
    }

    @Test func noSamplesShowDash() {
        #expect(SiteStatusText.uptime([]) == "-")
    }
}

struct SiteChartDataTests {
    @Test func latencyPointsKeepDatesAndSkipFailures() {
        let samples = [site(0, latency: 120), site(5, up: false, latency: nil), site(10, latency: 80)]
        let points = SiteHistory.latencyPoints(samples)
        #expect(points.map(\.value) == [120, 80])
        #expect(points.map(\.date) == [site(0).date, site(10).date])
    }

    @Test func downtimeDatesListFailedChecks() {
        let samples = [site(0), site(5, up: false, latency: nil), site(10)]
        #expect(SiteHistory.downtimeDates(samples) == [site(5).date])
    }

    @Test func latencyAxisRoundsUpToHundredsWithAFloor() {
        #expect(SiteHistory.latencyDomain([80, 140]) == 0...200)
        #expect(SiteHistory.latencyDomain([]) == 0...100)
        #expect(SiteHistory.latencyDomain([100]) == 0...100)
    }
}

struct HistoryFileTests {
    private func tempURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory() + "nobet-hist-\(UUID().uuidString)/history.json")
    }

    @Test func savedSamplesAreReadBack() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = HistoryFile<SiteSample>(url: url)
        file.save(["a": [site(0), site(5, up: false, latency: nil)]])
        #expect(file.load(now: t0.addingTimeInterval(600)) == ["a": [site(0), site(5, up: false, latency: nil)]])
    }

    @Test func samplesOlderThanTheWindowAreDroppedOnLoad() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = HistoryFile<SiteSample>(url: url)
        file.save(["a": [site(0), site(25 * 60)]])
        let loaded = file.load(now: site(25 * 60).date)
        #expect(loaded["a"]?.count == 1)
    }

    @Test func missingOrBrokenFileGivesEmptyHistory() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let file = HistoryFile<SiteSample>(url: url)
        #expect(file.load(now: t0).isEmpty)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("bozuk".utf8).write(to: url)
        #expect(file.load(now: t0).isEmpty)
    }

    @Test func fileIsOwnerOnly() throws {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        HistoryFile<SiteSample>(url: url).save(["a": [site(0)]])
        let mode = (try FileManager.default.attributesOfItem(atPath: url.path))[.posixPermissions] as? NSNumber
        #expect(mode?.intValue == 0o600)
    }

    @Test @MainActor func siteModelRestoresHistoryFromTheFile() async {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let name = "nobet-histmodel-\(UUID().uuidString)"
        let defaults = TestDefaults.make(name)
        defaults.removePersistentDomain(forName: name)
        let file = HistoryFile<SiteSample>(url: url)
        let first = ServerModel(nobet: NobetModel(), defaults: defaults, prober: StubProber(), now: { t0 }, history: file)
        first.addSite(name: "A", host: "a.com", port: 443)
        await first.checkAll()
        let id = first.sites[0].id
        let second = ServerModel(nobet: NobetModel(), defaults: defaults, prober: StubProber(), now: { t0 }, history: file)
        #expect((second.history[id]?.count ?? 0) >= 1)
    }
}

private struct StubProber: ServerProbing {
    func probe(_ site: ServerSite) async -> ProbeResult {
        ProbeResult(reachable: true, httpStatus: 200, latencyMs: 90, certExpiry: nil, error: nil)
    }
}

struct UptimeStripTests {
    private func sample(_ minutesAgo: Double, up: Bool = true) -> SiteSample {
        SiteSample(date: t0.addingTimeInterval(-minutesAgo * 60), up: up, latencyMs: up ? 50 : nil)
    }

    @Test func thereAreTwentyFourCellsOldestFirst() {
        let cells = UptimeStrip.cells([], now: t0)
        #expect(cells.count == 24)
        #expect(cells.allSatisfy { $0 == nil })
    }

    @Test func eachCellIsTheUptimeOfItsHour() {
        let samples = [sample(10), sample(20, up: false), sample(90)]
        let cells = UptimeStrip.cells(samples, now: t0)
        #expect(cells[23] == 50)
        #expect(cells[22] == 100)
        #expect(cells[21] == nil)
    }

    @Test func boundarySampleBelongsToTheOlderHour() {
        let cells = UptimeStrip.cells([sample(60, up: false)], now: t0)
        #expect(cells[22] == 0)
        #expect(cells[23] == nil)
    }

    @Test func levelsFollowFixedThresholds() {
        #expect(UptimeStrip.level(nil) == .unknown)
        #expect(UptimeStrip.level(100) == .good)
        #expect(UptimeStrip.level(99) == .good)
        #expect(UptimeStrip.level(95) == .degraded)
        #expect(UptimeStrip.level(80) == .down)
    }
}

struct AlertTimelineDetailTests {
    private func event(_ title: String, ago hours: Double, now: Date, kind: AlertEvent.Kind = .started) -> AlertEvent {
        AlertEvent(kind: kind, issue: AlertIssue(key: title, module: "dev", subject: "s", title: title, severity: .info),
                   date: now.addingTimeInterval(-hours * 3600))
    }

    @Test func bucketListsTheTitlesOfIssuesStartedInThatHour() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let events = [event("a", ago: 0.5, now: now), event("b", ago: 0.2, now: now), event("c", ago: 3.5, now: now),
                      event("d", ago: 0.4, now: now, kind: .resolved)]
        #expect(AlertTimeline.titles(events, bucket: 23, now: now) == ["a", "b"])
        #expect(AlertTimeline.titles(events, bucket: 20, now: now) == ["c"])
        #expect(AlertTimeline.titles(events, bucket: 10, now: now).isEmpty)
    }

    @Test func titlesAgreeWithTheHourlyCounts() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let events = (0..<6).map { event("t\($0)", ago: Double($0) * 1.7, now: now) }
        let counts = AlertTimeline.hourlyStarts(events, now: now)
        for index in counts.indices { #expect(AlertTimeline.titles(events, bucket: index, now: now).count == counts[index]) }
    }

    @Test func bucketLabelNamesTheHourAgo() {
        #expect(AlertTimeline.label(bucket: 23) == "Son 1 saat")
        #expect(AlertTimeline.label(bucket: 20) == "4 saat önce")
        #expect(AlertTimeline.label(bucket: 0, hours: 24) == "24 saat önce")
    }
}
