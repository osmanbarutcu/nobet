import Foundation
import Testing
@testable import Nobet

private let hardened = """
    #df
    Filesystem 1024-blocks Used Available Capacity Mounted on
    /dev/vda1 100 50 50 50% /
    #sshd
    port 22
    permitrootlogin without-password
    passwordauthentication no
    #f2b
    active
    #listen
    State      Recv-Q Send-Q Local Address:Port               Peer Address:Port
    LISTEN     0      128          *:22                       *:*
    LISTEN     0      128    127.0.0.1:3306                   *:*
    #lastb
    12
    #pending
    no
    """

private let weak = """
    #df
    Filesystem 1024-blocks Used Available Capacity Mounted on
    /dev/vda1 100 50 50 50% /
    #sshd
    port 22
    permitrootlogin yes
    passwordauthentication yes
    #f2b
    inactive
    #listen
    State      Recv-Q Send-Q Local Address:Port               Peer Address:Port
    LISTEN     0      128          *:22                       *:*
    LISTEN     0      128         :::80                      :::*
    LISTEN     0      128    127.0.0.1:3306                   *:*
    LISTEN     0      128   10.0.0.5:8080                     *:*
    #lastb
    4821
    #pending
    yes
    """

struct RemoteSecurityTests {
    @Test func hardenedServerParsesWithoutFindings() throws {
        let metrics = try #require(LinuxParser.metrics(from: hardened))
        let security = try #require(metrics.security)
        #expect(security.permitRootLogin == "without-password")
        #expect(security.passwordAuthentication == false)
        #expect(security.fail2banActive == true)
        #expect(security.failedLogins == 12)
        #expect(security.publicPorts == [22])
        #expect(!security.rebootRequired)
        #expect(RemoteHealth.issues(for: metrics).isEmpty)
    }

    @Test func weakServerIsParsedFully() throws {
        let security = try #require(LinuxParser.metrics(from: weak)?.security)
        #expect(security.permitRootLogin == "yes")
        #expect(security.passwordAuthentication == true)
        #expect(security.fail2banActive == false)
        #expect(security.failedLogins == 4821)
        #expect(security.publicPorts == [22, 80, 8080])
        #expect(security.rebootRequired)
    }

    @Test func weakServerRaisesTheExpectedIssues() throws {
        let metrics = try #require(LinuxParser.metrics(from: weak))
        let issues = RemoteHealth.issues(for: metrics)
        let byTitle = Dictionary(uniqueKeysWithValues: issues.map { ($0.title, $0) })
        #expect(byTitle["Root ile SSH girişi açık"]?.severity == .high)
        #expect(byTitle["SSH parola girişi açık"]?.severity == .medium)
        #expect(byTitle["fail2ban çalışmıyor"]?.severity == .medium)
        #expect(byTitle["Yeniden başlatma bekliyor"]?.severity == .info)
        #expect(RemoteHealth.alertCount(issues) == 3)
    }

    @Test func suggestionsAreTextOnlyAndMentionKeyAuthWarning() throws {
        let metrics = try #require(LinuxParser.metrics(from: weak))
        let root = try #require(RemoteHealth.issues(for: metrics).first { $0.title == "Root ile SSH girişi açık" })
        #expect(root.suggestion?.contains("PermitRootLogin prohibit-password") == true)
        #expect(root.detail.contains("anahtar"))
    }

    @Test func missingSecuritySectionsGiveNoSecurityAndNoIssues() throws {
        let output = "#df\nFilesystem 1024-blocks Used Available Capacity Mounted on\n/dev/vda1 100 50 50 50% /\n"
        let metrics = try #require(LinuxParser.metrics(from: output))
        #expect(metrics.security == nil)
        #expect(RemoteHealth.issues(for: metrics).isEmpty)
    }

    @Test func unknownFail2banIsNotReportedAsStopped() throws {
        let output = hardened.replacingOccurrences(of: "#f2b\nactive", with: "#f2b\n")
        let security = try #require(LinuxParser.metrics(from: output)?.security)
        #expect(security.fail2banActive == nil)
    }

    @Test func scriptHasSecuritySectionsAndStaysReadOnly() {
        let script = RemoteScript.linux(services: [])
        for marker in ["#sshd", "#f2b", "#listen", "#lastb", "#pending"] { #expect(script.contains(marker)) }
        #expect(!script.contains("; sudo"))
        for forbidden in ["rm ", "yum ", "apt ", "systemctl restart", "systemctl stop", "> /", "sed -i", "chmod", "kill"] {
            #expect(!script.contains(forbidden))
        }
    }
}
