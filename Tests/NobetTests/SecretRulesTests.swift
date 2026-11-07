import Foundation
import Testing
@testable import Nobet

struct FileModeTests {
    @Test func ownerOnlyIsNotAccessibleToOthers() {
        #expect(!FileMode.isGroupOrWorldAccessible(0o600))
        #expect(!FileMode.isGroupOrWorldAccessible(0o700))
    }

    @Test func groupOrWorldBitsAreDetected() {
        #expect(FileMode.isGroupOrWorldAccessible(0o640))
        #expect(FileMode.isGroupOrWorldAccessible(0o604))
        #expect(FileMode.isGroupOrWorldAccessible(0o755))
    }

    @Test func worldReadableChecksOnlyTheOtherReadBit() {
        #expect(FileMode.isWorldReadable(0o644))
        #expect(!FileMode.isWorldReadable(0o640))
        #expect(!FileMode.isWorldReadable(0o600))
    }

    @Test func octalIgnoresFileTypeBits() {
        #expect(FileMode.octal(0o100644) == "644")
        #expect(FileMode.octal(0o40700) == "700")
    }
}

struct EnvFileTests {
    @Test func recognisesEnvFileNames() {
        #expect(EnvFile.isEnvFileName(".env"))
        #expect(EnvFile.isEnvFileName(".env.local"))
        #expect(EnvFile.isEnvFileName(".env.production"))
        #expect(EnvFile.isEnvFileName(".ENV"))
    }

    @Test func templatesAndOtherNamesAreNotEnvFiles() {
        #expect(!EnvFile.isEnvFileName(".env.example"))
        #expect(!EnvFile.isEnvFileName(".env.sample"))
        #expect(!EnvFile.isEnvFileName(".env.dist"))
        #expect(!EnvFile.isEnvFileName(".env.template"))
        #expect(!EnvFile.isEnvFileName("env"))
        #expect(!EnvFile.isEnvFileName(".envrc"))
        #expect(!EnvFile.isEnvFileName("environment.ts"))
    }

    @Test func findsSecretKeysAndReportsLengthOnly() {
        let text = "APP_NAME=Nobet\nDB_PASSWORD=hunter2hunter2\nAPI_TOKEN=\"abc123xyz\"\n"
        let found = EnvFile.secrets(in: text)
        #expect(found.map(\.key) == ["DB_PASSWORD", "API_TOKEN"])
        #expect(found.map(\.valueLength) == [14, 9])
    }

    @Test func ignoresCommentsBlankLinesAndExportPrefix() {
        let text = "# DB_PASSWORD=gizli\n\nexport STRIPE_SECRET=sk_live_1234567890\n"
        let found = EnvFile.secrets(in: text)
        #expect(found.map(\.key) == ["STRIPE_SECRET"])
    }

    @Test func placeholdersAndEmptyValuesAreNotSecrets() {
        let text = """
        DB_PASSWORD=
        API_TOKEN=changeme
        APP_SECRET=your-secret-here
        MAIL_PASSWORD=null
        X_TOKEN=${OTHER}
        Y_TOKEN=<token>
        Z_SECRET=xxxxxxxx
        """
        #expect(EnvFile.secrets(in: text).isEmpty)
    }

    @Test func publicKeysAndPlainSettingsAreNotSecrets() {
        let text = "NEXT_PUBLIC_API_KEY=abcdef123456\nPORT=3000\nAPP_URL=http://x\n"
        #expect(EnvFile.secrets(in: text).isEmpty)
    }

    @Test func laravelAppKeyCounts() {
        let found = EnvFile.secrets(in: "APP_KEY=base64:AbCdEfGhIjKlMnOpQrStUvWxYz0123456789abcdefg=\n")
        #expect(found.map(\.key) == ["APP_KEY"])
    }

    @Test func inlineCommentIsNotPartOfTheValue() {
        let found = EnvFile.secrets(in: "API_TOKEN=abcdef # not\n")
        #expect(found.first?.valueLength == 6)
    }

    @Test func invalidKeysAreSkipped() {
        #expect(EnvFile.secrets(in: "bu bir anahtar değil\n= TOKEN\n1TOKEN=abcdefgh\n").isEmpty)
    }
}

struct PrivateKeyTests {
    private func opensshKey(cipher: String) -> String {
        var bytes = Data("openssh-key-v1".utf8)
        bytes.append(0)
        let count = cipher.utf8.count
        bytes.append(Data([UInt8((count >> 24) & 255), UInt8((count >> 16) & 255), UInt8((count >> 8) & 255), UInt8(count & 255)]))
        bytes.append(Data(cipher.utf8))
        bytes.append(Data(repeating: 7, count: 80))
        let body = bytes.base64EncodedString()
        return "-----BEGIN OPENSSH PRIVATE KEY-----\n\(body)\n-----END OPENSSH PRIVATE KEY-----\n"
    }

    @Test func opensshKeyWithoutCipherIsUnencrypted() {
        #expect(PrivateKey.inspect(opensshKey(cipher: "none")) == KeyInspection(isEncrypted: false))
    }

    @Test func opensshKeyWithCipherIsEncrypted() {
        #expect(PrivateKey.inspect(opensshKey(cipher: "aes256-ctr")) == KeyInspection(isEncrypted: true))
    }

    @Test func pemKeyWithoutProcTypeIsUnencrypted() {
        let text = "-----BEGIN RSA PRIVATE KEY-----\nMIIEow...\n-----END RSA PRIVATE KEY-----\n"
        #expect(PrivateKey.inspect(text) == KeyInspection(isEncrypted: false))
    }

    @Test func legacyEncryptedPemIsEncrypted() {
        let text = "-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\nDEK-Info: AES-128-CBC,AB\n\nMIIE\n-----END RSA PRIVATE KEY-----\n"
        #expect(PrivateKey.inspect(text) == KeyInspection(isEncrypted: true))
    }

    @Test func pkcs8EncryptedHeaderIsEncrypted() {
        let text = "-----BEGIN ENCRYPTED PRIVATE KEY-----\nMIIF\n-----END ENCRYPTED PRIVATE KEY-----\n"
        #expect(PrivateKey.inspect(text) == KeyInspection(isEncrypted: true))
    }

    @Test func publicKeysAndPlainTextAreNotPrivateKeys() {
        #expect(PrivateKey.inspect("ssh-ed25519 AAAAC3Nza... user@host\n") == nil)
        #expect(PrivateKey.inspect("-----BEGIN PUBLIC KEY-----\nMIIB\n-----END PUBLIC KEY-----\n") == nil)
        #expect(PrivateKey.inspect("Merhaba dünya") == nil)
        #expect(PrivateKey.inspect("") == nil)
    }

    @Test func truncatedOpensshBodyDoesNotCrash() {
        #expect(PrivateKey.inspect("-----BEGIN OPENSSH PRIVATE KEY-----\nb3Bl\n") != nil)
    }
}

struct SSHAuditTests {
    private let privateHead = "-----BEGIN RSA PRIVATE KEY-----\nMIIEow\n-----END RSA PRIVATE KEY-----\n"

    @Test func looseDirectoryPermissionIsMedium() {
        let findings = SSHAudit.evaluate(dirPath: "/h/.ssh", dirMode: 0o755, entries: [])
        #expect(findings.map(\.kind) == [.sshDirectoryPermissions])
        #expect(findings.first?.severity == .medium)
    }

    @Test func correctDirectoryPermissionGivesNoFinding() {
        #expect(SSHAudit.evaluate(dirPath: "/h/.ssh", dirMode: 0o700, entries: []).isEmpty)
    }

    @Test func privateKeyReadableByOthersIsHigh() {
        let entries = [SSHEntry(path: "/h/.ssh/id_rsa", mode: 0o644, head: privateHead)]
        let findings = SSHAudit.evaluate(dirPath: "/h/.ssh", dirMode: 0o700, entries: entries)
        #expect(findings.map(\.kind) == [.privateKeyPermissions])
        #expect(findings.first?.severity == .high)
        #expect(findings.first?.detail.contains("644") == true)
    }

    @Test func unencryptedKeyWithGoodPermissionIsInfoOnly() {
        let entries = [SSHEntry(path: "/h/.ssh/id_rsa", mode: 0o600, head: privateHead)]
        let findings = SSHAudit.evaluate(dirPath: "/h/.ssh", dirMode: 0o700, entries: entries)
        #expect(findings.map(\.kind) == [.unencryptedPrivateKey])
        #expect(findings.first?.severity == .info)
    }

    @Test func encryptedKeyWithGoodPermissionIsFine() {
        let head = "-----BEGIN RSA PRIVATE KEY-----\nProc-Type: 4,ENCRYPTED\n\nMIIE\n"
        let entries = [SSHEntry(path: "/h/.ssh/id_rsa", mode: 0o600, head: head)]
        #expect(SSHAudit.evaluate(dirPath: "/h/.ssh", dirMode: 0o700, entries: entries).isEmpty)
    }

    @Test func looseUnencryptedKeyReportsOnlyThePermissionFinding() {
        let entries = [SSHEntry(path: "/h/.ssh/id_rsa", mode: 0o644, head: privateHead)]
        let findings = SSHAudit.evaluate(dirPath: "/h/.ssh", dirMode: 0o700, entries: entries)
        #expect(findings.count == 1)
    }

    @Test func nonKeyFilesAreIgnored() {
        let entries = [
            SSHEntry(path: "/h/.ssh/config", mode: 0o644, head: "Host *\n  ForwardAgent no\n"),
            SSHEntry(path: "/h/.ssh/id_rsa.pub", mode: 0o644, head: "ssh-rsa AAAA user\n"),
        ]
        #expect(SSHAudit.evaluate(dirPath: "/h/.ssh", dirMode: 0o700, entries: entries).isEmpty)
    }
}

struct CredentialAuditTests {
    private func spec(_ path: String) -> CredentialSpec {
        CredentialSpec.all.first { $0.relativePath == path }!
    }

    @Test func npmrcWithTokenAndGoodPermissionIsInfo() {
        let finding = CredentialAudit.evaluate(path: "/h/.npmrc", spec: spec(".npmrc"), mode: 0o600,
                                               head: "//registry.npmjs.org/:_authToken=npm_abc123\n")
        #expect(finding?.kind == .credentialFile)
        #expect(finding?.severity == .info)
    }

    @Test func npmrcWithoutTokenGivesNothing() {
        #expect(CredentialAudit.evaluate(path: "/h/.npmrc", spec: spec(".npmrc"), mode: 0o644, head: "registry=https://x\n") == nil)
    }

    @Test func credentialFileOpenToOthersIsHigh() {
        let finding = CredentialAudit.evaluate(path: "/h/.aws/credentials", spec: spec(".aws/credentials"), mode: 0o644,
                                               head: "[default]\naws_secret_access_key = abc\n")
        #expect(finding?.kind == .credentialWorldReadable)
        #expect(finding?.severity == .high)
    }

    @Test func gitCredentialsStoreIsMediumEvenWithGoodPermission() {
        let finding = CredentialAudit.evaluate(path: "/h/.git-credentials", spec: spec(".git-credentials"), mode: 0o600,
                                               head: "https://user:pass@github.com\n")
        #expect(finding?.kind == .plaintextCredentialStore)
        #expect(finding?.severity == .medium)
    }

    @Test func detailNeverContainsTheSecret() {
        let finding = CredentialAudit.evaluate(path: "/h/.git-credentials", spec: spec(".git-credentials"), mode: 0o600,
                                               head: "https://user:SUPERSECRETPASS@github.com\n")
        #expect(finding?.detail.contains("SUPERSECRETPASS") == false)
    }

    @Test func dockerConfigNeedsAnAuthEntry() {
        #expect(CredentialAudit.evaluate(path: "/h/.docker/config.json", spec: spec(".docker/config.json"), mode: 0o600,
                                         head: "{\"credsStore\":\"osxkeychain\"}") == nil)
        #expect(CredentialAudit.evaluate(path: "/h/.docker/config.json", spec: spec(".docker/config.json"), mode: 0o600,
                                         head: "{\"auths\":{\"x\":{\"auth\":\"dXNlcjpwYXNz\"}}}")?.kind == .credentialFile)
    }
}

struct EnvAuditTests {
    private let secrets = [EnvFile.Secret(key: "DB_PASSWORD", valueLength: 12), EnvFile.Secret(key: "APP_KEY", valueLength: 40)]

    @Test func trackedEnvFileIsHigh() {
        let findings = EnvAudit.evaluate(path: "/p/.env", secrets: secrets, mode: 0o600,
                                         git: GitStatus(inRepo: true, tracked: true, ignored: false))
        #expect(findings.map(\.kind) == [.envTracked])
        #expect(findings.first?.severity == .high)
    }

    @Test func detailListsKeyNamesButNoValues() {
        let findings = EnvAudit.evaluate(path: "/p/.env", secrets: secrets, mode: 0o600,
                                         git: GitStatus(inRepo: true, tracked: true, ignored: false))
        let detail = findings.first?.detail ?? ""
        #expect(detail.contains("DB_PASSWORD"))
        #expect(detail.contains("APP_KEY"))
    }

    @Test func ignoredEnvFileWithGoodPermissionIsFine() {
        let findings = EnvAudit.evaluate(path: "/p/.env", secrets: secrets, mode: 0o600,
                                         git: GitStatus(inRepo: true, tracked: false, ignored: true))
        #expect(findings.isEmpty)
    }

    @Test func envFileOutsideGitWithGoodPermissionIsFine() {
        let findings = EnvAudit.evaluate(path: "/p/.env", secrets: secrets, mode: 0o600,
                                         git: GitStatus(inRepo: false, tracked: false, ignored: false))
        #expect(findings.isEmpty)
    }

    @Test func notIgnoredInsideGitRepoIsMedium() {
        let findings = EnvAudit.evaluate(path: "/p/.env", secrets: secrets, mode: 0o600,
                                         git: GitStatus(inRepo: true, tracked: false, ignored: false))
        #expect(findings.map(\.kind) == [.envNotIgnored])
        #expect(findings.first?.severity == .medium)
    }

    @Test func worldReadableSecretFileIsHigh() {
        let findings = EnvAudit.evaluate(path: "/p/.env", secrets: secrets, mode: 0o644,
                                         git: GitStatus(inRepo: true, tracked: false, ignored: true))
        #expect(findings.map(\.kind) == [.envWorldReadable])
        #expect(findings.first?.severity == .high)
    }

    @Test func fileWithoutSecretsGivesNothing() {
        let findings = EnvAudit.evaluate(path: "/p/.env", secrets: [], mode: 0o644,
                                         git: GitStatus(inRepo: true, tracked: true, ignored: false))
        #expect(findings.isEmpty)
    }

    @Test func trackedAndWorldReadableGiveTwoFindings() {
        let findings = EnvAudit.evaluate(path: "/p/.env", secrets: secrets, mode: 0o644,
                                         git: GitStatus(inRepo: true, tracked: true, ignored: false))
        #expect(Set(findings.map(\.kind)) == [.envTracked, .envWorldReadable])
    }

    @Test func longKeyListIsShortened() {
        let many = (1...8).map { EnvFile.Secret(key: "SECRET_\($0)", valueLength: 10) }
        let findings = EnvAudit.evaluate(path: "/p/.env", secrets: many, mode: 0o600,
                                         git: GitStatus(inRepo: true, tracked: true, ignored: false))
        #expect(findings.first?.detail.contains("+3") == true)
    }
}

struct SuggestedCommandTests {
    private func finding(_ kind: SecretKind, _ path: String) -> SecretFinding {
        SecretFinding(kind: kind, severity: .high, path: path, detail: "")
    }

    @Test func permissionFindingsSuggestChmod() {
        #expect(finding(.privateKeyPermissions, "/h/.ssh/id_rsa").suggestedCommand == "chmod 600 '/h/.ssh/id_rsa'")
        #expect(finding(.credentialWorldReadable, "/h/.aws/credentials").suggestedCommand == "chmod 600 '/h/.aws/credentials'")
        #expect(finding(.envWorldReadable, "/p/.env").suggestedCommand == "chmod 600 '/p/.env'")
        #expect(finding(.sshDirectoryPermissions, "/h/.ssh").suggestedCommand == "chmod 700 '/h/.ssh'")
    }

    @Test func trackedEnvSuggestsRemovingItFromTheIndex() {
        #expect(finding(.envTracked, "/p/.env").suggestedCommand == "git -C '/p' rm --cached -- '.env'")
    }

    @Test func unignoredEnvSuggestsAGitignoreLine() {
        #expect(finding(.envNotIgnored, "/p/.env.local").suggestedCommand == "echo '.env.local' >> '/p/.gitignore'")
    }

    @Test func unencryptedKeySuggestsSettingAPassphrase() {
        #expect(finding(.unencryptedPrivateKey, "/h/.ssh/id_ed25519").suggestedCommand == "ssh-keygen -p -f '/h/.ssh/id_ed25519'")
    }

    @Test func informationalFindingsHaveNoCommand() {
        #expect(finding(.credentialFile, "/h/.npmrc").suggestedCommand == nil)
        #expect(finding(.plaintextCredentialStore, "/h/.git-credentials").suggestedCommand == nil)
    }

    @Test func singleQuotesInPathsAreEscaped() {
        #expect(finding(.envWorldReadable, "/h/it's/.env").suggestedCommand == "chmod 600 '/h/it'\\''s/.env'")
    }
}

struct SecretSummaryTests {
    private func finding(_ severity: Severity, _ path: String) -> SecretFinding {
        SecretFinding(kind: .envTracked, severity: severity, path: path, detail: "")
    }

    @Test func alertCountIncludesHighAndMediumOnly() {
        let list = [finding(.high, "a"), finding(.medium, "b"), finding(.info, "c"), finding(.info, "d")]
        #expect(SecretFinding.alertCount(list) == 2)
    }

    @Test func sortingPutsHighFirstThenByPath() {
        let list = [finding(.info, "z"), finding(.high, "b"), finding(.high, "a"), finding(.medium, "m")]
        let sorted = SecretFinding.sorted(list)
        #expect(sorted.map(\.path) == ["a", "b", "m", "z"])
    }

    @Test func everyKindHasATitle() {
        for kind in SecretKind.allCases { #expect(!kind.title.isEmpty) }
    }
}

struct TokenPatternTests {
    private func rep(_ char: String, _ count: Int) -> String { String(repeating: char, count: count) }

    @Test func knownTokenFormatsAreNamed() {
        #expect(TokenPattern.match("ghp_" + rep("a", 36)) == "GitHub")
        #expect(TokenPattern.match("github_pat_" + rep("A", 30)) == "GitHub")
        #expect(TokenPattern.match("sk_live_" + rep("a", 30)) == "Stripe")
        #expect(TokenPattern.match("xoxb-" + rep("1", 20)) == "Slack")
        #expect(TokenPattern.match("AKIA" + rep("A", 16)) == "AWS")
        #expect(TokenPattern.match("AIza" + rep("a", 35)) == "Google")
        #expect(TokenPattern.match("glpat-" + rep("a", 20)) == "GitLab")
        #expect(TokenPattern.match("npm_" + rep("a", 36)) == "npm")
        #expect(TokenPattern.match("sk-ant-" + rep("a", 30)) == "Anthropic")
        #expect(TokenPattern.match("sk-" + rep("a", 40)) == "OpenAI")
    }

    @Test func ordinaryValuesAreNotTokens() {
        #expect(TokenPattern.match("hello") == nil)
        #expect(TokenPattern.match("ghp_short") == nil)
        #expect(TokenPattern.match("AKIA" + rep("a", 16)) == nil)
        #expect(TokenPattern.match("") == nil)
    }

    @Test func tokenInAnInnocentlyNamedKeyIsStillFound() {
        let secrets = EnvFile.secrets(in: "DEPLOY_REF=ghp_" + rep("a", 36))
        #expect(secrets.map(\.key) == ["DEPLOY_REF"])
        #expect(secrets.first?.token == "GitHub")
    }

    @Test func plainInnocentKeyStaysIgnored() {
        #expect(EnvFile.secrets(in: "APP_NAME=nobet").isEmpty)
    }

    @Test func findingDetailNamesTheTokenButNeverTheValue() {
        let value = "ghp_" + rep("z", 36)
        let secrets = EnvFile.secrets(in: "DEPLOY_REF=" + value)
        let findings = EnvAudit.evaluate(path: "/p/.env", secrets: secrets, mode: 0o644, git: GitStatus(inRepo: false, tracked: false, ignored: false))
        #expect(findings.contains { $0.detail.contains("GitHub") })
        #expect(findings.allSatisfy { !$0.detail.contains(value) })
    }
}

struct RotationAdviceTests {
    private func finding(_ kind: SecretKind, detail: String = "") -> SecretFinding {
        SecretFinding(kind: kind, severity: .high, path: "/p/.env", detail: detail)
    }

    @Test func trackedEnvFileNeedsRotationBecauseHistoryKeepsTheSecret() {
        let advice = finding(.envTracked, detail: "git'e eklenmiş. Sırlar: DB_PASSWORD").rotationAdvice
        #expect(advice?.contains("geçmişinde") == true)
        #expect(advice?.contains("yenileyin") == true)
    }

    @Test func providerNamedInTheDetailGetsAProviderHint() {
        let advice = finding(.envWorldReadable, detail: "izin 644. Sırlar: DEPLOY_REF (GitHub)").rotationAdvice
        #expect(advice?.contains("GitHub") == true)
        #expect(advice?.contains("iptal") == true)
    }

    @Test func plainPermissionIssueNeedsNoRotation() {
        #expect(finding(.privateKeyPermissions).rotationAdvice == nil)
        #expect(finding(.envWorldReadable, detail: "izin 644. Sırlar: DB_PASSWORD").rotationAdvice == nil)
    }

    @Test func everyKnownProviderHasAHint() {
        for name in TokenPattern.providerNames {
            #expect(TokenPattern.rotationHint(for: name) != nil)
        }
    }
}

struct EnvHistoryTests {
    private let secrets = [EnvFile.Secret(key: "DB_PASSWORD", valueLength: 12)]
    private let ignoredNow = GitStatus(inRepo: true, tracked: false, ignored: true)

    @Test func fileOnlyInHistoryIsMedium() {
        let findings = EnvAudit.evaluate(path: "/p/.env", secrets: secrets, mode: 0o600, git: ignoredNow, inHistory: true)
        #expect(findings.map(\.kind) == [.envInHistory])
        #expect(findings[0].severity == .medium)
        #expect(findings[0].detail.contains("DB_PASSWORD"))
        #expect(findings[0].rotationAdvice?.contains("yenileyin") == true)
    }

    @Test func noHistoryNoFinding() {
        #expect(EnvAudit.evaluate(path: "/p/.env", secrets: secrets, mode: 0o600, git: ignoredNow, inHistory: false).isEmpty)
    }

    @Test func trackedFileKeepsItsHighFindingAndAddsNoSecondOne() {
        let tracked = GitStatus(inRepo: true, tracked: true, ignored: false)
        let findings = EnvAudit.evaluate(path: "/p/.env", secrets: secrets, mode: 0o600, git: tracked, inHistory: true)
        #expect(findings.map(\.kind) == [.envTracked])
    }

    @Test func historyIsNotAskedOutsideARepo() {
        let outside = GitStatus(inRepo: false, tracked: false, ignored: false)
        #expect(EnvAudit.evaluate(path: "/p/.env", secrets: secrets, mode: 0o600, git: outside, inHistory: true).isEmpty)
    }
}
