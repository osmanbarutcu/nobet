import Foundation

struct DiskUsage: Equatable {
    let mount: String
    let usedPercent: Int
}

struct MemoryUsage: Equatable {
    let totalMB: Int
    let availableMB: Int
    let swapTotalMB: Int
    let swapUsedMB: Int

    var usedPercent: Int {
        totalMB > 0 ? Int((Double(totalMB - availableMB) / Double(totalMB) * 100).rounded()) : 0
    }
}

enum ServiceState: String, Equatable {
    case active, inactive, failed, missing
}

/// `docker ps -a` satırı. Değerler sunucudan gelir ve yalnızca gösterilir.
struct RemoteContainer: Equatable {
    let name: String
    let state: String
    let status: String
}

/// En yeni yedek dosyasının zamanı ve sunucu saati. Yaş, sunucu saatiyle hesaplanır, Mac saati karışmaz.
struct BackupState: Equatable {
    let newestEpoch: Int?
    let serverEpoch: Int
}

struct DatabaseProbe: Equatable {
    enum Engine: String, Equatable {
        case postgres, mysql

        var title: String { self == .postgres ? "PostgreSQL" : "MySQL/MariaDB" }
    }

    let engine: Engine
    let up: Bool
}

/// SSH ve ağ sertleştirme durumu. Değer okunamadıysa `nil` kalır ve sorun sayılmaz.
struct SecurityPosture: Equatable {
    var permitRootLogin: String?
    var passwordAuthentication: Bool?
    var fail2banActive: Bool?
    var failedLogins: Int?
    var publicPorts: [Int]
    var rebootRequired: Bool
}

/// Uzak sunucudan okunan değerler. Yalnızca bellekte durur, diske yazılmaz.
struct RemoteMetrics: Equatable {
    var disks: [DiskUsage]
    var memory: MemoryUsage?
    var load: [Double]?
    var cores: Int?
    var uptimeSeconds: Int?
    var services: [String: ServiceState]
    var failedUnits: [String]
    var osName: String? = nil
    var security: SecurityPosture? = nil
    /// `nil`: docker bölümü okunmadı. Boş liste: konteyner yok veya docker kurulu değil.
    var containers: [RemoteContainer]? = nil
    /// `nil`: yedek klasörü tanımlı değil veya okunamadı.
    var backup: BackupState? = nil
    /// `nil`: veritabanı bölümü okunmadı. Boş liste: sunucuda `pg_isready` ve `mysqladmin` yok.
    var databases: [DatabaseProbe]? = nil
    /// Son 1 saatteki hata düzeyi günlük satırı. `nil`: okunamadı.
    var errorLogs: Int? = nil
}

/// Sabit, salt okunur Linux komutlarının çıktısını ayrıştırır. Beklenmeyen çıktı boş sonuç verir, hata fırlatmaz.
enum LinuxParser {
    private static let pseudoFilesystems: Set<String> = ["tmpfs", "devtmpfs", "udev", "overlay", "squashfs", "none", "shm", "efivarfs"]
    private static let pseudoMountPrefixes = ["/dev", "/run", "/sys", "/proc", "/var/lib/docker", "/var/lib/snapd", "/snap"]

    /// `RemoteScript.linux` çıktısını bölümlere ayırıp birleştirir. İşaretçi yoksa `nil` verir.
    static func metrics(from output: String) -> RemoteMetrics? {
        var sections: [String: [String]] = [:]
        var current: String?
        for line in output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init) {
            if line.hasPrefix("#"), ["os", "df", "free", "load", "uptime", "nproc", "failed", "svc", "sshd", "f2b", "listen", "lastb", "pending", "docker", "backup", "db", "journal"].contains(String(line.dropFirst())) {
                current = String(line.dropFirst())
                sections[current!] = []
            } else if let key = current {
                sections[key, default: []].append(line)
            }
        }
        guard let df = sections["df"] else { return nil }
        func text(_ key: String) -> String { (sections[key] ?? []).joined(separator: "\n") }
        var services: [String: ServiceState] = [:]
        for line in sections["svc"] ?? [] {
            guard let split = line.firstIndex(of: "=") else { continue }
            services[String(line[..<split])] = serviceState(String(line[line.index(after: split)...]))
        }
        let osLine = (sections["os"] ?? []).first { $0.hasPrefix("PRETTY_NAME=") }
        return RemoteMetrics(
            disks: disks(df.joined(separator: "\n")),
            memory: memory(text("free")),
            load: load(text("load")),
            cores: Int(text("nproc").trimmingCharacters(in: .whitespacesAndNewlines)),
            uptimeSeconds: uptimeSeconds(text("uptime")),
            services: services,
            failedUnits: failedUnits(text("failed")),
            osName: osLine.map { String($0.dropFirst("PRETTY_NAME=".count)).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) },
            security: ["sshd", "f2b", "listen", "lastb", "pending"].contains(where: { sections[$0] != nil })
                ? posture(sshd: text("sshd"), fail2ban: text("f2b"), listen: text("listen"), lastb: text("lastb"), reboot: text("pending"))
                : nil,
            containers: sections["docker"].map { containers($0.joined(separator: "\n")) },
            backup: sections["backup"].flatMap(backup),
            databases: sections["db"].map { databases($0.joined(separator: "\n")) },
            errorLogs: Int(text("journal").trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// İlk satır en yeni dosyanın zamanı (boş olabilir), ikinci satır sunucu saati. Sunucu saati yoksa sonuç `nil` olur.
    static func backup(_ lines: [String]) -> BackupState? {
        var rows = lines.map { $0.trimmingCharacters(in: .whitespaces) }
        while rows.last?.isEmpty == true { rows.removeLast() }
        guard rows.count >= 2, let server = Int(rows[1]) else { return nil }
        return BackupState(newestEpoch: Double(rows[0]).map { Int($0) }, serverEpoch: server)
    }

    /// `pg:` ve `mysql:` önekli satırlar. Motor, yanıt veren herhangi bir satır varsa ayakta sayılır.
    /// `Access denied` sunucunun ayakta olduğunu gösterir, parola yalnızca yetkiyi reddeder.
    static func databases(_ output: String) -> [DatabaseProbe] {
        var order: [DatabaseProbe.Engine] = []
        var alive: [DatabaseProbe.Engine: Bool] = [:]
        for line in output.split(whereSeparator: \.isNewline).map(String.init) {
            let engine: DatabaseProbe.Engine
            if line.hasPrefix("pg:") { engine = .postgres } else if line.hasPrefix("mysql:") { engine = .mysql } else { continue }
            if !order.contains(engine) { order.append(engine) }
            let up = line.contains("accepting connections") || line.contains("is alive") || line.contains("Access denied")
            alive[engine] = (alive[engine] ?? false) || up
        }
        return order.map { DatabaseProbe(engine: $0, up: alive[$0] ?? false) }
    }

    /// `docker ps -a --format '{{.Names}}|{{.State}}|{{.Status}}'` çıktısı. Biçimi bozuk satır atlanır.
    static func containers(_ output: String) -> [RemoteContainer] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count == 3, !fields[0].isEmpty, !fields[1].isEmpty else { return nil }
            return RemoteContainer(name: fields[0], state: fields[1], status: fields[2])
        }
    }

    /// `sshd -T` (veya `sshd_config`) çıktısından ilgili anahtarlar, `ss -tln`, `lastb` ve yeniden başlatma bayrağı.
    static func posture(sshd: String, fail2ban: String, listen: String, lastb: String, reboot: String) -> SecurityPosture {
        var rootLogin: String?
        var password: Bool?
        for line in sshd.split(whereSeparator: \.isNewline) {
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard parts.count >= 2 else { continue }
            switch parts[0].lowercased() {
            case "permitrootlogin": rootLogin = parts[1].lowercased()
            case "passwordauthentication": password = parts[1].lowercased() == "yes"
            default: break
            }
        }
        let f2b: Bool?
        switch fail2ban.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "active": f2b = true
        case "inactive", "failed": f2b = false
        default: f2b = nil
        }
        return SecurityPosture(
            permitRootLogin: rootLogin, passwordAuthentication: password, fail2banActive: f2b,
            failedLogins: Int(lastb.trimmingCharacters(in: .whitespacesAndNewlines)),
            publicPorts: publicPorts(listen),
            rebootRequired: reboot.trimmingCharacters(in: .whitespacesAndNewlines) == "yes")
    }

    /// `ss -tln` çıktısında tüm arayüzlerde veya dış adreste dinleyen portlar. Yalnızca 127.x ve ::1 yerel sayılır.
    static func publicPorts(_ output: String) -> [Int] {
        var ports = Set<Int>()
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.first == "LISTEN", fields.count >= 4, let colon = fields[3].lastIndex(of: ":"),
                  let port = Int(fields[3][fields[3].index(after: colon)...]) else { continue }
            let host = String(fields[3][..<colon])
            if host.hasPrefix("127.") || host == "[::1]" || host == "::1" { continue }
            ports.insert(port)
        }
        return ports.sorted()
    }

    /// `df -P` çıktısı. Sanal dosya sistemleri atlanır.
    static func disks(_ output: String) -> [DiskUsage] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 5, omittingEmptySubsequences: true)
            guard fields.count == 6, fields[4].hasSuffix("%"), let percent = Int(fields[4].dropLast()) else { return nil }
            let mount = fields[5].trimmingCharacters(in: .whitespaces)
            guard !pseudoFilesystems.contains(String(fields[0])), !fields[0].hasPrefix("/dev/loop"), !pseudoMountPrefixes.contains(where: { mount == $0 || mount.hasPrefix($0 + "/") }) else {
                return nil
            }
            return DiskUsage(mount: mount, usedPercent: percent)
        }
    }

    /// `free -m` çıktısı. `available` sütunu yoksa sonuç `nil` olur.
    static func memory(_ output: String) -> MemoryUsage? {
        let lines = output.split(whereSeparator: \.isNewline).map { $0.split(whereSeparator: \.isWhitespace).map(String.init) }
        guard let mem = lines.first(where: { $0.first == "Mem:" }), mem.count >= 7,
              let total = Int(mem[1]), let available = Int(mem[6]) else { return nil }
        let swap = lines.first(where: { $0.first == "Swap:" })
        return MemoryUsage(totalMB: total, availableMB: available, swapTotalMB: swap.flatMap { Int($0[1]) } ?? 0,
                           swapUsedMB: swap.flatMap { $0.count > 2 ? Int($0[2]) : nil } ?? 0)
    }

    /// `/proc/loadavg` çıktısı: 1, 5 ve 15 dakikalık yük.
    static func load(_ output: String) -> [Double]? {
        let values = output.split(whereSeparator: \.isWhitespace).prefix(3).compactMap { Double($0) }
        return values.count == 3 ? values : nil
    }

    /// `/proc/uptime` çıktısı: açık kalma süresi, saniye.
    static func uptimeSeconds(_ output: String) -> Int? {
        output.split(whereSeparator: \.isWhitespace).first.flatMap { Double($0) }.map { Int($0) }
    }

    /// `systemctl is-active` çıktısı. Bilinmeyen kelime `missing` sayılır.
    static func serviceState(_ output: String) -> ServiceState {
        switch output.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "active": return .active
        case "inactive": return .inactive
        case "failed": return .failed
        default: return .missing
        }
    }

    /// `systemctl --failed --no-legend` çıktısı: başarısız birim adları.
    static func failedUnits(_ output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let cleaned = line.drop { $0 == "●" || $0 == "*" || $0.isWhitespace }
            guard let name = cleaned.split(whereSeparator: \.isWhitespace).first, name.contains(".") else { return nil }
            return String(name)
        }
    }
}

struct RemoteIssue: Equatable {
    let title: String
    let detail: String
    let severity: Severity
    /// Kullanıcının kendi çalıştıracağı komut. Uygulama komutu çalıştırmaz.
    var suggestion: String? = nil
}

enum RemoteHealth {
    static let diskHigh = 90
    static let diskMedium = 80
    static let memoryLowPercent = 10
    static let loadPerCore = 2.0

    static func issues(for metrics: RemoteMetrics, thresholds: ServerThresholds = .standard) -> [RemoteIssue] {
        var found: [RemoteIssue] = []
        for (name, state) in metrics.services.sorted(by: { $0.key < $1.key }) where state != .active {
            let detail = state == .missing ? "Servis bulunamadı veya durumu okunamadı." : "Durum: \(state.rawValue)."
            found.append(RemoteIssue(title: "\(name) servisi çalışmıyor", detail: detail, severity: .high))
        }
        if !metrics.failedUnits.isEmpty {
            found.append(RemoteIssue(title: "Başarısız servis var", detail: metrics.failedUnits.joined(separator: ", "), severity: .medium))
        }
        for disk in metrics.disks where disk.usedPercent >= thresholds.diskMedium {
            found.append(RemoteIssue(title: "Disk dolu: \(disk.mount)", detail: "Kullanım %\(disk.usedPercent).",
                                     severity: disk.usedPercent >= thresholds.diskHigh ? .high : .medium))
        }
        if let memory = metrics.memory, memory.totalMB > 0, memory.availableMB * 100 / memory.totalMB < thresholds.memoryLowPercent {
            found.append(RemoteIssue(title: "Bellek azaldı", detail: "Kullanılabilir \(memory.availableMB) MB, toplam \(memory.totalMB) MB.", severity: .medium))
        }
        if let load = metrics.load, let cores = metrics.cores, cores > 0, load[0] / Double(cores) > thresholds.loadPerCore {
            found.append(RemoteIssue(title: "Yük yüksek", detail: "1 dakikalık yük \(load[0]), çekirdek \(cores).", severity: .medium))
        }
        if let errors = metrics.errorLogs, errors >= errorLogThreshold {
            found.append(RemoteIssue(title: "Log hata sayısı yüksek", detail: "Son 1 saatte \(errors) hata satırı.", severity: .medium))
        }
        return found + containerIssues(metrics.containers) + backupIssues(metrics.backup) + databaseIssues(metrics.databases) + securityIssues(metrics.security)
    }

    static let errorLogThreshold = 100
    static let backupMaxAgeSeconds = 48 * 3600

    static func backupIssues(_ backup: BackupState?) -> [RemoteIssue] {
        guard let backup else { return [] }
        guard let newest = backup.newestEpoch else {
            return [RemoteIssue(title: "Yedek bulunamadı", detail: "Yedek klasöründe dosya yok.", severity: .medium)]
        }
        let age = backup.serverEpoch - newest
        guard age > backupMaxAgeSeconds else { return [] }
        return [RemoteIssue(title: "Yedek eski", detail: "Son yedek \(age / 3600) saat önce. Sınır 48 saat.", severity: .medium)]
    }

    static func databaseIssues(_ databases: [DatabaseProbe]?) -> [RemoteIssue] {
        (databases ?? []).filter { !$0.up }.map {
            RemoteIssue(title: "Veritabanı yanıt vermiyor: \($0.engine.title)", detail: "Servis çalışıyor görünse bile sorguya yanıt gelmedi.", severity: .high)
        }
    }

    /// Temiz çıkış (kod 0) ve yeni oluşturulmuş konteyner sorun sayılmaz. Tek seferlik işler böyle biter.
    static func containerIssues(_ containers: [RemoteContainer]?) -> [RemoteIssue] {
        (containers ?? []).compactMap { container in
            switch container.state {
            case "restarting":
                return RemoteIssue(title: "Konteyner yeniden başlıyor: \(container.name)", detail: container.status, severity: .high)
            case "dead":
                return RemoteIssue(title: "Konteyner çalışmıyor: \(container.name)", detail: container.status, severity: .medium)
            case "exited" where !container.status.hasPrefix("Exited (0)"):
                return RemoteIssue(title: "Konteyner çalışmıyor: \(container.name)", detail: container.status, severity: .medium)
            case "running" where container.status.contains("(unhealthy)"):
                return RemoteIssue(title: "Konteyner sağlıksız: \(container.name)", detail: container.status, severity: .medium)
            default:
                return nil
            }
        }
    }

    private static let sshdReload = "sshd -t && systemctl reload sshd"

    static func securityIssues(_ security: SecurityPosture?) -> [RemoteIssue] {
        guard let security else { return [] }
        var found: [RemoteIssue] = []
        if security.permitRootLogin == "yes" {
            found.append(RemoteIssue(
                title: "Root ile SSH girişi açık",
                detail: "Root parolayla girebilir. Önce başka bir kullanıcıyla anahtar girişini deneyin, sonra kapatın.",
                severity: .high,
                suggestion: "sed -i 's/^#\\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config && \(sshdReload)"))
        }
        if security.passwordAuthentication == true {
            found.append(RemoteIssue(
                title: "SSH parola girişi açık",
                detail: "Parola denemesi mümkün. Anahtar girişi çalışıyorsa parolayı kapatın. Anahtar yoksa kendinizi dışarıda bırakırsınız.",
                severity: .medium,
                suggestion: "sed -i 's/^#\\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config && \(sshdReload)"))
        }
        if security.fail2banActive == false {
            found.append(RemoteIssue(
                title: "fail2ban çalışmıyor",
                detail: "Başarısız girişleri engelleyen servis kapalı veya kurulu değil.",
                severity: .medium,
                suggestion: "yum install -y epel-release fail2ban && systemctl enable --now fail2ban   # Debian/Ubuntu: apt install fail2ban"))
        }
        if security.rebootRequired {
            found.append(RemoteIssue(title: "Yeniden başlatma bekliyor", detail: "Güncelleme sonrası yeniden başlatma gerekiyor.", severity: .info))
        }
        return found
    }

    /// Menü çubuğu uyarısı: yüksek ve orta sorunlar.
    static func alertCount(_ issues: [RemoteIssue]) -> Int {
        issues.filter { $0.severity >= .medium }.count
    }
}

/// Windows PowerShell çıktısını ayrıştırır. Beklenmeyen çıktı `nil` verir, hata fırlatmaz.
enum WindowsParser {
    static func metrics(from output: String) -> RemoteMetrics? {
        var sections: [String: [String]] = [:]
        var current: String?
        for raw in output.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#"), ["os", "df", "mem", "uptime", "svc"].contains(String(line.dropFirst())) {
                current = String(line.dropFirst())
                sections[current!] = []
            } else if let key = current, !line.isEmpty {
                sections[key, default: []].append(line)
            }
        }
        guard let df = sections["df"] else { return nil }
        let disks: [DiskUsage] = df.compactMap { line in
            let fields = line.split(separator: " ")
            guard fields.count == 3, let size = Double(fields[1]), let free = Double(fields[2]), size > 0 else { return nil }
            return DiskUsage(mount: String(fields[0]), usedPercent: Int(((size - free) / size * 100).rounded()))
        }
        var memory: MemoryUsage?
        if let fields = sections["mem"]?.first?.split(separator: " "), fields.count == 2, let total = Int(fields[0]), let free = Int(fields[1]) {
            memory = MemoryUsage(totalMB: total / 1024, availableMB: free / 1024, swapTotalMB: 0, swapUsedMB: 0)
        }
        var services: [String: ServiceState] = [:]
        for line in sections["svc"] ?? [] {
            guard let split = line.firstIndex(of: "=") else { continue }
            let state: ServiceState
            switch line[line.index(after: split)...] {
            case "Running": state = .active
            case "NotFound": state = .missing
            default: state = .inactive
            }
            services[String(line[..<split])] = state
        }
        return RemoteMetrics(disks: disks, memory: memory, load: nil, cores: nil,
                             uptimeSeconds: sections["uptime"]?.first.flatMap { Int($0) },
                             services: services, failedUnits: [], osName: sections["os"]?.first)
    }
}
