import Foundation
import Testing
@testable import Nobet

private let base = """
    #df
    Filesystem 1024-blocks Used Available Capacity Mounted on
    /dev/vda1 100 50 50 50% /
    """

private func output(backup: String? = nil, db: String? = nil) -> String {
    var text = base
    if let backup { text += "\n#backup\n" + backup }
    if let db { text += "\n#db\n" + db }
    return text
}

struct RemoteBackupTests {
    @Test func freshBackupRaisesNothing() throws {
        let metrics = try #require(LinuxParser.metrics(from: output(backup: "1800000000\n1800003600")))
        #expect(metrics.backup == BackupState(newestEpoch: 1_800_000_000, serverEpoch: 1_800_003_600))
        #expect(RemoteHealth.issues(for: metrics).isEmpty)
    }

    @Test func oldBackupIsMedium() throws {
        let metrics = try #require(LinuxParser.metrics(from: output(backup: "1800000000\n\(1_800_000_000 + 3 * 86_400)")))
        let issue = try #require(RemoteHealth.issues(for: metrics).first)
        #expect(issue.title == "Yedek eski")
        #expect(issue.severity == .medium)
        #expect(issue.detail.contains("72"))
    }

    @Test func thresholdIsExactlyFortyEightHours() throws {
        let edge = try #require(LinuxParser.metrics(from: output(backup: "1000\n\(1000 + 48 * 3600)")))
        #expect(RemoteHealth.issues(for: edge).isEmpty)
        let over = try #require(LinuxParser.metrics(from: output(backup: "1000\n\(1000 + 48 * 3600 + 1)")))
        #expect(RemoteHealth.issues(for: over).count == 1)
    }

    @Test func emptyFolderMeansNoBackup() throws {
        let metrics = try #require(LinuxParser.metrics(from: output(backup: "\n1800003600")))
        #expect(metrics.backup == BackupState(newestEpoch: nil, serverEpoch: 1_800_003_600))
        let issue = try #require(RemoteHealth.issues(for: metrics).first)
        #expect(issue.title == "Yedek bulunamadı")
        #expect(issue.severity == .medium)
    }

    @Test func fractionalFindOutputIsAccepted() throws {
        let metrics = try #require(LinuxParser.metrics(from: output(backup: "1800000000.1234567890\n1800000100")))
        #expect(metrics.backup?.newestEpoch == 1_800_000_000)
    }

    @Test func missingServerClockMeansUnknown() throws {
        let metrics = try #require(LinuxParser.metrics(from: output(backup: "1800000000")))
        #expect(metrics.backup == nil)
        #expect(RemoteHealth.issues(for: metrics).isEmpty)
    }

    @Test func noBackupSectionMeansNoCheck() throws {
        #expect(try #require(LinuxParser.metrics(from: output())).backup == nil)
    }

    @Test func backupPathValidation() {
        #expect(SSHProfile.isSafeBackupPath("/var/backups"))
        #expect(SSHProfile.isSafeBackupPath("/home/yedek/db-dump_1.2"))
        #expect(!SSHProfile.isSafeBackupPath("var/backups"))
        #expect(!SSHProfile.isSafeBackupPath("/"))
        #expect(!SSHProfile.isSafeBackupPath("/var/../etc"))
        #expect(!SSHProfile.isSafeBackupPath("/var/b ackups"))
        #expect(!SSHProfile.isSafeBackupPath("/var/b'; rm -rf /"))
        #expect(!SSHProfile.isSafeBackupPath("/var/$(id)"))
        #expect(!SSHProfile.isSafeBackupPath(""))
        #expect(!SSHProfile.isSafeBackupPath("/" + String(repeating: "a", count: 300)))
    }

    @Test func profileRefusesAnUnsafeBackupPathAndKeepsASafeOne() {
        #expect(SSHProfile.make(name: "", host: "a.com", port: 22, user: "root", auth: .key, services: [], backupPath: "/x;y") == nil)
        let ok = SSHProfile.make(name: "", host: "a.com", port: 22, user: "root", auth: .key, services: [], backupPath: "  /var/backups ")
        #expect(ok?.backupPath == "/var/backups")
        let empty = SSHProfile.make(name: "", host: "a.com", port: 22, user: "root", auth: .key, services: [], backupPath: "   ")
        #expect(empty?.backupPath == nil)
    }

    @Test func scriptAddsBackupSectionOnlyWhenAPathIsGiven() {
        #expect(!RemoteScript.linux(services: []).contains("#backup"))
        let script = RemoteScript.linux(services: [], backupPath: "/var/backups")
        #expect(script.contains("#backup"))
        #expect(script.contains("find '/var/backups'"))
        #expect(!RemoteScript.linux(services: [], backupPath: "/x;rm -rf /").contains("#backup"))
    }

    @Test func profilesSavedBeforeBackupStillDecode() throws {
        let old = #"{"id":"1","name":"A","host":"a.com","port":22,"user":"root","auth":"key","services":[]}"#
        #expect(try JSONDecoder().decode(SSHProfile.self, from: Data(old.utf8)).backupPath == nil)
    }
}

struct RemoteDatabaseTests {
    @Test func aliveDatabasesRaiseNothing() throws {
        let metrics = try #require(LinuxParser.metrics(from: output(db: "pg:/var/run/postgresql:5432 - accepting connections\nmysql:mysqld is alive")))
        #expect(metrics.databases == [DatabaseProbe(engine: .postgres, up: true), DatabaseProbe(engine: .mysql, up: true)])
        #expect(RemoteHealth.issues(for: metrics).isEmpty)
    }

    @Test func accessDeniedMeansTheServerIsUp() throws {
        let metrics = try #require(LinuxParser.metrics(from: output(db: "mysql:mysqladmin: connect to server at 'localhost' failed\nmysql:error: 'Access denied for user 'root'@'localhost' (using password: NO)'")))
        #expect(metrics.databases?.first?.up == true)
    }

    @Test func deadMysqlIsHigh() throws {
        let metrics = try #require(LinuxParser.metrics(from: output(db: "mysql:mysqladmin: connect to server at 'localhost' failed\nmysql:error: 'Can't connect to local MySQL server through socket'")))
        let issue = try #require(RemoteHealth.issues(for: metrics).first)
        #expect(issue.title == "Veritabanı yanıt vermiyor: MySQL/MariaDB")
        #expect(issue.severity == .high)
    }

    @Test func deadPostgresIsHigh() throws {
        let metrics = try #require(LinuxParser.metrics(from: output(db: "pg:/var/run/postgresql:5432 - no response")))
        let issue = try #require(RemoteHealth.issues(for: metrics).first)
        #expect(issue.title == "Veritabanı yanıt vermiyor: PostgreSQL")
        #expect(issue.severity == .high)
    }

    @Test func rejectingPostgresIsHigh() throws {
        let metrics = try #require(LinuxParser.metrics(from: output(db: "pg:/tmp:5432 - rejecting connections")))
        #expect(metrics.databases?.first?.up == false)
    }

    @Test func absentToolsGiveNoProbes() throws {
        let metrics = try #require(LinuxParser.metrics(from: output(db: "")))
        #expect(metrics.databases == [])
        #expect(RemoteHealth.issues(for: metrics).isEmpty)
        #expect(try #require(LinuxParser.metrics(from: output())).databases == nil)
    }

    @Test func scriptReadsDatabasesAndStaysReadOnly() {
        let script = RemoteScript.linux(services: [])
        #expect(script.contains("#db"))
        #expect(script.contains("pg_isready"))
        #expect(script.contains("mysqladmin ping"))
        #expect(!script.contains("mysql -"))
        #expect(!script.contains("psql"))
        #expect(!script.contains("DROP"))
    }
}

struct RemoteJournalTests {
    private func output(_ journal: String?) -> String {
        var text = "#df\nFilesystem 1024-blocks Used Available Capacity Mounted on\n/dev/vda1 100 50 50 50% /"
        if let journal { text += "\n#journal\n" + journal }
        return text
    }

    @Test func errorCountIsParsed() throws {
        let metrics = try #require(LinuxParser.metrics(from: output("37\n")))
        #expect(metrics.errorLogs == 37)
        #expect(RemoteHealth.issues(for: metrics).isEmpty)
    }

    @Test func manyErrorsRaiseAMediumIssue() throws {
        let metrics = try #require(LinuxParser.metrics(from: output("150")))
        let issue = try #require(RemoteHealth.issues(for: metrics).first)
        #expect(issue.title == "Log hata sayısı yüksek")
        #expect(issue.severity == .medium)
        #expect(issue.detail.contains("150"))
    }

    @Test func thresholdIsExactlyOneHundred() throws {
        #expect(RemoteHealth.issues(for: try #require(LinuxParser.metrics(from: output("99")))).isEmpty)
        #expect(RemoteHealth.issues(for: try #require(LinuxParser.metrics(from: output("100")))).count == 1)
    }

    @Test func missingOrBrokenSectionMeansUnknown() throws {
        #expect(try #require(LinuxParser.metrics(from: output(nil))).errorLogs == nil)
        #expect(try #require(LinuxParser.metrics(from: output("bozuk"))).errorLogs == nil)
    }

    @Test func scriptReadsTheJournalWithoutChangingIt() {
        let script = RemoteScript.linux(services: [])
        #expect(script.contains("#journal"))
        #expect(script.contains("journalctl -p err --since '1 hour ago'"))
        #expect(!script.contains("--vacuum"))
        #expect(!script.contains("--rotate"))
    }
}
