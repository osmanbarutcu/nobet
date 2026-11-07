import Foundation

struct SSHFailure: Error, Equatable {
    let message: String
}

protocol RemoteCollecting: Sendable {
    func collect(_ profile: SSHProfile, password: String?) async -> Result<RemoteMetrics, SSHFailure>
}

/// Parola ve anahtar deposu. Gerçek uygulama Anahtar Zinciri kullanır, testler bellek içi depo kullanır.
protocol SecretStoring {
    func set(_ secret: Data, account: String) throws
    func get(account: String) throws -> Data?
    func delete(account: String) throws
}

extension KeychainStore: SecretStoring {}

/// Sistemdeki `/usr/bin/ssh` ile sabit, salt okunur komutu çalıştırır. Kabuk metni kurulmaz, argümanlar dizidir.
/// Parola yalnızca çocuk sürecin ortam değişkeninde durur. Dosyaya ve günlüğe yazılmaz.
struct SSHRunner: RemoteCollecting {
    static let timeout: TimeInterval = 30
    private static let sshPath = "/usr/bin/ssh"

    func collect(_ profile: SSHProfile, password: String?) async -> Result<RemoteMetrics, SSHFailure> {
        await Task.detached(priority: .utility) { Self.runBlocking(profile, password: password) }.value
    }

    /// Parola kimliği için ortam değişkenleri. Anahtar kimliğinde parola ve askpass izi bırakılmaz.
    static func environment(for profile: SSHProfile, password: String?, askpassPath: String, base: [String: String]) -> [String: String] {
        var env = base
        for key in ["NOBET_PW", "NOBET_ASKPASS", "SSH_ASKPASS", "SSH_ASKPASS_REQUIRE"] { env[key] = nil }
        guard profile.auth == .password, let password else { return env }
        env["SSH_ASKPASS"] = askpassPath
        env["SSH_ASKPASS_REQUIRE"] = "force"
        env["NOBET_ASKPASS"] = "1"
        env["NOBET_PW"] = password
        if env["DISPLAY"] == nil { env["DISPLAY"] = ":0" }
        return env
    }

    static func interpret(status: Int32, stdout: String, stderr: String, windows: Bool = false) -> Result<RemoteMetrics, SSHFailure> {
        guard status == 0 else { return .failure(SSHFailure(message: SSHError.describe(status: status, output: stderr + "\n" + stdout))) }
        guard let metrics = windows ? WindowsParser.metrics(from: stdout) : LinuxParser.metrics(from: stdout) else {
            return .failure(SSHFailure(message: windows
                ? "Beklenmeyen çıktı. Sunucuda OpenSSH ve PowerShell çalışmıyor olabilir."
                : "Beklenmeyen çıktı. Sunucu Linux ve systemd kullanmıyor olabilir."))
        }
        return .success(metrics)
    }

    /// Nöbet'in kendi `known_hosts` dosyası. Kullanıcının `~/.ssh/known_hosts` dosyasına dokunulmaz.
    static func knownHostsPath() -> String {
        let directory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Nobet")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("known_hosts").path
    }

    private final class TimeoutFlag: @unchecked Sendable {
        var fired = false
    }

    private static func runBlocking(_ profile: SSHProfile, password: String?) -> Result<RemoteMetrics, SSHFailure> {
        switch execute(profile, password: password, command: RemoteScript.command(for: profile)) {
        case .failure(let failure): return .failure(failure)
        case .success(let output): return interpret(status: output.status, stdout: output.stdout, stderr: output.stderr, windows: profile.isWindows)
        }
    }

    struct CommandOutput {
        let status: Int32
        let stdout: String
        let stderr: String
    }

    /// Sabit bir komutu tek `ssh` sürecinde çalıştırır. Zaman aşımında süreci sonlandırır.
    static func execute(_ profile: SSHProfile, password: String?, command: String) -> Result<CommandOutput, SSHFailure> {
        guard let askpass = Bundle.main.executablePath else { return .failure(SSHFailure(message: "Uygulama yolu bulunamadı.")) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sshPath)
        process.arguments = SSHInvocation.arguments(for: profile, knownHosts: knownHostsPath(), command: command)
        process.environment = environment(for: profile, password: password, askpassPath: askpass, base: ProcessInfo.processInfo.environment)
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return .failure(SSHFailure(message: "ssh başlatılamadı.")) }

        let flag = TimeoutFlag()
        let watchdog = DispatchWorkItem { if process.isRunning { flag.fired = true; process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let errBox = DataBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global().async {
            errBox.data = err.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        group.wait()
        process.waitUntilExit()
        watchdog.cancel()
        if flag.fired { return .failure(SSHFailure(message: "Zaman aşımı. Sunucu \(Int(timeout)) saniyede yanıt vermedi.")) }
        return .success(CommandOutput(status: process.terminationStatus, stdout: String(decoding: outData, as: UTF8.self),
                                      stderr: String(decoding: errBox.data, as: UTF8.self)))
    }

    private final class DataBox: @unchecked Sendable {
        var data = Data()
    }
}

extension SSHRunner: PackageListing {
    func packages(_ profile: SSHProfile, password: String?) async -> Result<[InstalledPackage], SSHFailure> {
        await Task.detached(priority: .utility) {
            switch Self.execute(profile, password: password, command: RemoteScript.packages) {
            case .failure(let failure): return .failure(failure)
            case .success(let output):
                guard output.status == 0 else {
                    return .failure(SSHFailure(message: SSHError.describe(status: output.status, output: output.stderr + "\n" + output.stdout)))
                }
                let items = PackageInventory.parse(output.stdout)
                return items.isEmpty ? .failure(SSHFailure(message: "Paket listesi okunamadı. Sunucuda dpkg veya rpm yok.")) : .success(items)
            }
        }.value
    }
}
