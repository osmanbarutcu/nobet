import Foundation
import Testing
@testable import Nobet

struct LinuxParserTests {
    private let df = """
    Filesystem     1024-blocks     Used Available Capacity Mounted on
    /dev/sda1         41152812 33000000   8152812      81% /
    tmpfs              2000000        0   2000000       0% /dev/shm
    overlay           41152812 33000000   8152812      81% /var/lib/docker/overlay2/x/merged
    /dev/sdb1        103081248 98000000   5081248      95% /mnt/yedek disk
    """

    @Test func dfKeepsRealFilesystemsAndSkipsPseudoOnes() {
        let disks = LinuxParser.disks(df)
        #expect(disks.map(\.mount) == ["/", "/mnt/yedek disk"])
        #expect(disks[0].usedPercent == 81)
        #expect(disks[1].usedPercent == 95)
    }

    @Test func dfSkipsReadOnlyLoopDevicesFromSnap() {
        let real = """
        Filesystem                  1024-blocks     Used Available Capacity Mounted on
        /dev/loop0                        50560    50560         0     100% /var/lib/snapd/snap/snapd/24792
        /dev/mapper/centos_srv-root   157260800 77495728  79765072      50% /
        /dev/sda1                       1038336   198784    839552      20% /boot
        """
        #expect(LinuxParser.disks(real).map(\.mount) == ["/", "/boot"])
    }

    @Test func dfGarbageGivesNoDisks() {
        #expect(LinuxParser.disks("").isEmpty)
        #expect(LinuxParser.disks("komut bulunamadı").isEmpty)
    }

    private let free = """
                   total        used        free      shared  buff/cache   available
    Mem:            3900        1500         400         100        2000        2200
    Swap:           2047         512        1535
    """

    @Test func freeGivesMemoryAndSwap() throws {
        let memory = try #require(LinuxParser.memory(free))
        #expect(memory.totalMB == 3900)
        #expect(memory.availableMB == 2200)
        #expect(memory.usedPercent == 44)
        #expect(memory.swapTotalMB == 2047)
        #expect(memory.swapUsedMB == 512)
    }

    @Test func freeWithoutMemLineIsNil() {
        #expect(LinuxParser.memory("garbage") == nil)
    }

    @Test func loadAverageAndUptime() throws {
        let load = try #require(LinuxParser.load("0.15 0.10 0.05 1/234 5678"))
        #expect(load == [0.15, 0.10, 0.05])
        #expect(LinuxParser.load("x y") == nil)
        #expect(LinuxParser.uptimeSeconds("1052334.12 4000000.55") == 1_052_334)
        #expect(LinuxParser.uptimeSeconds("") == nil)
    }

    @Test func serviceStateAcceptsOnlyKnownWords() {
        #expect(LinuxParser.serviceState("active\n") == .active)
        #expect(LinuxParser.serviceState("inactive\n") == .inactive)
        #expect(LinuxParser.serviceState("failed\n") == .failed)
        #expect(LinuxParser.serviceState("unknown\n") == .missing)
        #expect(LinuxParser.serviceState("") == .missing)
    }

    @Test func failedUnitsAreListedByName() {
        let output = """
          nginx.service loaded failed failed A high performance web server
        ● cron.service  loaded failed failed Regular background program processing
        """
        #expect(LinuxParser.failedUnits(output) == ["nginx.service", "cron.service"])
        #expect(LinuxParser.failedUnits("").isEmpty)
    }
}

struct RemoteHealthTests {
    private func metrics(disks: [DiskUsage] = [], memory: MemoryUsage? = nil, load: [Double]? = nil, cores: Int? = nil,
                         services: [String: ServiceState] = [:], failed: [String] = []) -> RemoteMetrics {
        RemoteMetrics(disks: disks, memory: memory, load: load, cores: cores, uptimeSeconds: nil, services: services, failedUnits: failed)
    }

    @Test func healthyServerHasNoIssues() {
        let ok = metrics(disks: [DiskUsage(mount: "/", usedPercent: 40)],
                         memory: MemoryUsage(totalMB: 4000, availableMB: 3000, swapTotalMB: 0, swapUsedMB: 0),
                         load: [0.2, 0.2, 0.2], cores: 2, services: ["nginx": .active])
        #expect(RemoteHealth.issues(for: ok).isEmpty)
    }

    @Test func diskThresholds() {
        let high = RemoteHealth.issues(for: metrics(disks: [DiskUsage(mount: "/", usedPercent: 95)]))
        #expect(high.map(\.severity) == [.high])
        let medium = RemoteHealth.issues(for: metrics(disks: [DiskUsage(mount: "/", usedPercent: 85)]))
        #expect(medium.map(\.severity) == [.medium])
        #expect(RemoteHealth.issues(for: metrics(disks: [DiskUsage(mount: "/", usedPercent: 79)])).isEmpty)
    }

    @Test func lowMemoryIsMedium() {
        let low = metrics(memory: MemoryUsage(totalMB: 4000, availableMB: 200, swapTotalMB: 0, swapUsedMB: 0))
        #expect(RemoteHealth.issues(for: low).map(\.severity) == [.medium])
    }

    @Test func heavyLoadPerCoreIsMedium() {
        #expect(RemoteHealth.issues(for: metrics(load: [9, 1, 1], cores: 2)).map(\.severity) == [.medium])
        #expect(RemoteHealth.issues(for: metrics(load: [3, 1, 1], cores: 2)).isEmpty)
    }

    @Test func stoppedOrMissingServiceIsHigh() {
        let down = RemoteHealth.issues(for: metrics(services: ["postgresql": .inactive, "redis": .failed]))
        #expect(down.count == 2)
        #expect(down.allSatisfy { $0.severity == .high })
        #expect(RemoteHealth.issues(for: metrics(services: ["mysql": .missing])).first?.severity == .high)
    }

    @Test func failedUnitsAreMedium() {
        let issues = RemoteHealth.issues(for: metrics(failed: ["nginx.service"]))
        #expect(issues.map(\.severity) == [.medium])
        #expect(issues.first?.detail.contains("nginx.service") == true)
    }

    @Test func alertCountIgnoresInfo() {
        let issues = [RemoteIssue(title: "a", detail: "", severity: .info), RemoteIssue(title: "b", detail: "", severity: .high)]
        #expect(RemoteHealth.alertCount(issues) == 1)
    }
}
