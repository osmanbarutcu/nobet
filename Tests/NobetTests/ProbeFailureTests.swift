import Foundation
import Testing
@testable import Nobet

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func failed(_ failure: ProbeFailure?, error: String = "hata") -> ProbeResult {
    ProbeResult(reachable: false, httpStatus: nil, latencyMs: nil, certExpiry: nil, error: error, failure: failure)
}

struct ProbeFailureTests {
    @Test func urlErrorCodesAreClassifiedByStage() {
        #expect(ProbeFailure.classify(URLError(.cannotFindHost)) == .dns)
        #expect(ProbeFailure.classify(URLError(.dnsLookupFailed)) == .dns)
        #expect(ProbeFailure.classify(URLError(.cannotConnectToHost)) == .connection)
        #expect(ProbeFailure.classify(URLError(.networkConnectionLost)) == .connection)
        #expect(ProbeFailure.classify(URLError(.timedOut)) == .timeout)
        #expect(ProbeFailure.classify(URLError(.notConnectedToInternet)) == .offline)
        #expect(ProbeFailure.classify(URLError(.badURL)) == .other)
        #expect(ProbeFailure.classify(NSError(domain: "x", code: 1)) == .other)
    }

    @Test func dnsFailureHasItsOwnHighIssue() {
        let issues = SiteHealth.issues(for: failed(.dns), now: now)
        #expect(issues.map(\.kind) == [.dnsFailed])
        #expect(issues.first?.severity == .high)
        #expect(ServerIssueKind.dnsFailed.title == "Alan adı çözülemiyor")
    }

    @Test func refusedConnectionHasItsOwnHighIssue() {
        let issues = SiteHealth.issues(for: failed(.connection), now: now)
        #expect(issues.map(\.kind) == [.portClosed])
        #expect(issues.first?.severity == .high)
        #expect(ServerIssueKind.portClosed.title == "Port bağlantısı kurulamıyor")
    }

    @Test func timeoutAndUnknownStayAsDown() {
        #expect(SiteHealth.issues(for: failed(.timeout), now: now).map(\.kind) == [.down])
        #expect(SiteHealth.issues(for: failed(nil), now: now).map(\.kind) == [.down])
        #expect(SiteHealth.issues(for: failed(.other), now: now).map(\.kind) == [.down])
    }

    @Test func ourOwnNetworkBeingOfflineIsNotASiteAlert() {
        // İnternet yoksa her site düşmüş görünür. Bu bir site sorunu değildir, bildirim üretmez.
        let issues = SiteHealth.issues(for: failed(.offline), now: now)
        #expect(issues.allSatisfy { $0.severity == .info })
        #expect(SiteHealth.alertCount(issues) == 0)
    }

    @Test func closedLocalPortIsClassifiedAsConnection() async {
        let site = ServerSite.make(name: "yerel", host: "localhost", port: 9)!
        let result = await NetworkProber(timeout: 3).probe(site)
        #expect(result.failure == .connection)
    }
}
