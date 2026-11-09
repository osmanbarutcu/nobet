import Foundation
import Testing
@testable import Nobet

struct NetworkRulesTests {
    private func listener(
        process: String = "svc", pid: Int = 10, port: Int = 9000, scope: ListeningPort.Scope = .local,
        path: String? = "/opt/x/svc", signature: SignatureStatus = .developer,
        suspicious: Bool = false, project: Bool = false
    ) -> NetworkListener {
        let address = scope == .all ? "*" : "127.0.0.1"
        return NetworkListener(
            port: ListeningPort(pid: pid, process: process, address: address, port: port, scope: scope),
            identity: ProcessIdentity(path: path, signature: signature, suspiciousLocation: suspicious),
            isProjectPort: project)
    }

    private func risks(_ item: NetworkListener, new: Bool = false, trusted: Bool = false) -> [NetworkRisk] {
        NetworkRules.risks(for: item, newKeys: new ? [item.digest] : [], trusted: trusted ? [item.digest] : [])
    }

    @Test func quietLocalDeveloperSignedListenerHasNoRisk() {
        #expect(risks(listener()).isEmpty)
    }

    @Test func newListenerIsReportedOnlyWhenItsKeyIsNew() {
        #expect(risks(listener(), new: true) == [.newListener])
        #expect(risks(listener(), new: false).isEmpty)
    }

    @Test func appleSignedExposedPortIsQuiet() {
        #expect(risks(listener(scope: .all, signature: .apple)).isEmpty)
    }

    @Test(arguments: [SignatureStatus.developer, .adHoc, .unknown])
    func exposedPortOfNonAppleSignedProcessIsMedium(signature: SignatureStatus) {
        #expect(risks(listener(scope: .all, signature: signature)) == [.exposedSystemPort])
    }

    @Test(arguments: [SignatureStatus.unsigned, .invalid])
    func exposedUnsignedProcessGetsTheSpecificRuleOnly(signature: SignatureStatus) {
        #expect(risks(listener(scope: .all, signature: signature)) == [.unsignedExposed])
    }

    @Test func unsignedButLocalOnlyIsQuiet() {
        #expect(risks(listener(scope: .local, signature: .unsigned)).isEmpty)
        #expect(risks(listener(scope: .local, signature: .adHoc)).isEmpty)
    }

    @Test func adHocSignatureAloneNeverAlerts() {
        #expect(risks(listener(scope: .interface, signature: .adHoc)).isEmpty)
    }

    @Test func suspiciousLocationIsHighEvenWhenLocalOnly() {
        let item = listener(scope: .local, path: "/tmp/agent", suspicious: true)
        #expect(risks(item) == [.suspiciousLocation])
        #expect(NetworkRisk.suspiciousLocation.severity == .high)
    }

    @Test func severitiesAndTitles() {
        #expect(NetworkRisk.newListener.severity == .medium)
        #expect(NetworkRisk.exposedSystemPort.severity == .medium)
        #expect(NetworkRisk.unsignedExposed.severity == .medium)
        #expect(NetworkRisk.newListener.title == "Yeni dinleyen süreç")
        #expect(NetworkRisk.exposedSystemPort.title == "Sistem portu tüm ağa açık")
        #expect(NetworkRisk.suspiciousLocation.title == "Şüpheli klasörden çalışıyor")
        #expect(NetworkRisk.unsignedExposed.title == "İmzasız süreç tüm ağa açık")
    }

    @Test func projectPortsNeverAlertHere() {
        let item = listener(scope: .all, signature: .unsigned, suspicious: true, project: true)
        #expect(risks(item, new: true).isEmpty)
    }

    @Test func trustedListenerIsSilentForEveryRule() {
        let item = listener(scope: .all, path: "/tmp/agent", signature: .unsigned, suspicious: true)
        #expect(risks(item, new: true, trusted: true).isEmpty)
    }

    @Test func severalRulesCanFireTogether() {
        let item = listener(scope: .all, path: "/tmp/agent", signature: .unsigned, suspicious: true)
        #expect(Set(risks(item, new: true)) == [.newListener, .suspiciousLocation, .unsignedExposed])
    }

    @Test func alertIssueCarriesNoPathAndNoPid() {
        let item = listener(process: "agent", pid: 4242, scope: .all, path: "/Users/ornek/secret/agent", signature: .unsigned)
        let issue = NetworkRules.alertIssues([item], newKeys: [], trusted: [])[0]
        #expect(issue.module == "net")
        #expect(issue.subject == "agent")
        #expect(!issue.key.contains("/Users"))
        #expect(!issue.key.contains("4242"))
        #expect(!issue.subject.contains("/"))
    }

    @Test func issueKeyIsStableAcrossRestarts() {
        let before = NetworkRules.alertIssues([listener(pid: 10, scope: .all)], newKeys: [], trusted: [])
        let after = NetworkRules.alertIssues([listener(pid: 99, port: 9100, scope: .all)], newKeys: [], trusted: [])
        #expect(before.map(\.key) == after.map(\.key))
    }

    @Test func sameProcessWithTwoPortsGivesOneIssuePerRule() {
        let issues = NetworkRules.alertIssues(
            [listener(port: 9000, scope: .all), listener(port: 9001, scope: .all)], newKeys: [], trusted: [])
        #expect(issues.count == 1)
    }

    @Test func keySeparatesScopesOfTheSameProcess() {
        #expect(listener(scope: .local).digest != listener(scope: .all).digest)
    }

    @Test func keyFallsBackToProcessNameWithoutPath() {
        let named = listener(process: "daemon", path: nil)
        let other = listener(process: "other", path: nil)
        #expect(named.digest != other.digest)
    }

    @Test func displayOrderPutsRiskyFirstThenSystemThenProjectPorts() {
        let risky = listener(process: "r", port: 9003, scope: .all, path: "/tmp/r", suspicious: true)
        let quiet = listener(process: "q", port: 9001)
        let project = listener(process: "p", port: 9000, project: true)
        let medium = listener(process: "m", port: 9002, scope: .all)
        let ordered = NetworkRules.displayOrder([project, quiet, medium, risky], newKeys: [], trusted: [])
        #expect(ordered.map(\.port.process) == ["r", "m", "q", "p"])
    }

    @Test func displayOrderKeepsPortOrderInsideTheSameGroup() {
        let high = listener(process: "b", pid: 2, port: 9100)
        let low = listener(process: "a", pid: 1, port: 9050)
        let ordered = NetworkRules.displayOrder([high, low], newKeys: [], trusted: [])
        #expect(ordered.map(\.port.port) == [9050, 9100])
    }

    @Test func issuesAreSortedBySeverityThenSubject() {
        let issues = NetworkRules.alertIssues(
            [listener(process: "b", scope: .all), listener(process: "a", path: "/tmp/a", suspicious: true)],
            newKeys: [], trusted: [])
        #expect(issues.map(\.subject) == ["a", "b"])
        #expect(issues.first?.severity == .high)
    }
}
