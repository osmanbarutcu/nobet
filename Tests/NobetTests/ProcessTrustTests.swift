import Foundation
import Testing
@testable import Nobet

private struct FakeChecker: SignatureChecking {
    let result: SignatureStatus
    func status(forPath path: String) -> SignatureStatus { result }
}

struct ProcessTrustTests {
    private let home = "/Users/ornek"

    @Test(arguments: [
        "/tmp/agent",
        "/private/tmp/agent",
        "/var/tmp/agent",
        "/private/var/tmp/agent",
        "/private/var/folders/ab/cd/T/payload",
        "/Users/ornek/Downloads/tool",
        "/Users/ornek/.hidden/bin/svc",
        "/Users/ornek/.Trash/svc",
        "/Users/Shared/svc",
    ])
    func flagsRiskyLocations(path: String) {
        #expect(ProcessTrust.isSuspiciousLocation(path, home: home))
    }

    @Test(arguments: [
        "/usr/bin/ssh",
        "/System/Library/CoreServices/ControlCenter.app/Contents/MacOS/ControlCenter",
        "/Applications/Safari.app/Contents/MacOS/Safari",
        "/opt/homebrew/bin/node",
        "/Users/ornek/Projects/app/bin/server",
        "/Users/ornek/.orbstack/bin/docker",
        "/Users/ornek/.cargo/bin/rg",
        "/Users/ornek/.nvm/versions/node/v22/bin/node",
        "/Users/ornek/.local/bin/uv",
        "/private/var/folders/ab/cd/T/AppTranslocation/X/d/Foo.app/Contents/MacOS/Foo",
    ])
    func acceptsNormalLocations(path: String) {
        #expect(!ProcessTrust.isSuspiciousLocation(path, home: home))
    }

    @Test func downloadsFolderOfAnotherUserIsAlsoRisky() {
        #expect(ProcessTrust.isSuspiciousLocation("/Users/baska/Downloads/tool", home: home))
    }

    @Test func similarPrefixIsNotAMatch() {
        #expect(!ProcessTrust.isSuspiciousLocation("/tmpfoo/agent", home: home))
        #expect(!ProcessTrust.isSuspiciousLocation("/Users/ornek/Downloads2/tool", home: home))
    }

    @Test func identityCombinesPathAndSignature() {
        let identity = ProcessTrust.identity(
            pid: 42, home: home, checker: FakeChecker(result: .unsigned), pathOf: { _ in "/tmp/agent" })
        #expect(identity.path == "/tmp/agent")
        #expect(identity.signature == .unsigned)
        #expect(identity.suspiciousLocation)
    }

    @Test func unreadablePathGivesUnknownAndNeverSuspicious() {
        let identity = ProcessTrust.identity(
            pid: 1, home: home, checker: FakeChecker(result: .apple), pathOf: { _ in nil })
        #expect(identity.path == nil)
        #expect(identity.signature == .unknown)
        #expect(!identity.suspiciousLocation)
    }

    @Test func identityKeyUsesPathElseName() {
        let known = ProcessIdentity(path: "/usr/bin/ssh", signature: .apple, suspiciousLocation: false)
        let unknown = ProcessIdentity(path: nil, signature: .unknown, suspiciousLocation: false)
        #expect(known.key(fallbackName: "ssh") == "/usr/bin/ssh")
        #expect(unknown.key(fallbackName: "ssh") == "ssh")
    }

    @Test func realCheckerRecognizesAppleBinaries() {
        #expect(SystemSignatureChecker().status(forPath: "/bin/ls") == .apple)
    }

    @Test func realCheckerReturnsUnknownForMissingFile() {
        #expect(SystemSignatureChecker().status(forPath: "/yok/boyle/dosya") == .unknown)
    }

    @Test func cachedCheckerAsksTheInnerCheckerOncePerFile() {
        final class Counting: SignatureChecking, @unchecked Sendable {
            var calls = 0
            func status(forPath path: String) -> SignatureStatus { calls += 1; return .developer }
        }
        let inner = Counting()
        let cached = CachedSignatureChecker(inner: inner)
        _ = cached.status(forPath: "/bin/ls")
        _ = cached.status(forPath: "/bin/ls")
        #expect(inner.calls == 1)
    }

    @Test func signatureLabelsAreTurkish() {
        #expect(SignatureStatus.apple.label == "Apple imzalı")
        #expect(SignatureStatus.developer.label == "Geliştirici imzalı")
        #expect(SignatureStatus.adHoc.label == "Ad-hoc imzalı")
        #expect(SignatureStatus.unsigned.label == "İmzasız")
        #expect(SignatureStatus.invalid.label == "İmza geçersiz")
        #expect(SignatureStatus.unknown.label == "İmza okunamadı")
    }
}
