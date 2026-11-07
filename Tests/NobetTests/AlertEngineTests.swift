import Foundation
import Testing
@testable import Nobet

private func issue(_ key: String, module: String = "servers", title: String = "Sorun", severity: Severity = .high) -> AlertIssue {
    AlertIssue(key: key, module: module, subject: "a.com", title: title, severity: severity)
}

struct AlertEngineTests {
    @Test func newIssueStarts() {
        let result = AlertEngine.diff(previous: [], current: [issue("a")])
        #expect(result.started.map(\.key) == ["a"])
        #expect(result.resolved.isEmpty)
    }

    @Test func existingIssueStaysSilent() {
        let result = AlertEngine.diff(previous: [issue("a")], current: [issue("a")])
        #expect(result.started.isEmpty)
        #expect(result.resolved.isEmpty)
    }

    @Test func goneIssueResolvesWithItsOldTitle() {
        let result = AlertEngine.diff(previous: [issue("a", title: "Disk dolu")], current: [])
        #expect(result.resolved.map(\.title) == ["Disk dolu"])
        #expect(result.started.isEmpty)
    }

    @Test func mixedChangeIsSplitCorrectly() {
        let result = AlertEngine.diff(previous: [issue("a"), issue("b")], current: [issue("b"), issue("c")])
        #expect(result.started.map(\.key) == ["c"])
        #expect(result.resolved.map(\.key) == ["a"])
    }

    @Test func duplicateKeysInOneSnapshotStartOnce() {
        let result = AlertEngine.diff(previous: [], current: [issue("a"), issue("a")])
        #expect(result.started.count == 1)
    }

    @Test func infoSeverityNeverAlerts() {
        let result = AlertEngine.diff(previous: [], current: [issue("a", severity: .info), issue("b", severity: .medium)])
        #expect(result.started.map(\.key) == ["b"])
    }
}

struct QuietHoursTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 7, hour: hour, minute: minute))!
    }

    @Test func windowThatCrossesMidnight() {
        let quiet = QuietHours(startMinute: 23 * 60, endMinute: 8 * 60)
        #expect(quiet.contains(date(23, 30), calendar: calendar))
        #expect(quiet.contains(date(0, 0), calendar: calendar))
        #expect(quiet.contains(date(7, 59), calendar: calendar))
        #expect(!quiet.contains(date(8, 0), calendar: calendar))
        #expect(!quiet.contains(date(12, 0), calendar: calendar))
        #expect(quiet.contains(date(23, 0), calendar: calendar))
    }

    @Test func windowInsideOneDay() {
        let quiet = QuietHours(startMinute: 60, endMinute: 300)
        #expect(quiet.contains(date(2), calendar: calendar))
        #expect(!quiet.contains(date(6), calendar: calendar))
    }

    @Test func equalStartAndEndMeansNeverQuiet() {
        let quiet = QuietHours(startMinute: 600, endMinute: 600)
        #expect(!quiet.contains(date(10), calendar: calendar))
    }
}

struct AlertHistoryTests {
    private func event(_ key: String) -> AlertEvent {
        AlertEvent(kind: .started, issue: issue(key), date: Date(timeIntervalSince1970: 0))
    }

    @Test func newestEventsComeFirst() {
        let result = AlertHistory.appending([event("b"), event("c")], to: [event("a")], limit: 10)
        #expect(result.map(\.issue.key) == ["b", "c", "a"])
    }

    @Test func historyIsCapped() {
        let old = (0..<5).map { event("o\($0)") }
        let result = AlertHistory.appending([event("n1"), event("n2")], to: old, limit: 4)
        #expect(result.count == 4)
        #expect(result.first?.issue.key == "n1")
    }

    @Test func eventsEncodeWithoutDetailText() throws {
        let json = String(decoding: try JSONEncoder().encode(event("a")), as: UTF8.self)
        #expect(!json.contains("detail"))
        let decoded = try JSONDecoder().decode(AlertEvent.self, from: Data(json.utf8))
        #expect(decoded.issue.key == "a")
    }
}

struct AlertExportTests {
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(_ title: String, subject: String = "a.com", kind: AlertEvent.Kind = .started) -> AlertEvent {
        AlertEvent(kind: kind, issue: AlertIssue(key: "k", module: "servers", subject: subject, title: title, severity: .high), date: date)
    }

    @Test func csvHasAHeaderAndOneRowPerEvent() {
        let csv = AlertExport.csv([event("Site kapalı"), event("Site açıldı", kind: .resolved)])
        let lines = csv.split(separator: "\n").map(String.init)
        #expect(lines[0] == "tarih,olay,modül,konu,başlık,önem")
        #expect(lines.count == 3)
        #expect(lines[1].contains("başladı"))
        #expect(lines[2].contains("düzeldi"))
    }

    @Test func csvQuotesCommasQuotesAndNewlines() {
        let csv = AlertExport.csv([event("a, \"b\"\nc")])
        #expect(csv.contains("\"a, \"\"b\"\"\nc\""))
    }

    @Test func csvNeutralizesSpreadsheetFormulas() {
        let csv = AlertExport.csv([event("=HYPERLINK(\"x\")", subject: "+1")])
        #expect(csv.contains("'=HYPERLINK"))
        #expect(csv.contains(",'+1,"))
    }

    @Test func jsonRoundTripsTheFields() throws {
        let data = try #require(AlertExport.json([event("Site kapalı")]).data(using: .utf8))
        let rows = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: String]])
        #expect(rows.count == 1)
        #expect(rows[0]["başlık"] == "Site kapalı")
        #expect(rows[0]["önem"] == "Yüksek")
        #expect(rows[0]["olay"] == "başladı")
    }

    @Test func exportNeverContainsTheAlertKey() {
        let keyed = AlertEvent(kind: .started, issue: AlertIssue(key: "GIZLI-ANAHTAR-123", module: "servers", subject: "s", title: "t", severity: .high), date: date)
        #expect(!AlertExport.csv([keyed]).contains("GIZLI-ANAHTAR"))
        #expect(!AlertExport.json([keyed]).contains("GIZLI-ANAHTAR"))
    }
}
