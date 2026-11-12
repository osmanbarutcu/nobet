import Foundation
import Testing
@testable import Nobet

/// `ssh` yerine geçici bir betik çalıştırır. Gerçek sunucuya bağlanılmaz.
@Suite(.serialized)
struct SSHRunnerExecuteTests {
    private func makeScript(_ body: String) throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nobet-ssh-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("fake-ssh").path
        try "#!/bin/sh\n\(body)\n".write(toFile: path, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func profile(auth: SSHAuth = .key) throws -> SSHProfile {
        try #require(SSHProfile.make(name: "", host: "a.example.com", port: 2222, user: "deploy", auth: auth, services: []))
    }

    private func run(_ script: String, auth: SSHAuth = .key, password: String? = nil, timeout: TimeInterval = 10)
        throws -> Result<SSHRunner.CommandOutput, SSHFailure> {
        SSHRunner.execute(try profile(auth: auth), password: password, command: "uname -sr", sshPath: try makeScript(script), timeout: timeout)
    }

    @Test func successReturnsStdoutAndStatusZero() throws {
        let output = try #require(try? run("echo merhaba").get())
        #expect(output.status == 0)
        #expect(output.stdout == "merhaba\n")
    }

    @Test func nonZeroStatusAndStderrAreCaptured() throws {
        let output = try #require(try? run("echo 'Permission denied (publickey).' >&2; exit 255").get())
        #expect(output.status == 255)
        #expect(output.stderr.contains("Permission denied"))
    }

    @Test func argumentsAreSeparateAndEndWithTheCommand() throws {
        let output = try #require(try? run(#"for a in "$@"; do echo "[$a]"; done"#).get())
        let lines = output.stdout.split(separator: "\n").map(String.init)
        #expect(lines.contains("[-T]"))
        #expect(lines.contains("[--]"))
        #expect(lines.contains("[deploy@a.example.com]"))
        #expect(lines.last == "[uname -sr]")
    }

    @Test func passwordProfilePassesThePasswordOnlyThroughTheEnvironment() throws {
        let output = try #require(try? run(#"echo "pw=$NOBET_PW force=$SSH_ASKPASS_REQUIRE args=$*""#, auth: .password, password: "gizli-1").get())
        #expect(output.stdout.contains("pw=gizli-1"))
        #expect(output.stdout.contains("force=force"))
        #expect(!output.stdout.contains("args=") || !output.stdout.components(separatedBy: "args=")[1].contains("gizli-1"))
    }

    @Test func keyProfileLeavesNoPasswordInTheEnvironment() throws {
        let output = try #require(try? run(#"echo "pw=[$NOBET_PW] askpass=[$SSH_ASKPASS]""#, auth: .key, password: "gizli-1").get())
        #expect(output.stdout.contains("pw=[]"))
        #expect(output.stdout.contains("askpass=[]"))
    }

    @Test func slowProcessIsKilledAndReportedAsTimeout() throws {
        let start = Date()
        let result = try run("exec sleep 30", timeout: 0.5)
        guard case .failure(let failure) = result else { Issue.record("Zaman aşımı bekleniyordu"); return }
        #expect(failure.message.contains("Zaman aşımı"))
        #expect(Date().timeIntervalSince(start) < 10)
    }

    @Test func missingBinaryReportsAStartFailure() throws {
        let result = SSHRunner.execute(try profile(), password: nil, command: "x", sshPath: "/yok/ssh", timeout: 2)
        guard case .failure(let failure) = result else { Issue.record("Hata bekleniyordu"); return }
        #expect(failure.message.contains("başlatılamadı"))
    }

    @Test func largeOutputOnBothStreamsDoesNotDeadlock() throws {
        let script = "head -c 300000 /dev/zero | tr '\\0' a; head -c 300000 /dev/zero | tr '\\0' b >&2"
        let output = try #require(try? run(script, timeout: 20).get())
        #expect(output.stdout.count == 300_000)
        #expect(output.stderr.count == 300_000)
    }

    @Test func fullCollectionParsesTheFakeServerOutput() throws {
        let script = "echo 'Linux 6.1'; echo '#os'; echo 'PRETTY_NAME=\"Debian\"'; echo '#df'; echo 'Filesystem 1024-blocks Used Available Capacity Mounted on'; "
            + "echo '/dev/sda1 1000 400 600 40% /'; echo '#uptime'; echo '1000.00 900.00'"
        let output = try #require(try? run(script).get())
        guard case .success = SSHRunner.interpret(status: output.status, stdout: output.stdout, stderr: output.stderr) else {
            Issue.record("Çıktı ayrıştırılamadı"); return
        }
    }
}
