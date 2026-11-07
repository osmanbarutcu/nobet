import Foundation
import Testing
@testable import Nobet

private func output(_ docker: String) -> String {
    """
    #df
    Filesystem 1024-blocks Used Available Capacity Mounted on
    /dev/vda1 100 50 50 50% /
    #docker
    \(docker)
    """
}

struct RemoteDockerTests {
    @Test func containersAreParsed() throws {
        let metrics = try #require(LinuxParser.metrics(from: output("""
            web|running|Up 3 days
            db|running|Up 3 days (healthy)
            """)))
        #expect(metrics.containers?.map(\.name) == ["web", "db"])
        #expect(metrics.containers?.first?.state == "running")
        #expect(metrics.containers?.last?.status == "Up 3 days (healthy)")
    }

    @Test func healthyContainersRaiseNothing() throws {
        let metrics = try #require(LinuxParser.metrics(from: output("web|running|Up 3 days\ndb|running|Up 1 hour (healthy)")))
        #expect(RemoteHealth.issues(for: metrics).isEmpty)
    }

    @Test func crashedContainerRaisesAMediumIssue() throws {
        let metrics = try #require(LinuxParser.metrics(from: output("api|exited|Exited (137) 2 hours ago")))
        let issue = try #require(RemoteHealth.issues(for: metrics).first)
        #expect(issue.title == "Konteyner çalışmıyor: api")
        #expect(issue.severity == .medium)
        #expect(issue.detail.contains("137"))
    }

    @Test func cleanExitIsNotAnIssue() throws {
        let metrics = try #require(LinuxParser.metrics(from: output("migrate|exited|Exited (0) 5 days ago\nold|created|Created")))
        #expect(RemoteHealth.issues(for: metrics).isEmpty)
    }

    @Test func restartLoopIsHigh() throws {
        let metrics = try #require(LinuxParser.metrics(from: output("worker|restarting|Restarting (1) 4 seconds ago")))
        let issue = try #require(RemoteHealth.issues(for: metrics).first)
        #expect(issue.title == "Konteyner yeniden başlıyor: worker")
        #expect(issue.severity == .high)
    }

    @Test func unhealthyContainerIsMedium() throws {
        let metrics = try #require(LinuxParser.metrics(from: output("db|running|Up 1 hour (unhealthy)")))
        let issue = try #require(RemoteHealth.issues(for: metrics).first)
        #expect(issue.title == "Konteyner sağlıksız: db")
        #expect(issue.severity == .medium)
    }

    @Test func deadContainerIsMedium() throws {
        let metrics = try #require(LinuxParser.metrics(from: output("x|dead|Dead")))
        #expect(RemoteHealth.issues(for: metrics).first?.severity == .medium)
    }

    @Test func missingDockerSectionMeansUnknownNotEmpty() throws {
        let metrics = try #require(LinuxParser.metrics(from: "#df\nFilesystem 1024-blocks Used Available Capacity Mounted on\n/dev/vda1 100 50 50 50% /\n"))
        #expect(metrics.containers == nil)
    }

    @Test func malformedLinesAreSkipped() throws {
        let metrics = try #require(LinuxParser.metrics(from: output("bozuk satır\nweb|running|Up 1 day")))
        #expect(metrics.containers?.map(\.name) == ["web"])
    }

    @Test func scriptReadsContainersAndStaysReadOnly() {
        let script = RemoteScript.linux(services: [])
        #expect(script.contains("#docker"))
        #expect(script.contains("docker ps -a"))
        #expect(!script.contains("docker rm"))
        #expect(!script.contains("docker stop"))
        #expect(!script.contains("docker restart"))
        #expect(!script.contains("docker exec"))
    }
}
