import Foundation
import Testing
@testable import Nobet

struct ProcessCwdTests {
    @Test func parsesPidToDirectory() {
        let output = "p100\nfcwd\nn/Users/it/app\np200\nfcwd\nn/\n"
        let map = ProcessCwd.parse(output)
        #expect(map[100] == "/Users/it/app")
        #expect(map[200] == "/")
    }

    @Test func processWithoutDirectoryIsSkipped() {
        let map = ProcessCwd.parse("p100\nfcwd\np200\nfcwd\nn/tmp\n")
        #expect(map[100] == nil)
        #expect(map[200] == "/tmp")
    }

    @Test func emptyOutputGivesEmptyMap() {
        #expect(ProcessCwd.parse("").isEmpty)
    }
}

struct ProjectRootTests {
    private let home = "/Users/it"

    @Test func findsNearestMarkerAboveTheDirectory() {
        let files: Set<String> = ["/Users/it/proj/package.json"]
        let root = ProjectRoot.find(from: "/Users/it/proj/src/deep", home: home) { files.contains($0) }
        #expect(root == "/Users/it/proj")
    }

    @Test func nearestMarkerWinsInMonorepo() {
        let files: Set<String> = ["/Users/it/r/.git", "/Users/it/r/api/package.json"]
        let root = ProjectRoot.find(from: "/Users/it/r/api/src", home: home) { files.contains($0) }
        #expect(root == "/Users/it/r/api")
    }

    @Test func gitDirectoryCountsAsMarker() {
        let files: Set<String> = ["/Users/it/p/.git"]
        let root = ProjectRoot.find(from: "/Users/it/p/x", home: home) { files.contains($0) }
        #expect(root == "/Users/it/p")
    }

    @Test func homeFolderIsNeverAProject() {
        let files: Set<String> = ["/Users/it/package.json"]
        let root = ProjectRoot.find(from: "/Users/it/Downloads", home: home) { files.contains($0) }
        #expect(root == nil)
    }

    @Test func noMarkerGivesNil() {
        let root = ProjectRoot.find(from: "/Users/it/misc", home: home) { _ in false }
        #expect(root == nil)
    }

    @Test func rootDirectoryGivesNil() {
        #expect(ProjectRoot.find(from: "/", home: home) { _ in true } == nil)
    }

    @Test func projectsOutsideHomeAreFound() {
        let files: Set<String> = ["/Volumes/brtc-disk/Proje/x/composer.json"]
        let root = ProjectRoot.find(from: "/Volumes/brtc-disk/Proje/x/public", home: home) { files.contains($0) }
        #expect(root == "/Volumes/brtc-disk/Proje/x")
    }
}

struct DockerContainerTests {
    private func line(_ fields: [String]) -> String { fields.joined(separator: "\t") }

    @Test func parsesDdevContainer() throws {
        let out = line(["d4493b", "ddev-mia-web-wp-db", "ddev/ddev-dbserver", "running", "Up 2 hours (healthy)",
                        "127.0.0.1:33001->3306/tcp", "ddev-mia-web-wp", "mia-web-wp",
                        "/Volumes/brtc-disk/Proje/mia-web-wp", ""])
        let list = DockerContainer.parse(out)
        let container = try #require(list.first)
        #expect(container.name == "ddev-mia-web-wp-db")
        #expect(container.isRunning)
        #expect(container.projectName == "mia-web-wp")
        #expect(container.projectRoot == "/Volumes/brtc-disk/Proje/mia-web-wp")
    }

    @Test func composeContainerUsesWorkingDirectory() throws {
        let out = line(["a1", "web-1", "nginx", "exited", "Exited (0) 1 hour ago", "", "shop", "", "", "/Users/it/shop"])
        let container = try #require(DockerContainer.parse(out).first)
        #expect(!container.isRunning)
        #expect(container.projectName == "shop")
        #expect(container.projectRoot == "/Users/it/shop")
    }

    @Test func standaloneContainerHasNoRootAndUsesItsName() throws {
        let out = line(["b2", "redis", "redis:7", "running", "Up 3 days", "0.0.0.0:6379->6379/tcp", "", "", "", ""])
        let container = try #require(DockerContainer.parse(out).first)
        #expect(container.projectRoot == nil)
        #expect(container.projectName == "redis")
    }

    @Test func malformedLinesAreSkipped() {
        let good = line(["b2", "redis", "redis:7", "running", "Up", "", "", "", "", ""])
        let out = "bozuk satır\n\(good)\nbir\tiki\n"
        #expect(DockerContainer.parse(out).count == 1)
    }

    @Test func emptyOutputGivesNoContainers() {
        #expect(DockerContainer.parse("").isEmpty)
    }
}

struct DevOverviewTests {
    private let home = "/Users/it"
    private let files: Set<String> = ["/Users/it/proj/package.json", "/Users/it/other/composer.json"]

    private func port(_ pid: Int, _ name: String, _ number: Int, _ scope: ListeningPort.Scope) -> ListeningPort {
        ListeningPort(pid: pid, process: name, address: scope == .all ? "*" : "127.0.0.1", port: number, scope: scope)
    }

    private func container(root: String?, site: String) -> DockerContainer {
        DockerContainer(id: "c1", name: "web", image: "img", state: "running", status: "Up", ports: "",
                        composeProject: "", ddevSite: site, ddevRoot: root ?? "", composeDir: "")
    }

    private func overview() -> DevOverview {
        DevOverview.build(
            ports: [port(10, "node", 3000, .local), port(11, "php", 8080, .all), port(12, "ControlCenter", 7000, .all)],
            cwds: [10: "/Users/it/proj/web", 11: "/Users/it/other", 12: "/"],
            containers: [container(root: "/Users/it/proj", site: "proj")],
            home: home, exists: { files.contains($0) })
    }

    @Test func portsJoinTheirProjectByWorkingDirectory() throws {
        let proj = try #require(overview().projects.first { $0.name == "proj" })
        #expect(proj.ports.map(\.port) == [3000])
        #expect(proj.containers.count == 1)
    }

    @Test func projectsAreSortedByName() {
        #expect(overview().projects.map(\.name) == ["other", "proj"])
    }

    @Test func portsWithoutProjectGoToOthers() {
        #expect(overview().otherPorts.map(\.port) == [7000])
    }

    @Test func alertCountsOnlyProjectPortsOpenToAllInterfaces() {
        #expect(overview().alertCount == 1)
    }

    @Test func containerWithoutRootFormsItsOwnProject() {
        let result = DevOverview.build(
            ports: [], cwds: [:],
            containers: [DockerContainer(id: "r", name: "redis", image: "redis", state: "running", status: "Up", ports: "",
                                         composeProject: "", ddevSite: "", ddevRoot: "", composeDir: "")],
            home: home, exists: { _ in false })
        #expect(result.projects.map(\.name) == ["redis"])
        #expect(result.projects.first?.root == nil)
    }
}

struct ProjectNameTests {
    @Test func ordinaryFolderNameIsKept() {
        #expect(ProjectName.make(root: "/Users/it/alvex") == "alvex")
    }

    @Test func genericNameGetsItsParent() {
        #expect(ProjectName.make(root: "/Users/it/ion-license-hub/docker") == "ion-license-hub/docker")
    }

    @Test func nestedGenericNamesClimbToTheFirstSpecificFolder() {
        #expect(ProjectName.make(root: "/Users/it/fintec/apps/api") == "fintec/apps/api")
    }

    @Test func nameHasAtMostThreeParts() {
        #expect(ProjectName.make(root: "/a/b/c/apps/web/api") == "apps/web/api")
    }

    @Test func rootOfDiskKeepsItsOwnName() {
        #expect(ProjectName.make(root: "/api") == "api")
    }
}

struct DevProjectViewTests {
    private func container(_ name: String, site: String, state: String) -> DockerContainer {
        DockerContainer(id: name, name: name, image: "img", state: state, status: "", ports: "",
                        composeProject: "", ddevSite: site, ddevRoot: "", composeDir: "")
    }

    @Test func ddevContainersCollapseIntoOneSite() {
        let project = DevProject(name: "p", root: "/p", ports: [], containers: [
            container("web", site: "mia", state: "running"), container("db", site: "mia", state: "running"),
        ])
        #expect(project.ddevSites == [DDEVSiteState(name: "mia", running: true)])
        #expect(project.standaloneContainers.isEmpty)
    }

    @Test func siteIsRunningWhenAnyContainerRuns() {
        let project = DevProject(name: "p", root: "/p", ports: [], containers: [
            container("web", site: "mia", state: "exited"), container("db", site: "mia", state: "running"),
        ])
        #expect(project.ddevSites.first?.running == true)
    }

    @Test func siteIsStoppedWhenNoContainerRuns() {
        let project = DevProject(name: "p", root: "/p", ports: [], containers: [container("web", site: "mia", state: "exited")])
        #expect(project.ddevSites.first?.running == false)
    }

    @Test func plainContainersStaySeparateFromDdev() {
        let project = DevProject(name: "p", root: "/p", ports: [], containers: [
            container("web", site: "mia", state: "running"), container("redis", site: "", state: "running"),
        ])
        #expect(project.standaloneContainers.map(\.name) == ["redis"])
        #expect(project.ddevSites.map(\.name) == ["mia"])
    }
}

struct DevModelTests {
    private func overview(exposed: Int) -> DevOverview {
        let ports = (0..<exposed).map {
            ListeningPort(pid: 10 + $0, process: "node", address: "*", port: 3000 + $0, scope: .all)
        }
        return DevOverview(projects: [DevProject(name: "p", root: "/Users/it/p", ports: ports, containers: [])], otherPorts: [])
    }

    @Test @MainActor func applyingOverviewPublishesTheAlertCount() {
        let nobet = NobetModel()
        let model = DevModel(nobet: nobet)
        model.apply(overview(exposed: 2))
        #expect(nobet.alertCount == 2)
        #expect(model.loaded)
    }

    @Test @MainActor func newOverviewReplacesTheOldAlertCount() {
        let nobet = NobetModel()
        let model = DevModel(nobet: nobet)
        model.apply(overview(exposed: 3))
        model.apply(overview(exposed: 0))
        #expect(nobet.alertCount == 0)
    }

    @Test @MainActor func validActionWaitsForConfirmation() {
        let model = DevModel(nobet: NobetModel())
        model.request(.stopContainer("web-1"))
        #expect(model.pending == .stopContainer("web-1"))
        #expect(model.errorText == nil)
    }

    @Test @MainActor func unsafeActionIsRefusedWithAMessage() {
        let model = DevModel(nobet: NobetModel())
        model.request(.stopContainer("x; rm -rf /"))
        #expect(model.pending == nil)
        #expect(model.errorText != nil)
    }

    @Test @MainActor func cancelClearsThePendingAction() {
        let model = DevModel(nobet: NobetModel())
        model.request(.ddevStop("site"))
        model.cancel()
        #expect(model.pending == nil)
    }
}

/// Gerçek komut yolu. Yalnızca testin kendi başlattığı süreç ve var olmayan bir ad kullanılır.
struct DevRunnerTests {
    @Test func terminateStopsOnlyTheGivenProcess() throws {
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["60"]
        try sleeper.run()
        defer { if sleeper.isRunning { sleeper.terminate() } }

        let failure = DevRunner.execute(.terminate(pid: Int(sleeper.processIdentifier)))
        sleeper.waitUntilExit()

        #expect(failure == nil)
        #expect(!sleeper.isRunning)
        #expect(sleeper.terminationReason == .uncaughtSignal)
    }

    @Test func stoppingAMissingContainerReportsAnErrorAndChangesNothing() {
        let failure = DevRunner.execute(.stopContainer("nobet-test-yok-\(UUID().uuidString.prefix(8))"))
        #expect(failure != nil)
    }

    @Test func invalidActionNeverReachesTheShell() {
        #expect(DevRunner.execute(.stopContainer("x; touch /tmp/nobet-enjeksiyon")) == "Eylem geçersiz.")
        #expect(!FileManager.default.fileExists(atPath: "/tmp/nobet-enjeksiyon"))
    }

    @Test func runReturnsNilWhenTheProgramDoesNotExist() {
        #expect(DevRunner.run("/yok/boyle/bir/program", [], timeout: 2) == nil)
    }

    @Test func runKillsAProgramThatExceedsTheTimeout() {
        let started = Date()
        let result = DevRunner.run("/bin/sleep", ["30"], timeout: 1)
        #expect(result == nil)
        #expect(Date().timeIntervalSince(started) < 10)
    }
}

struct DevActionTests {
    @Test func containerActionsBuildDockerArguments() {
        #expect(DevAction.stopContainer("abc123").command == .process(tool: .docker, arguments: ["stop", "abc123"]))
        #expect(DevAction.startContainer("abc123").command == .process(tool: .docker, arguments: ["start", "abc123"]))
    }

    @Test func ddevActionsBuildDdevArguments() {
        #expect(DevAction.ddevStop("mia-web-wp").command == .process(tool: .ddev, arguments: ["stop", "mia-web-wp"]))
        #expect(DevAction.ddevStart("mia-web-wp").command == .process(tool: .ddev, arguments: ["start", "mia-web-wp"]))
    }

    @Test func unsafeNamesAreRejected() {
        for bad in ["", "-rf", "x; rm -rf /", "a b", "../x", "a$(id)", "a\nb", String(repeating: "a", count: 200)] {
            #expect(DevAction.stopContainer(bad).command == nil, "kabul edilmemeli: \(bad)")
            #expect(DevAction.ddevStart(bad).command == nil, "kabul edilmemeli: \(bad)")
        }
    }

    @Test func terminateAcceptsOrdinaryPids() {
        #expect(DevAction.terminate(pid: 4242).command == .signal(pid: 4242))
    }

    @Test func terminateRejectsSystemAndInvalidPids() {
        #expect(DevAction.terminate(pid: 1).command == nil)
        #expect(DevAction.terminate(pid: 0).command == nil)
        #expect(DevAction.terminate(pid: -5).command == nil)
    }

    @Test func terminateRejectsOwnProcess() {
        #expect(DevAction.terminate(pid: Int(ProcessInfo.processInfo.processIdentifier)).command == nil)
    }
}

struct DevHealthTests {
    private func port(_ pid: Int, _ number: Int, _ scope: ListeningPort.Scope) -> ListeningPort {
        ListeningPort(pid: pid, process: "p\(pid)", address: "0.0.0.0", port: number, scope: scope)
    }

    private func container(_ name: String, state: String) -> DockerContainer {
        DockerContainer(id: name, name: name, image: "img", state: state, status: state, ports: "", composeProject: "",
                        ddevSite: "", ddevRoot: "", composeDir: "")
    }

    @Test func countsProjectsPortsAndContainers() {
        let project = DevProject(name: "p", root: "/h/p", ports: [port(1, 3000, .all), port(2, 3001, .local)],
                                 containers: [container("a", state: "running"), container("b", state: "exited")])
        let health = DevHealth(overview: DevOverview(projects: [project], otherPorts: [port(3, 80, .interface)]))
        #expect(health.projects == 1)
        #expect(health.listening == 3)
        #expect(health.exposed == 1)
        #expect(health.conflicts == 0)
        #expect(health.containersRunning == 1)
        #expect(health.containersStopped == 1)
    }

    @Test func levelIsOkWithoutIssuesAndWarningOtherwise() {
        #expect(DevHealth(overview: .empty).level == .ok)
        let exposed = DevProject(name: "p", root: "/h/p", ports: [port(1, 3000, .all)], containers: [])
        #expect(DevHealth(overview: DevOverview(projects: [exposed], otherPorts: [])).level == .warning)
        let conflict = DevOverview(projects: [], otherPorts: [port(1, 80, .local), port(2, 80, .local)])
        #expect(DevHealth(overview: conflict).level == .warning)
    }

    @Test func stoppedContainersAloneDoNotWarn() {
        let project = DevProject(name: "p", root: "/h/p", ports: [], containers: [container("b", state: "exited")])
        #expect(DevHealth(overview: DevOverview(projects: [project], otherPorts: [])).level == .ok)
    }

    @Test func headlineIsConcrete() {
        #expect(DevHealth(overview: .empty).headline == "Her şey yolunda")
        let exposed = DevProject(name: "p", root: "/h/p", ports: [port(1, 3000, .all)], containers: [])
        #expect(DevHealth(overview: DevOverview(projects: [exposed], otherPorts: [])).headline == "1 sorun var")
    }
}

struct DockerPortSummaryTests {
    private func container(_ ports: String) -> DockerContainer {
        DockerContainer(id: "a", name: "web", image: "img", state: "running", status: "Up", ports: ports,
                        composeProject: "", ddevSite: "", ddevRoot: "", composeDir: "")
    }

    @Test func ipv4AndIpv6MappingsCollapseIntoOne() {
        #expect(container("0.0.0.0:8080->80/tcp, :::8080->80/tcp").portSummary == "8080→80")
    }

    @Test func unpublishedPortsAreSkipped() {
        #expect(container("3306/tcp, 0.0.0.0:3307->3306/tcp").portSummary == "3307→3306")
    }

    @Test func severalMappingsKeepTheirOrder() {
        #expect(container("0.0.0.0:80->80/tcp, 0.0.0.0:443->443/tcp").portSummary == "80→80, 443→443")
    }

    @Test func emptyInputGivesEmptySummary() {
        #expect(container("").portSummary.isEmpty)
    }

    @Test func rangesAreKeptAsWritten() {
        #expect(container("0.0.0.0:8000-8002->8000-8002/tcp").portSummary == "8000-8002→8000-8002")
    }
}
