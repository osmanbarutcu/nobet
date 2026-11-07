import Foundation
import Testing
@testable import Nobet

struct WindowsProfileTests {
    @Test func platformDefaultsToLinuxAndRoundTrips() throws {
        let linux = try #require(SSHProfile.make(name: "a", host: "a.com", port: 22, user: "root", auth: .key, services: []))
        #expect(linux.platform == nil)
        #expect(linux.isWindows == false)
        let windows = try #require(SSHProfile.make(name: "w", host: "w.com", port: 22, user: "Administrator", auth: .key, services: [], platform: .windows))
        #expect(windows.isWindows)
        let decoded = try JSONDecoder().decode(SSHProfile.self, from: JSONEncoder().encode(windows))
        #expect(decoded == windows)
    }

    @Test func oldRecordsWithoutPlatformStillDecode() throws {
        let json = #"{"id":"1","name":"a","host":"a.com","port":22,"user":"root","auth":"key","services":[]}"#
        let profile = try JSONDecoder().decode(SSHProfile.self, from: Data(json.utf8))
        #expect(profile.isWindows == false)
    }
}

struct WindowsScriptTests {
    private func decode(_ command: String) -> String? {
        guard let range = command.range(of: "-EncodedCommand ") else { return nil }
        let encoded = String(command[range.upperBound...])
        return Data(base64Encoded: encoded).flatMap { String(data: $0, encoding: .utf16LittleEndian) }
    }

    @Test func commandRunsPowerShellWithAnEncodedScript() throws {
        let command = RemoteScript.windows(services: ["Spooler"])
        #expect(command.hasPrefix("powershell -NoProfile -NonInteractive -EncodedCommand "))
        let script = try #require(decode(command))
        #expect(script.contains("Win32_LogicalDisk"))
        #expect(script.contains("Win32_OperatingSystem"))
        #expect(script.contains("'Spooler'"))
    }

    @Test func scriptStaysReadOnly() throws {
        let script = try #require(decode(RemoteScript.windows(services: [])))
        let lowered = script.lowercased()
        for forbidden in ["remove-", "stop-", "restart-", "set-", "new-", "start-", "invoke-expression", "iex ", "del ", "format-", "clear-", "out-file", ">"] {
            #expect(!lowered.contains(forbidden), "yasak: \(forbidden)")
        }
    }

    @Test func unsafeServiceNamesAreDropped() throws {
        let script = try #require(decode(RemoteScript.windows(services: ["ok", "kötü'; calc; '"])))
        #expect(script.contains("'ok'"))
        #expect(!script.contains("calc"))
    }

    @Test func sshProfileUsesTheWindowsCommand() throws {
        let profile = try #require(SSHProfile.make(name: "w", host: "w.com", port: 22, user: "Administrator", auth: .key, services: [], platform: .windows))
        #expect(RemoteScript.command(for: profile).hasPrefix("powershell "))
        let linux = try #require(SSHProfile.make(name: "a", host: "a.com", port: 22, user: "root", auth: .key, services: []))
        #expect(RemoteScript.command(for: linux).hasPrefix("uname -sr"))
    }
}

struct WindowsParserTests {
    private let output = """
    #os
    Microsoft Windows Server 2022 Standard
    #df
    C: 100000000000 25000000000
    D: 50000000000 50000000000
    #mem
    8388608 2097152
    #uptime
    93784
    #svc
    Spooler=Running
    W32Time=Stopped
    Yok=NotFound
    """

    @Test func readsDisksMemoryUptimeAndServices() throws {
        let metrics = try #require(WindowsParser.metrics(from: output))
        #expect(metrics.disks == [DiskUsage(mount: "C:", usedPercent: 75), DiskUsage(mount: "D:", usedPercent: 0)])
        #expect(metrics.memory?.totalMB == 8192)
        #expect(metrics.memory?.availableMB == 2048)
        #expect(metrics.memory?.usedPercent == 75)
        #expect(metrics.uptimeSeconds == 93784)
        #expect(metrics.services == ["Spooler": .active, "W32Time": .inactive, "Yok": .missing])
        #expect(metrics.osName == "Microsoft Windows Server 2022 Standard")
        #expect(metrics.load == nil && metrics.security == nil && metrics.containers == nil)
    }

    @Test func outputWithoutDiskSectionIsRejected() {
        #expect(WindowsParser.metrics(from: "bozuk çıktı") == nil)
    }

    @Test func zeroSizedDiskAndBrokenLinesAreSkipped() throws {
        let text = "#df\nA: 0 0\nC: x y\nE: 100 50\n"
        #expect(try #require(WindowsParser.metrics(from: text)).disks == [DiskUsage(mount: "E:", usedPercent: 50)])
    }

    @Test func interpretUsesTheWindowsParserForWindowsProfiles() {
        let result = SSHRunner.interpret(status: 0, stdout: output, stderr: "", windows: true)
        #expect((try? result.get())?.osName == "Microsoft Windows Server 2022 Standard")
        #expect((try? SSHRunner.interpret(status: 0, stdout: output, stderr: "").get())?.osName == nil)
    }
}
