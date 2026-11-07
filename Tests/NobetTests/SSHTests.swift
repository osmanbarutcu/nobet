import Foundation
import Testing
@testable import Nobet

struct SSHProfileTests {
    @Test func validProfileIsAccepted() {
        let profile = SSHProfile.make(name: "Üretim", host: "203.0.113.10", port: 22, user: "root", auth: .password, services: ["nginx", "mariadb"])
        #expect(profile?.user == "root")
        #expect(profile?.services == ["nginx", "mariadb"])
    }

    @Test func badHostUserPortAreRefused() {
        #expect(SSHProfile.make(name: "", host: "ssh://x.com", port: 22, user: "root", auth: .key, services: []) == nil)
        #expect(SSHProfile.make(name: "", host: "x.com", port: 22, user: "root; id", auth: .key, services: []) == nil)
        #expect(SSHProfile.make(name: "", host: "x.com", port: 22, user: "-oProxyCommand=x", auth: .key, services: []) == nil)
        #expect(SSHProfile.make(name: "", host: "x.com", port: 0, user: "root", auth: .key, services: []) == nil)
        #expect(SSHProfile.make(name: "", host: "x.com", port: 22, user: "", auth: .key, services: []) == nil)
    }

    @Test func unsafeServiceNamesAreDropped() {
        let profile = SSHProfile.make(name: "", host: "x.com", port: 22, user: "root", auth: .key,
                                      services: ["nginx", "x; rm -rf /", "a b", "$(id)", "postgresql@14-main", "nginx"])
        #expect(profile?.services == ["nginx", "postgresql@14-main"])
    }

    @Test func emptyNameFallsBackToHost() {
        #expect(SSHProfile.make(name: " ", host: "x.com", port: 22, user: "root", auth: .key, services: [])?.name == "x.com")
    }

    @Test func profileHasNoSecretField() throws {
        let profile = try #require(SSHProfile.make(name: "a", host: "x.com", port: 22, user: "root", auth: .password, services: []))
        let json = String(decoding: try JSONEncoder().encode(profile), as: UTF8.self)
        #expect(!json.lowercased().contains("password\":\""))
        #expect(json.contains("\"auth\":\"password\""))
    }
}

struct SSHInvocationTests {
    private let password = SSHProfile.make(name: "a", host: "10.0.0.1", port: 2222, user: "root", auth: .password, services: ["nginx"])!
    private let key = SSHProfile.make(name: "a", host: "10.0.0.1", port: 22, user: "deploy", auth: .key, services: [])!

    @Test func passwordAuthDisablesKeysAndLimitsPrompts() {
        let args = SSHInvocation.arguments(for: password, knownHosts: "/tmp/kh", command: "echo hi")
        #expect(args.contains("PreferredAuthentications=password"))
        #expect(args.contains("PubkeyAuthentication=no"))
        #expect(args.contains("NumberOfPasswordPrompts=1"))
        #expect(!args.contains("BatchMode=yes"))
    }

    @Test func keyAuthIsBatchMode() {
        let args = SSHInvocation.arguments(for: key, knownHosts: "/tmp/kh", command: "echo hi")
        #expect(args.contains("BatchMode=yes"))
        #expect(!args.contains("PreferredAuthentications=password"))
    }

    @Test func knownHostsPathWithSpacesIsQuoted() {
        let args = SSHInvocation.arguments(for: password, knownHosts: "/Users/it/Library/Application Support/Nobet/known_hosts", command: "echo hi")
        #expect(args.contains("UserKnownHostsFile=\"/Users/it/Library/Application Support/Nobet/known_hosts\""))
        #expect(!args.contains("UserKnownHostsFile=/Users/it/Library/Application Support/Nobet/known_hosts"))
    }

    @Test func commonOptionsAndOrdering() {
        let args = SSHInvocation.arguments(for: password, knownHosts: "/tmp/kh", command: "echo hi")
        #expect(args.contains("StrictHostKeyChecking=accept-new"))
        #expect(args.contains("UserKnownHostsFile=/tmp/kh"))
        #expect(args.contains("ConnectTimeout=10"))
        let portIndex = args.firstIndex(of: "-p")
        #expect(portIndex.map { args[$0 + 1] } == "2222")
        #expect(Array(args.suffix(3)) == ["--", "root@10.0.0.1", "echo hi"])
    }
}

struct RemoteScriptTests {
    @Test func scriptContainsFixedReadOnlyCommandsOnly() {
        let script = RemoteScript.linux(services: ["nginx"])
        for expected in ["df -P", "free -m", "/proc/loadavg", "/proc/uptime", "nproc", "systemctl --failed", "systemctl is-active"] {
            #expect(script.contains(expected))
        }
        // İzinli kalıplar: stderr'i atan `2>/dev/null` ve yeniden başlatma bayrağı dosyasının adı. Başka yönlendirme yasak.
        let checked = script.replacingOccurrences(of: "2>/dev/null", with: "").replacingOccurrences(of: "2>&1", with: "").replacingOccurrences(of: "/var/run/reboot-required", with: "")
        for forbidden in ["rm ", "reboot", "shutdown", "kill", ">", "sudo", "chmod", "systemctl restart", "systemctl stop"] {
            #expect(!checked.contains(forbidden))
        }
    }

    @Test func serviceNamesAreQuotedAndUnsafeOnesNeverAppear() {
        let script = RemoteScript.linux(services: ["nginx", "x; rm -rf /"])
        #expect(script.contains("'nginx'"))
        #expect(!script.contains("rm -rf"))
    }
}

struct MetricsAssemblyTests {
    private let output = """
    Linux 3.10.0-1160.119.1.el7.x86_64
    #os
    PRETTY_NAME="CentOS Linux 7 (Core)"
    #df
    Filesystem                  1024-blocks     Used Available Capacity Mounted on
    devtmpfs                        8111836        0   8111836       0% /dev
    /dev/mapper/centos_srv-root   157260800 77495728  79765072      50% /
    /dev/loop0                        50560    50560         0     100% /var/lib/snapd/snap/snapd/24792
    /dev/sda1                       1038336   198784    839552      20% /boot
    #free
                  total        used        free      shared  buff/cache   available
    Mem:          15866        4401         891         921       10572       10132
    Swap:          8063         155        7908
    #load
    0.39 0.31 0.25 1/730 38513
    #uptime
    6863642.61 26448083.52
    #nproc
    4
    #failed
    #svc
    nginx=active
    mysql=unknown
    mariadb=active
    """

    @Test func realOutputIsAssembled() throws {
        let metrics = try #require(LinuxParser.metrics(from: output))
        #expect(metrics.disks.map(\.mount) == ["/", "/boot"])
        #expect(metrics.memory?.totalMB == 15866)
        #expect(metrics.cores == 4)
        #expect(metrics.uptimeSeconds == 6_863_642)
        #expect(metrics.load == [0.39, 0.31, 0.25])
        #expect(metrics.failedUnits.isEmpty)
        #expect(metrics.services == ["nginx": .active, "mysql": .missing, "mariadb": .active])
        #expect(metrics.osName == "CentOS Linux 7 (Core)")
    }

    @Test func outputWithoutMarkersIsRejected() {
        #expect(LinuxParser.metrics(from: "Permission denied") == nil)
        #expect(LinuxParser.metrics(from: "") == nil)
    }
}

struct SSHErrorTests {
    @Test func commonFailuresGetClearMessages() {
        #expect(SSHError.describe(status: 255, output: "root@x: Permission denied (publickey,password).").contains("Kimlik doğrulama"))
        #expect(SSHError.describe(status: 255, output: "ssh: connect to host x port 22: Operation timed out").contains("Zaman aşımı"))
        #expect(SSHError.describe(status: 255, output: "ssh: connect to host x port 22: Connection refused").contains("reddedildi"))
        #expect(SSHError.describe(status: 255, output: "Host key verification failed.").contains("anahtarı"))
        #expect(SSHError.describe(status: 255, output: "ssh: Could not resolve hostname x").contains("çözümlenemedi"))
    }

    @Test func outputNeverEchoesUnknownText() {
        let message = SSHError.describe(status: 1, output: "gizli-metin-123")
        #expect(!message.contains("gizli-metin-123"))
    }
}

struct AskpassTests {
    @Test func askpassReturnsPasswordOnlyWhenFlagged() {
        #expect(AskpassMode.password(environment: ["NOBET_ASKPASS": "1", "NOBET_PW": "abc"]) == "abc")
        #expect(AskpassMode.password(environment: ["NOBET_PW": "abc"]) == nil)
        #expect(AskpassMode.password(environment: ["NOBET_ASKPASS": "1"]) == nil)
    }
}
