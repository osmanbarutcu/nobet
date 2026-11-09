import Foundation
import Testing
@testable import Nobet

struct NetworkScanTests {
    private let sample = """
    p501
    cSafari
    n192.168.1.20:50111->93.184.216.34:443
    n192.168.1.20:50112->93.184.216.34:443
    p612
    cGoogle\\x20Chrome
    n[2001:db8::1]:50300->[2001:db8:ffff::5]:443
    n127.0.0.1:50400->127.0.0.1:5432
    p700
    cnode
    n192.168.1.20:50500->10.0.0.8:22
    n*:8080
    """

    @Test func parsesIPv4ConnectionsWithProcessAndPorts() {
        let connections = NetworkScan.parse(sample)
        let safari = connections.filter { $0.pid == 501 }
        #expect(safari.count == 2)
        #expect(safari.first?.process == "Safari")
        #expect(safari.first?.remoteHost == "93.184.216.34")
        #expect(safari.first?.remotePort == 443)
        #expect(safari.contains { $0.localPort == 50112 })
    }

    @Test func parsesIPv6AndRestoresEscapedSpacesInProcessNames() {
        let chrome = NetworkScan.parse(sample).first { $0.pid == 612 && $0.remoteHost == "2001:db8:ffff::5" }
        #expect(chrome?.process == "Google Chrome")
        #expect(chrome?.localPort == 50300)
        #expect(chrome?.remotePort == 443)
    }

    @Test func skipsLinesWithoutAnArrow() {
        let connections = NetworkScan.parse(sample)
        #expect(connections.allSatisfy { $0.localPort != 8080 })
    }

    @Test func dropsEmptyAndBrokenInput() {
        #expect(NetworkScan.parse("").isEmpty)
        #expect(NetworkScan.parse("p1\ncx\nnnot-an-address").isEmpty)
        #expect(NetworkScan.parse("p1\ncx\nn1.2.3.4:5->host:abc").isEmpty)
    }

    @Test func mergesIdenticalRecords() {
        let twice = "p9\ncfoo\nn10.0.0.1:1000->8.8.8.8:53\nn10.0.0.1:1000->8.8.8.8:53"
        #expect(NetworkScan.parse(twice).count == 1)
    }

    @Test func classifiesReach() {
        let byRemote = Dictionary(NetworkScan.parse(sample).map { ($0.remoteHost, $0.reach) }, uniquingKeysWith: { first, _ in first })
        #expect(byRemote["93.184.216.34"] == .external)
        #expect(byRemote["2001:db8:ffff::5"] == .external)
        #expect(byRemote["127.0.0.1"] == .loopback)
        #expect(byRemote["10.0.0.8"] == .local)
    }

    @Test func reachCoversPrivateAndLinkLocalRanges() {
        #expect(NetworkConnection.reach(of: "192.168.0.1") == .local)
        #expect(NetworkConnection.reach(of: "172.16.5.5") == .local)
        #expect(NetworkConnection.reach(of: "172.31.255.1") == .local)
        #expect(NetworkConnection.reach(of: "172.32.0.1") == .external)
        #expect(NetworkConnection.reach(of: "169.254.1.1") == .local)
        #expect(NetworkConnection.reach(of: "fe80::1") == .local)
        #expect(NetworkConnection.reach(of: "fd12:3456::1") == .local)
        #expect(NetworkConnection.reach(of: "::1") == .loopback)
        #expect(NetworkConnection.reach(of: "127.5.5.5") == .loopback)
        #expect(NetworkConnection.reach(of: "8.8.8.8") == .external)
    }

    @Test func sortsExternalFirstAndLoopbackLast() {
        let sorted = NetworkScan.parse(sample)
        #expect(sorted.first?.reach == .external)
        #expect(sorted.last?.reach == .loopback)
    }

    @Test func detailShowsNoThousandsSeparator() {
        let connection = NetworkScan.parse("p8001\ncapp\nn10.0.0.1:50000->1.2.3.4:8443")[0]
        #expect(connection.detail == "PID 8001 · :50000 → 1.2.3.4:8443")
    }
}
