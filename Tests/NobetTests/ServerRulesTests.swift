import Foundation
import Testing
@testable import Nobet

struct ServerSiteTests {
    @Test func validHostAndPortAreAccepted() {
        #expect(ServerSite.make(name: "Ana site", host: "example.com", port: 443) != nil)
        #expect(ServerSite.make(name: "", host: "10.0.0.5", port: 8080) != nil)
    }

    @Test func schemePathAndSpacesInHostAreRefused() {
        #expect(ServerSite.make(name: "x", host: "https://example.com", port: 443) == nil)
        #expect(ServerSite.make(name: "x", host: "example.com/path", port: 443) == nil)
        #expect(ServerSite.make(name: "x", host: "exa mple.com", port: 443) == nil)
        #expect(ServerSite.make(name: "x", host: "", port: 443) == nil)
        #expect(ServerSite.make(name: "x", host: "-bad.com", port: 443) == nil)
    }

    @Test func portOutsideRangeIsRefused() {
        #expect(ServerSite.make(name: "x", host: "example.com", port: 0) == nil)
        #expect(ServerSite.make(name: "x", host: "example.com", port: 70000) == nil)
    }

    @Test func emptyNameFallsBackToHost() {
        #expect(ServerSite.make(name: "  ", host: "example.com", port: 443)?.name == "example.com")
    }

    @Test func hostIsLowercasedAndTrimmed() {
        #expect(ServerSite.make(name: "x", host: " Example.COM ", port: 443)?.host == "example.com")
    }

    @Test func httpsUrlOmitsDefaultPort() {
        let site = ServerSite.make(name: "x", host: "example.com", port: 443)!
        #expect(site.url?.absoluteString == "https://example.com/")
        let custom = ServerSite.make(name: "x", host: "example.com", port: 8443)!
        #expect(custom.url?.absoluteString == "https://example.com:8443/")
    }
}

struct SiteHealthTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func days(_ count: Double) -> Date { now.addingTimeInterval(count * 86_400) }

    private func result(reachable: Bool = true, status: Int? = 200, latency: Int? = 120, expiry: Date? = nil, error: String? = nil) -> ProbeResult {
        ProbeResult(reachable: reachable, httpStatus: status, latencyMs: latency, certExpiry: expiry, error: error)
    }

    @Test func healthySiteHasNoIssues() {
        #expect(SiteHealth.issues(for: result(expiry: days(60)), now: now).isEmpty)
    }

    @Test func unreachableSiteIsHigh() {
        let issues = SiteHealth.issues(for: result(reachable: false, status: nil, latency: nil, error: "zaman aşımı"), now: now)
        #expect(issues.map(\.kind) == [.down])
        #expect(issues.first?.severity == .high)
        #expect(issues.first?.detail.contains("zaman aşımı") == true)
    }

    @Test func serverErrorIsHighAndClientErrorIsMedium() {
        #expect(SiteHealth.issues(for: result(status: 503), now: now).first?.severity == .high)
        #expect(SiteHealth.issues(for: result(status: 404), now: now).first?.severity == .medium)
    }

    @Test func redirectsAndSuccessAreFine() {
        #expect(SiteHealth.issues(for: result(status: 301), now: now).isEmpty)
        #expect(SiteHealth.issues(for: result(status: 204), now: now).isEmpty)
    }

    @Test func expiredCertificateIsHigh() {
        let issues = SiteHealth.issues(for: result(expiry: days(-1)), now: now)
        #expect(issues.map(\.kind) == [.certExpired])
        #expect(issues.first?.severity == .high)
    }

    @Test func certificateExpiringWithin14DaysIsMedium() {
        let issues = SiteHealth.issues(for: result(expiry: days(10)), now: now)
        #expect(issues.map(\.kind) == [.certExpiring])
        #expect(issues.first?.severity == .medium)
        #expect(SiteHealth.issues(for: result(expiry: days(15)), now: now).isEmpty)
    }

    @Test func slowResponseIsInfoAbove2000ms() {
        let issues = SiteHealth.issues(for: result(latency: 2500), now: now)
        #expect(issues.map(\.kind) == [.slow])
        #expect(issues.first?.severity == .info)
        #expect(SiteHealth.issues(for: result(latency: 2000), now: now).isEmpty)
    }

    @Test func untrustedCertificateIsHighAndNotReportedAsDown() {
        var untrusted = result(status: nil, latency: nil, expiry: days(400))
        untrusted.certError = "SSL sertifikası doğrulanamadı."
        let issues = SiteHealth.issues(for: untrusted, now: now)
        #expect(issues.map(\.kind) == [.certInvalid])
        #expect(issues.first?.severity == .high)
        #expect(issues.first?.detail.contains("doğrulanamadı") == true)
    }

    @Test func alertCountIgnoresInfo() {
        let slow = SiteHealth.issues(for: result(latency: 3000), now: now)
        #expect(SiteHealth.alertCount(slow) == 0)
        let down = SiteHealth.issues(for: result(reachable: false, status: nil, latency: nil), now: now)
        #expect(SiteHealth.alertCount(down) == 1)
    }
}

struct CertCalendarTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func site(_ id: String) -> ServerSite { ServerSite(id: id, name: id, host: "\(id).com", port: 443) }

    private func result(daysLeft: Double?) -> ProbeResult {
        ProbeResult(reachable: true, httpStatus: 200, latencyMs: 50,
                    certExpiry: daysLeft.map { Date(timeIntervalSince1970: 1_800_000_000 + $0 * 86_400) }, error: nil)
    }

    @Test func entriesAreSortedByDaysLeft() {
        let entries = CertCalendar.entries(sites: [site("a"), site("b"), site("c")],
                                           results: ["a": result(daysLeft: 60), "b": result(daysLeft: 5), "c": result(daysLeft: 20)], now: now)
        #expect(entries.map(\.site.id) == ["b", "c", "a"])
        #expect(entries.map(\.daysLeft) == [5, 20, 60])
    }

    @Test func sitesWithoutACertificateAreLeftOut() {
        let entries = CertCalendar.entries(sites: [site("a"), site("b")], results: ["a": result(daysLeft: nil)], now: now)
        #expect(entries.isEmpty)
    }

    @Test func levelFollowsTheWarningWindow() {
        let entries = CertCalendar.entries(sites: [site("a"), site("b"), site("c")],
                                           results: ["a": result(daysLeft: 3), "b": result(daysLeft: 20), "c": result(daysLeft: 90)], now: now)
        #expect(entries.map(\.level) == [.critical, .warning, .ok])
    }

    @Test func expiredCertificateShowsNegativeDaysAndIsCritical() {
        let entries = CertCalendar.entries(sites: [site("a")], results: ["a": result(daysLeft: -2)], now: now)
        #expect(entries[0].daysLeft == -2)
        #expect(entries[0].level == .critical)
    }
}
