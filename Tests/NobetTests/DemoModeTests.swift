import Foundation
import Testing
@testable import Nobet

@Suite("Demo kipi")
struct DemoModeTests {
    @Test("Ortam değişkeni ve paket kimliği yoksa kip kapalıdır")
    func offByDefault() {
        #expect(DemoMode.isOn == false)
    }

    @Test("Ağ demo verisi yalnızca belgelendirme adresleri kullanır")
    func networkFixturesUseDocumentationAddresses() {
        let hosts = (DemoMode.networkSnapshot(includeNew: true).connections ?? []).map(\.remoteHost)
        #expect(!hosts.isEmpty)
        let allowed = ["192.0.2.", "198.51.100.", "203.0.113.", "10.", "127."]
        #expect(hosts.allSatisfy { host in allowed.contains { host.hasPrefix($0) } })
    }

    @Test("Ağ demo verisi öğrenmeden sonra yeni ve riskli dinleyici gösterir")
    func networkFixturesShowRisksAfterLearning() {
        let base = DemoMode.networkSnapshot(includeNew: false)
        let full = DemoMode.networkSnapshot(includeNew: true)
        #expect(full.listeners.count > base.listeners.count)
        let learned = NetworkBaseline.empty.observing(Set(base.listeners.filter { !$0.isProjectPort }.map(\.digest))).baseline
        let newKeys = learned.observing(Set(full.listeners.filter { !$0.isProjectPort }.map(\.digest))).newKeys
        let issues = NetworkRules.alertIssues(full.listeners, newKeys: newKeys, trusted: [])
        #expect(issues.contains { $0.severity == .high })
        #expect(issues.contains { $0.title == "Yeni dinleyen süreç" })
        #expect(NetworkRules.alertIssues(base.listeners, newKeys: [], trusted: []).allSatisfy { $0.severity != .high })
    }

    @Test("Ağ demo verisi gerçek bir kullanıcı klasörü içermez")
    func networkFixturesLeakNoRealPaths() {
        let paths = DemoMode.networkSnapshot(includeNew: true).listeners.compactMap(\.identity.path)
        #expect(!paths.contains { $0.hasPrefix(NSHomeDirectory()) })
    }

    @Test("Örnek profil ve siteler geçerlidir ve gerçek alan adı içermez")
    func fixturesAreValidAndFake() {
        #expect(DemoMode.profiles.count == 3)
        #expect(DemoMode.sites.count == 5)
        let hosts = DemoMode.profiles.map(\.host) + DemoMode.sites.map(\.host)
        #expect(hosts.allSatisfy { host in ["example.com", "example.org", "example.net", "example.dev", "example.io"].contains { host.hasSuffix($0) } })
    }

    @Test("Kip kapalıyken prepare ayar yazmaz")
    @MainActor
    func prepareIsNoopWhenOff() {
        let suite = UserDefaults(suiteName: "demo-test-\(UUID().uuidString)")!
        DemoMode.prepare(defaults: suite)
        #expect(suite.data(forKey: RemoteModel.profilesKey) == nil)
        #expect(suite.data(forKey: ServerModel.sitesKey) == nil)
    }

    @Test("Üretilen geçmiş 24 saati kapsar ve her seferinde aynıdır")
    func historyIsDeterministic() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = DemoMode.metricSamples(for: "demo-db", now: now)
        #expect(first == DemoMode.metricSamples(for: "demo-db", now: now))
        #expect(first.count == 288)
        #expect(now.timeIntervalSince(first[0].date) <= 24 * 3600)
        #expect(DemoMode.siteSamples(for: "demo-site-api", now: now).contains { !$0.up })
    }

    @Test("Sahte toplayıcı üç sunucuya üç farklı durum verir")
    func collectorVariesPerProfile() async {
        let collector = DemoCollector()
        var disks: [Int] = []
        for profile in DemoMode.profiles {
            guard case .success(let metrics) = await collector.collect(profile, password: nil) else { Issue.record("beklenmeyen hata"); return }
            disks.append(metrics.disks.first?.usedPercent ?? 0)
        }
        #expect(Set(disks).count == 3)
    }

    @Test("Sahte yoklayıcı hem sağlıklı hem hatalı site verir")
    func proberVaries() async {
        let prober = DemoProber()
        var statuses: Set<Int> = []
        for site in DemoMode.sites { statuses.insert(await prober.probe(site).httpStatus ?? 0) }
        #expect(statuses == [200, 503])
    }
}
