import Foundation
import Testing
@testable import Nobet

struct LockfileParserTests {
    @Test func npmLockV3ReadsEveryInstalledPackage() {
        let json = """
        {"lockfileVersion":3,"packages":{
          "":{"name":"app","version":"1.0.0"},
          "node_modules/a":{"version":"1.0.0"},
          "node_modules/@s/b":{"version":"2.0.0"},
          "node_modules/a/node_modules/c":{"version":"3.0.0"},
          "node_modules/linked":{"link":true}}}
        """
        let items = LockfileParser.npm(Data(json.utf8))
        #expect(items.map(\.name) == ["@s/b", "a", "c"])
        #expect(items.allSatisfy { $0.ecosystem == .npm })
    }

    @Test func npmLockV1ReadsNestedDependencies() {
        let json = #"{"lockfileVersion":1,"dependencies":{"a":{"version":"1.0.0","dependencies":{"b":{"version":"2.0.0"}}}}}"#
        #expect(LockfileParser.npm(Data(json.utf8)).map(\.name) == ["a", "b"])
    }

    @Test func brokenNpmLockGivesNothing() {
        #expect(LockfileParser.npm(Data("bozuk".utf8)).isEmpty)
    }

    @Test func composerLockReadsBothPackageLists() {
        let json = """
        {"packages":[{"name":"laravel/framework","version":"v12.1.0"}],
         "packages-dev":[{"name":"pestphp/pest","version":"3.0.0"}]}
        """
        let items = LockfileParser.composer(Data(json.utf8))
        #expect(items.map(\.name) == ["laravel/framework", "pestphp/pest"])
        #expect(items.map(\.version) == ["12.1.0", "3.0.0"])
        #expect(items.allSatisfy { $0.ecosystem == .composer })
    }

    @Test func swiftResolvedReadsPinsWithAVersion() {
        let json = """
        {"version":2,"pins":[
          {"identity":"x","location":"https://github.com/a/x.git","state":{"version":"1.2.3","revision":"abc"}},
          {"identity":"y","location":"https://github.com/a/y.git","state":{"branch":"main","revision":"def"}}]}
        """
        let items = LockfileParser.swiftResolved(Data(json.utf8))
        #expect(items.count == 1)
        #expect(items[0].name == "github.com/a/x")
        #expect(items[0].version == "1.2.3")
    }

    @Test func requirementsReadsPinnedLinesOnly() {
        let text = """
        # yorum
        requests==2.31.0
        Django[argon2]==4.2 ; python_version >= "3.8"
        numpy>=1.0
        -r other.txt
        flask == 3.0.0
        """
        let items = LockfileParser.requirements(text)
        #expect(items.map(\.name) == ["django", "flask", "requests"])
        #expect(items.map(\.version) == ["4.2", "3.0.0", "2.31.0"])
    }

    @Test func duplicatesCollapseAndResultIsSorted() {
        let json = #"{"packages":{"node_modules/b":{"version":"1"},"node_modules/a":{"version":"1"},"x/node_modules/a":{"version":"1"}}}"#
        #expect(LockfileParser.npm(Data(json.utf8)).map(\.name) == ["a", "b"])
    }
}

struct CycloneDXTests {
    private let items = [
        SBOMComponent(ecosystem: .npm, name: "@s/b", version: "2.0.0"),
        SBOMComponent(ecosystem: .composer, name: "laravel/framework", version: "12.1.0"),
        SBOMComponent(ecosystem: .pypi, name: "requests", version: "2.31.0"),
        SBOMComponent(ecosystem: .swift, name: "github.com/a/x", version: "1.0.0"),
    ]

    @Test func purlFollowsEachEcosystemsRules() {
        #expect(items.map(\.purl) == [
            "pkg:npm/%40s/b@2.0.0", "pkg:composer/laravel/framework@12.1.0", "pkg:pypi/requests@2.31.0", "pkg:swift/github.com/a/x@1.0.0",
        ])
    }

    @Test func documentHasTheRequiredFields() throws {
        let data = try #require(CycloneDX.json(items, date: Date(timeIntervalSince1970: 1_800_000_000)).data(using: .utf8))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(root["bomFormat"] as? String == "CycloneDX")
        #expect(root["specVersion"] as? String == "1.5")
        let components = try #require(root["components"] as? [[String: Any]])
        #expect(components.count == 4)
        #expect(components[0]["type"] as? String == "library")
        #expect(components[0]["purl"] as? String == "pkg:npm/%40s/b@2.0.0")
        #expect(components[0]["version"] as? String == "2.0.0")
    }

    @Test func documentNamesNoPathsOrHosts() {
        let text = CycloneDX.json(items, date: Date())
        #expect(!text.contains("/Users/"))
        #expect(!text.contains("/Volumes/"))
    }
}

struct OSVTests {
    private struct Lookup: VulnLookup {
        let table: [String: [String]]
        func lookup(_ components: [SBOMComponent]) async -> [SBOMComponent: [String]]? {
            var result: [SBOMComponent: [String]] = [:]
            for item in components { if let ids = table[item.name] { result[item] = ids } }
            return result
        }
    }

    @Test func requestListsOnlyEcosystemsOsvKnows() throws {
        let items = [
            SBOMComponent(ecosystem: .npm, name: "a", version: "1"),
            SBOMComponent(ecosystem: .composer, name: "v/p", version: "2"),
            SBOMComponent(ecosystem: .pypi, name: "r", version: "3"),
            SBOMComponent(ecosystem: .swift, name: "github.com/a/x", version: "4"),
        ]
        let body = OSVClient.requestBody(for: OSVClient.queryable(items))
        let root = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let queries = try #require(root["queries"] as? [[String: Any]])
        #expect(queries.count == 3)
        let ecosystems = queries.compactMap { ($0["package"] as? [String: String])?["ecosystem"] }
        #expect(ecosystems == ["npm", "Packagist", "PyPI"])
    }

    @Test func responseIsMatchedByPosition() {
        let items = [SBOMComponent(ecosystem: .npm, name: "a", version: "1"), SBOMComponent(ecosystem: .npm, name: "b", version: "1")]
        let json = #"{"results":[{"vulns":[{"id":"GHSA-1"},{"id":"CVE-2"}]},{}]}"#
        let map = OSVClient.parse(Data(json.utf8), for: items)
        #expect(map?[items[0]] == ["GHSA-1", "CVE-2"])
        #expect(map?[items[1]] == nil)
    }

    @Test func brokenResponseIsNil() {
        #expect(OSVClient.parse(Data("bozuk".utf8), for: []) == nil)
    }

    @Test func batchesAreCappedAtOneThousand() {
        let many = (0..<2300).map { SBOMComponent(ecosystem: .npm, name: "p\($0)", version: "1") }
        #expect(OSVClient.batches(many).map(\.count) == [1000, 1000, 300])
    }

    @Test @MainActor func switchedOffByDefaultAndNeverAsksOsv() async {
        let name = "nobet-sbom-test-\(UUID().uuidString)"
        let defaults = TestDefaults.make(name)
        defaults.removePersistentDomain(forName: name)
        let model = SBOMModel(defaults: defaults, lookup: Lookup(table: ["a": ["CVE-1"]]))
        await model.apply(components: [SBOMComponent(ecosystem: .npm, name: "a", version: "1")])
        #expect(model.components.count == 1)
        #expect(model.vulnerabilities.isEmpty)
        #expect(!model.lookupEnabled)
    }

    @Test @MainActor func whenEnabledVulnerableComponentsBecomeMediumIssues() async {
        let name = "nobet-sbom-test-\(UUID().uuidString)"
        let defaults = TestDefaults.make(name)
        defaults.removePersistentDomain(forName: name)
        defaults.set(true, forKey: SBOMModel.lookupKey)
        let model = SBOMModel(defaults: defaults, lookup: Lookup(table: ["a": ["CVE-1", "CVE-2"]]))
        let a = SBOMComponent(ecosystem: .npm, name: "a", version: "1")
        await model.apply(components: [a, SBOMComponent(ecosystem: .npm, name: "b", version: "1")])
        #expect(model.vulnerabilities[a] == ["CVE-1", "CVE-2"])
        let issues = SBOMModel.alertIssues(model.vulnerabilities)
        #expect(issues.count == 1)
        #expect(issues[0].severity == .medium)
        #expect(issues[0].module == "sbom")
        #expect(issues[0].title == "Açığı olan bağımlılık")
        #expect(issues[0].subject == "a 1")
    }
}

struct SBOMScannerTests {
    private func tempRoot() -> String {
        let path = NSTemporaryDirectory() + "nobet-sbom-\(UUID().uuidString)"
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }

    private func write(_ root: String, _ relative: String, _ content: String) {
        let path = root + "/" + relative
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: path, contents: Data(content.utf8))
    }

    @Test func findsLockfilesAndSkipsDependencyFolders() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        write(root, "app/package-lock.json", #"{"packages":{"node_modules/a":{"version":"1.0.0"}}}"#)
        write(root, "app/node_modules/x/package-lock.json", #"{"packages":{"node_modules/zzz":{"version":"9"}}}"#)
        write(root, "api/composer.lock", #"{"packages":[{"name":"v/p","version":"1.0.0"}]}"#)
        write(root, "py/requirements.txt", "requests==2.0.0\n")
        let found = SBOMScanner.scan(roots: [root])
        #expect(Set(found.map(\.name)) == ["a", "v/p", "requests"])
    }

    @Test func oversizedLockfileIsSkipped() {
        let root = tempRoot()
        defer { try? FileManager.default.removeItem(atPath: root) }
        write(root, "package-lock.json", String(repeating: " ", count: SBOMScanner.maxFileBytes + 1))
        #expect(SBOMScanner.scan(roots: [root]).isEmpty)
    }
}

struct SBOMFilterTests {
    private let a = SBOMComponent(ecosystem: .npm, name: "left-pad", version: "1.0.0")
    private let b = SBOMComponent(ecosystem: .composer, name: "laravel/framework", version: "12.0.0")
    private let c = SBOMComponent(ecosystem: .pypi, name: "requests", version: "2.0.0")

    @Test func emptyFilterKeepsEverything() {
        let filter = SBOMFilter()
        #expect(!filter.isActive)
        #expect(filter.apply([a, b, c], vulnerabilities: [:]) == [a, b, c])
    }

    @Test func ecosystemFilterKeepsTheChosenOnes() {
        var filter = SBOMFilter()
        filter.ecosystems = [.npm, .pypi]
        #expect(filter.apply([a, b, c], vulnerabilities: [:]) == [a, c])
    }

    @Test func textMatchesNameOrVersionIgnoringCase() {
        var filter = SBOMFilter()
        filter.text = "LARAVEL"
        #expect(filter.apply([a, b, c], vulnerabilities: [:]) == [b])
        filter.text = "1.0.0"
        #expect(filter.apply([a, b, c], vulnerabilities: [:]) == [a])
    }

    @Test func onlyVulnerableKeepsComponentsWithAdvisories() {
        var filter = SBOMFilter()
        filter.onlyVulnerable = true
        #expect(filter.apply([a, b, c], vulnerabilities: [b: ["CVE-1"]]) == [b])
    }

    @Test func chipsDescribeEveryActiveDimension() {
        var filter = SBOMFilter()
        filter.ecosystems = [.npm]
        filter.text = "pad"
        filter.onlyVulnerable = true
        #expect(filter.chips.map(\.title) == ["Ekosistem: npm", "Ara: pad", "Yalnızca açığı olanlar"])
        #expect(filter.removing(.text).text.isEmpty)
        #expect(!filter.cleared().isActive)
    }
}

struct OSVDetailTests {
    private let advisory = """
    {"id":"GHSA-1","database_specific":{"severity":"HIGH"},
     "affected":[
       {"package":{"name":"a","ecosystem":"npm"},"ranges":[{"type":"SEMVER","events":[{"introduced":"0"},{"fixed":"1.2.3"}]}]},
       {"package":{"name":"other","ecosystem":"npm"},"ranges":[{"events":[{"fixed":"9.9"}]}]}]}
    """

    @Test func advisoryGivesRatingAndFixPerPackage() throws {
        let detail = try #require(OSVClient.parseDetail(Data(advisory.utf8)))
        #expect(detail.id == "GHSA-1")
        #expect(detail.rating == .high)
        #expect(detail.fixedVersions(for: "a") == ["1.2.3"])
        #expect(detail.fixedVersions(for: "other") == ["9.9"])
        #expect(detail.fixedVersions(for: "yok").isEmpty)
    }

    @Test func missingSeverityIsUnknownAndBrokenJsonIsNil() throws {
        let detail = try #require(OSVClient.parseDetail(Data(#"{"id":"CVE-1"}"#.utf8)))
        #expect(detail.rating == .unknown)
        #expect(OSVClient.parseDetail(Data("bozuk".utf8)) == nil)
    }

    @Test func ratingNamesMapToAlertSeverity() {
        #expect(VulnDetail.Rating(osv: "CRITICAL") == .critical)
        #expect(VulnDetail.Rating(osv: "moderate") == .moderate)
        #expect(VulnDetail.Rating.critical.alertSeverity == .high)
        #expect(VulnDetail.Rating.high.alertSeverity == .high)
        #expect(VulnDetail.Rating.moderate.alertSeverity == .medium)
        #expect(VulnDetail.Rating.unknown.alertSeverity == .medium)
    }

    @Test func detailRequestsAreCapped() {
        let ids = (0..<120).map { "GHSA-\($0)" }
        #expect(OSVClient.detailTargets(ids + ids).count == OSVClient.detailLimit)
    }
}

struct SBOMWatchTests {
    private final class Stub: VulnLookup, @unchecked Sendable {
        var table: [String: [String]] = [:]
        var detailTable: [String: VulnDetail] = [:]
        var fail = false
        var calls = 0
        func lookup(_ components: [SBOMComponent]) async -> [SBOMComponent: [String]]? {
            calls += 1
            if fail { return nil }
            var result: [SBOMComponent: [String]] = [:]
            for item in components { if let ids = table[item.name] { result[item] = ids } }
            return result
        }
        func details(_ ids: [String]) async -> [String: VulnDetail] { detailTable.filter { ids.contains($0.key) } }
    }

    private static let a = SBOMComponent(ecosystem: .npm, name: "a", version: "1")
    private static let b = SBOMComponent(ecosystem: .npm, name: "b", version: "1")

    @MainActor private func make(_ stub: Stub, enabled: Bool = true) -> (SBOMModel, UserDefaults) {
        let name = "nobet-sbom-watch-\(UUID().uuidString)"
        let defaults = TestDefaults.make(name)
        defaults.removePersistentDomain(forName: name)
        defaults.set(enabled, forKey: SBOMModel.lookupKey)
        return (SBOMModel(defaults: defaults, lookup: stub), defaults)
    }

    @Test @MainActor func firstScanLearnsSilentlyThenOnlyNewAdvisoriesAreMarked() async {
        let stub = Stub()
        stub.table = ["a": ["CVE-1"]]
        let (model, _) = make(stub)
        await model.apply(components: [Self.a, Self.b])
        #expect(model.newlyVulnerable.isEmpty)

        stub.table = ["a": ["CVE-1"], "b": ["CVE-2"]]
        await model.apply(components: [Self.a, Self.b])
        #expect(model.newlyVulnerable == [Self.b])

        await model.apply(components: [Self.a, Self.b])
        #expect(model.newlyVulnerable.isEmpty)
    }

    @Test @MainActor func failedLookupKeepsKnownSetSoNothingIsFalselyNew() async {
        let stub = Stub()
        stub.table = ["a": ["CVE-1"]]
        let (model, _) = make(stub)
        await model.apply(components: [Self.a])
        stub.fail = true
        await model.apply(components: [Self.a])
        stub.fail = false
        await model.apply(components: [Self.a])
        #expect(model.newlyVulnerable.isEmpty)
    }

    @Test @MainActor func knownSetStoresDigestsOnly() async {
        let stub = Stub()
        stub.table = ["secret-internal-pkg": ["CVE-1"]]
        let (model, defaults) = make(stub)
        await model.apply(components: [SBOMComponent(ecosystem: .npm, name: "secret-internal-pkg", version: "7.7.7")])
        let stored = defaults.stringArray(forKey: SBOMModel.knownKey) ?? []
        #expect(stored.count == 1)
        #expect(!stored.joined().contains("secret-internal-pkg"))
    }

    @Test @MainActor func detailsFeedSeverityAndFixIntoAlerts() async {
        let stub = Stub()
        stub.table = ["a": ["GHSA-1"]]
        stub.detailTable = ["GHSA-1": VulnDetail(id: "GHSA-1", rating: .critical, fixed: ["a": ["1.2.3"]])]
        let (model, _) = make(stub)
        await model.apply(components: [Self.a])
        let issues = SBOMModel.alertIssues(model.vulnerabilities, details: model.details)
        #expect(issues.count == 1)
        #expect(issues[0].severity == .high)
        #expect(issues[0].subject == "a 1 (düzeltme: 1.2.3)")
    }

    @Test func alertsWithoutDetailsStayMedium() {
        let issues = SBOMModel.alertIssues([Self.a: ["CVE-1"]], details: [:])
        #expect(issues[0].severity == .medium)
        #expect(issues[0].subject == "a 1")
    }

    @Test @MainActor func backgroundRefreshNeverAsksOsvWhenLookupIsOff() async {
        let stub = Stub()
        let (model, _) = make(stub, enabled: false)
        let ran = await model.refreshIfEnabled(roots: [])
        #expect(!ran)
        #expect(stub.calls == 0)
    }

    @Test @MainActor func backgroundRefreshRunsWhenLookupIsOn() async {
        let stub = Stub()
        let (model, _) = make(stub)
        let ran = await model.refreshIfEnabled(roots: [])
        #expect(ran)
        #expect(stub.calls == 1)
        #expect(model.lastChecked != nil)
    }
}
