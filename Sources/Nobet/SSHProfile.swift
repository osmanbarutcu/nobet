import Foundation

enum SSHAuth: String, Codable {
    case password, key
}

/// Sunucu başına uyarı eşikleri. Boş bırakılan profil `standard` değerlerini kullanır.
struct ServerThresholds: Codable, Equatable {
    var diskMedium: Int
    var diskHigh: Int
    var memoryLowPercent: Int
    var loadPerCore: Double

    static let standard = ServerThresholds(diskMedium: 80, diskHigh: 90, memoryLowPercent: 10, loadPerCore: 2.0)

    var isValid: Bool {
        (1...100).contains(diskMedium) && (1...100).contains(diskHigh) && diskMedium < diskHigh
            && (1...90).contains(memoryLowPercent) && loadPerCore > 0 && loadPerCore <= 64
    }
}

/// SSH ile izlenen sunucu. Parola ve anahtar burada yer almaz. Sırlar yalnızca Anahtar Zinciri'nde durur.
/// Uzak sunucunun işletim sistemi. Kayıtta yoksa Linux sayılır.
enum RemotePlatform: String, Codable, Equatable, CaseIterable {
    case linux, windows

    var title: String { self == .linux ? "Linux" : "Windows" }
}

struct SSHProfile: Identifiable, Codable, Equatable {
    let id: String
    let name: String
    let host: String
    let port: Int
    let user: String
    let auth: SSHAuth
    let services: [String]
    var thresholds: ServerThresholds? = nil
    /// Yedeklerin durduğu uzak klasör. Doluysa en yeni dosyanın yaşı denetlenir.
    var backupPath: String? = nil
    /// `nil`: Linux. Windows için OpenSSH sunucusu ve PowerShell gerekir.
    var platform: RemotePlatform? = nil
    /// Anahtar kimliği için özel anahtar dosyası. `nil`: ssh-agent ve varsayılan dosya adları. İçeriği değil, yalnızca yolu saklanır.
    var keyPath: String? = nil

    var isWindows: Bool { platform == .windows }

    /// Geçersiz alan adı, kullanıcı veya port için `nil` verir. Güvensiz servis adları sessizce atılır.
    static func make(name: String, host: String, port: Int, user: String, auth: SSHAuth, services: [String],
                     thresholds: ServerThresholds? = nil, backupPath: String? = nil, platform: RemotePlatform? = nil,
                     keyPath: String? = nil, id: String = UUID().uuidString) -> SSHProfile? {
        let cleanHost = host.trimmingCharacters(in: .whitespaces).lowercased()
        let cleanUser = user.trimmingCharacters(in: .whitespaces)
        guard ServerSite.isValidHost(cleanHost), isValidUser(cleanUser), (1...65535).contains(port), thresholds?.isValid ?? true else { return nil }
        let cleanBackup = backupPath?.trimmingCharacters(in: .whitespaces)
        if let cleanBackup, !cleanBackup.isEmpty, !isSafeBackupPath(cleanBackup) { return nil }
        let cleanKey = keyPath?.trimmingCharacters(in: .whitespaces)
        if let cleanKey, !cleanKey.isEmpty, !isSafeKeyPath(cleanKey) { return nil }
        let cleanName = name.trimmingCharacters(in: .whitespaces)
        var seen = Set<String>()
        let safe = services.map { $0.trimmingCharacters(in: .whitespaces) }.filter { isSafeService($0) && seen.insert($0).inserted }
        return SSHProfile(id: id, name: cleanName.isEmpty ? cleanHost : cleanName, host: cleanHost, port: port, user: cleanUser,
                          auth: auth, services: safe, thresholds: thresholds,
                          backupPath: cleanBackup?.isEmpty == false ? cleanBackup : nil,
                          platform: platform == .windows ? .windows : nil,
                          keyPath: auth == .key && cleanKey?.isEmpty == false ? cleanKey : nil)
    }

    private static func isAsciiAlnum(_ character: Character) -> Bool {
        character.isASCII && (character.isLetter || character.isNumber)
    }

    /// İlk karakter harf veya alt çizgi olur. Tire ile başlayan ad `ssh` seçeneği gibi okunurdu.
    static func isValidUser(_ user: String) -> Bool {
        guard let first = user.first, (first.isASCII && first.isLetter) || first == "_", user.count <= 32 else { return false }
        return user.allSatisfy { isAsciiAlnum($0) || "_.-".contains($0) }
    }

    /// Mutlak yol. Harf, rakam ve `/._-` kabul edilir. Kabuk karakterleri ve `..` reddedilir.
    static func isSafeBackupPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.count > 1, path.count <= 200, !path.contains("..") else { return false }
        return path.allSatisfy { isAsciiAlnum($0) || "/._-".contains($0) }
    }

    /// Mutlak yol veya `~/` ile başlayan yol. `..` ve denetim karakteri reddedilir. `ssh -i` ayrı argüman alır, boşluk sorun olmaz.
    static func isSafeKeyPath(_ path: String) -> Bool {
        guard path.hasPrefix("/") || path.hasPrefix("~/"), path.count > 2, path.count <= 300, !path.contains("..") else { return false }
        return !path.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }

    /// `~/` ile başlayan yolu ev klasörüne açar. ssh `-i` içindeki `~` işaretini kendisi açmaz.
    static func expandedKeyPath(_ path: String, home: String = NSHomeDirectory()) -> String {
        path.hasPrefix("~/") ? home + String(path.dropFirst(1)) : path
    }

    /// systemd birim adında geçen karakterler. Kabuk karakterleri reddedilir.
    static func isSafeService(_ name: String) -> Bool {
        guard !name.isEmpty, name.count <= 64, !name.hasPrefix("-") else { return false }
        return name.allSatisfy { isAsciiAlnum($0) || "@._-".contains($0) }
    }
}

/// `ssh` komutunun argüman dizisi. Kabuk metni kurulmaz, her parça ayrı argümandır.
enum SSHInvocation {
    static func arguments(for profile: SSHProfile, knownHosts: String, command: String) -> [String] {
        // `ssh -o` değeri boşlukta keser. Boşluklu yol çift tırnak ister, yoksa dosya yolun ilk parçasına yazılır.
        let knownHostsValue = knownHosts.contains(where: \.isWhitespace) ? "\"\(knownHosts)\"" : knownHosts
        var args = [
            "-T",
            "-o", "ConnectTimeout=10",
            "-o", "StrictHostKeyChecking=accept-new",
            "-o", "UserKnownHostsFile=\(knownHostsValue)",
            "-o", "LogLevel=ERROR",
        ]
        switch profile.auth {
        case .password:
            args += ["-o", "PreferredAuthentications=password", "-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=1"]
        case .key:
            args += ["-o", "BatchMode=yes"]
            if let keyPath = profile.keyPath, SSHProfile.isSafeKeyPath(keyPath) {
                args += ["-o", "IdentitiesOnly=yes", "-i", SSHProfile.expandedKeyPath(keyPath)]
            }
        }
        return args + ["-p", String(profile.port), "--", "\(profile.user)@\(profile.host)", command]
    }
}

/// Uzak sunucuda çalışan sabit, salt okunur komut metni. Kullanıcı girdisi yalnızca doğrulanmış servis adlarıdır.
enum RemoteScript {
    /// Profilin platformuna uygun sabit komut.
    static func command(for profile: SSHProfile) -> String {
        profile.isWindows ? windows(services: profile.services) : linux(services: profile.services, backupPath: profile.backupPath)
    }

    /// Windows için salt okunur PowerShell. Betik `-EncodedCommand` ile gider, böylece tırnak sorunu olmaz.
    /// Yalnızca `Get-` komutları ve çıktı biçimleme kullanılır.
    static func windows(services: [String]) -> String {
        let names = services.filter(SSHProfile.isSafeService).map { "'\($0)'" }.joined(separator: ",")
        let script = """
        $ErrorActionPreference = 'SilentlyContinue'
        $os = Get-CimInstance Win32_OperatingSystem
        '#os'
        $os.Caption
        '#df'
        Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object { '{0} {1} {2}' -f $_.DeviceID, $_.Size, $_.FreeSpace }
        '#mem'
        '{0} {1}' -f $os.TotalVisibleMemorySize, $os.FreePhysicalMemory
        '#uptime'
        [int]((Get-Date) - $os.LastBootUpTime).TotalSeconds
        '#svc'
        foreach ($n in @(\(names))) { $s = Get-Service -Name $n; if ($s) { '{0}={1}' -f $n, $s.Status } else { '{0}=NotFound' -f $n } }
        """
        let encoded = Data(script.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }).base64EncodedString()
        return "powershell -NoProfile -NonInteractive -EncodedCommand \(encoded)"
    }

    static func linux(services: [String], backupPath: String? = nil) -> String {
        var parts = [
            "uname -sr", "echo '#os'", "grep PRETTY_NAME /etc/os-release",
            "echo '#df'", "df -P", "echo '#free'", "free -m",
            "echo '#load'", "cat /proc/loadavg", "echo '#uptime'", "cat /proc/uptime",
            "echo '#nproc'", "nproc", "echo '#failed'", "systemctl --failed --no-legend --plain",
            "echo '#svc'",
        ]
        // Sertleştirme okumaları. Hepsi salt okunurdur. `sshd -T` yoksa yapılandırma dosyasına düşer.
        let hardening = [
            "echo '#sshd'", "(sshd -T 2>/dev/null || cat /etc/ssh/sshd_config 2>/dev/null) | grep -iE '^(permitrootlogin|passwordauthentication|port) '",
            "echo '#f2b'", "systemctl is-active fail2ban 2>/dev/null",
            "echo '#listen'", "ss -tln 2>/dev/null",
            "echo '#lastb'", "lastb 2>/dev/null | grep -c notty",
            "echo '#docker'", "docker ps -a --format '{{.Names}}|{{.State}}|{{.Status}}' 2>/dev/null",
            "echo '#journal'", "journalctl -p err --since '1 hour ago' -q --no-pager 2>/dev/null | wc -l",
            "echo '#pending'", "if [ -f /var/run/reboot-required ]; then echo yes; else echo no; fi",
        ]
        let safe = services.filter(SSHProfile.isSafeService)
        if !safe.isEmpty {
            let list = safe.map { "'\($0)'" }.joined(separator: " ")
            parts.append("for s in \(list); do printf '%s=' \"$s\"; systemctl is-active \"$s\" || true; done")
        }
        // Veritabanı yanıt denetimi. `pg_isready` ve `mysqladmin ping` yalnızca sorar, veri okumaz. Araç yoksa çıktı boş kalır.
        var extra = [
            "echo '#db'",
            "if [ -n \"$(command -v pg_isready 2>/dev/null)\" ]; then pg_isready -t 5 2>&1 | sed 's/^/pg:/'; fi",
            "if [ -n \"$(command -v mysqladmin 2>/dev/null)\" ]; then timeout 8 mysqladmin ping 2>&1 | sed 's/^/mysql:/'; fi",
        ]
        // Yedek tazeliği: klasördeki en yeni dosyanın zamanı ve sunucu saati. Yol doğrulanmamışsa bölüm eklenmez.
        if let backupPath, SSHProfile.isSafeBackupPath(backupPath) {
            extra += [
                "echo '#backup'",
                "echo \"$(find '\(backupPath)' -maxdepth 2 -type f -printf '%T@\\n' 2>/dev/null | sort -n | tail -1)\"",
                "date +%s",
            ]
        }
        return (parts + hardening + extra).joined(separator: "; ")
    }
}

enum SSHError {
    /// Bilinen `ssh` hatalarını Türkçe mesaja çevirir. Ham çıktıyı göstermez, çünkü çıktı sunucudan gelir.
    static func describe(status: Int32, output: String) -> String {
        let text = output.lowercased()
        let known: [(String, String)] = [
            ("permission denied", "Kimlik doğrulama başarısız. Kullanıcıyı, parolayı veya anahtarı denetleyin."),
            ("timed out", "Zaman aşımı. Sunucuya ulaşılamadı."),
            ("connection refused", "Bağlantı reddedildi. SSH portunu denetleyin."),
            ("host key verification failed", "Sunucu anahtarı doğrulanamadı."),
            ("identification has changed", "Sunucu anahtarı değişti. Ortadaki adam saldırısı olabilir."),
            ("could not resolve", "Alan adı çözümlenemedi."),
            ("no route to host", "Sunucuya ağ yolu yok."),
            ("network is unreachable", "Sunucuya ağ yolu yok."),
        ]
        return known.first { text.contains($0.0) }?.1 ?? "SSH hatası (kod \(status))."
    }
}

/// `ssh`, parola sorarken `SSH_ASKPASS` olarak Nöbet'in kendi ikilisini çağırır. Parola ortam değişkeninden gelir, diske yazılmaz.
enum AskpassMode {
    static func password(environment: [String: String], prompt: String = "password") -> String? {
        guard environment["NOBET_ASKPASS"] == "1", prompt.lowercased().contains("assword") else { return nil }
        return environment["NOBET_PW"]
    }

    /// Askpass olarak çağrıldıysa parolayı yazar ve çıkar. Normal açılışta bir şey yapmaz.
    static func runIfRequested() {
        let prompt = CommandLine.arguments.dropFirst().joined(separator: " ")
        guard let secret = password(environment: ProcessInfo.processInfo.environment, prompt: prompt.isEmpty ? "password" : prompt) else { return }
        FileHandle.standardOutput.write(Data(secret.utf8))
        exit(0)
    }
}
