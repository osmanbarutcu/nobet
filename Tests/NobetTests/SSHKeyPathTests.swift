import Foundation
import Testing
@testable import Nobet

struct SSHKeyPathTests {
    private func profile(keyPath: String?, auth: SSHAuth = .key) -> SSHProfile? {
        SSHProfile.make(name: "", host: "a.com", port: 22, user: "root", auth: auth, services: [], keyPath: keyPath)
    }

    @Test func acceptsAbsoluteAndHomePaths() {
        #expect(profile(keyPath: " ~/.ssh/id_ed25519_uretim ")?.keyPath == "~/.ssh/id_ed25519_uretim")
        #expect(profile(keyPath: "/Users/it/My Keys/id")?.keyPath == "/Users/it/My Keys/id")
    }

    @Test func rejectsUnsafePaths() {
        for bad in ["id_rsa", "-oProxyCommand=x", "~/../etc/passwd", "/a/../b", "/a\nb", "~/", "/"] {
            #expect(profile(keyPath: bad) == nil, "\(bad)")
        }
    }

    @Test func emptyOrPasswordProfileDropsPath() {
        #expect(profile(keyPath: "   ")?.keyPath == nil)
        #expect(profile(keyPath: "~/.ssh/k", auth: .password)?.keyPath == nil)
    }

    @Test func keyAuthPassesIdentityAsSeparateArguments() throws {
        let p = try #require(profile(keyPath: "/Users/it/My Keys/id"))
        let args = SSHInvocation.arguments(for: p, knownHosts: "/tmp/kh", command: "true")
        let i = try #require(args.firstIndex(of: "-i"))
        #expect(args[i + 1] == "/Users/it/My Keys/id")
        #expect(args.contains("IdentitiesOnly=yes"))
        #expect(args.contains("BatchMode=yes"))
    }

    @Test func homePathExpandsBeforeSsh() throws {
        #expect(SSHProfile.expandedKeyPath("~/.ssh/k", home: "/Users/it") == "/Users/it/.ssh/k")
        let p = try #require(profile(keyPath: "~/.ssh/k"))
        let args = SSHInvocation.arguments(for: p, knownHosts: "/tmp/kh", command: "true")
        #expect(args[try #require(args.firstIndex(of: "-i")) + 1] == NSHomeDirectory() + "/.ssh/k")
    }

    @Test func noKeyPathKeepsAgentBehavior() throws {
        let args = SSHInvocation.arguments(for: try #require(profile(keyPath: nil)), knownHosts: "/tmp/kh", command: "true")
        #expect(!args.contains("-i"))
        #expect(!args.contains("IdentitiesOnly=yes"))
    }

    @Test func oldProfilesStillDecode() throws {
        let old = #"{"id":"1","name":"A","host":"a.com","port":22,"user":"root","auth":"key","services":[]}"#
        #expect(try JSONDecoder().decode(SSHProfile.self, from: Data(old.utf8)).keyPath == nil)
    }
}
