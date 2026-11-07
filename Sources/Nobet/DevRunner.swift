import Foundation

/// Dış komutları çalıştırır. Kabuk kullanılmaz, argümanlar dizi olarak geçer. Her çağrının zaman aşımı vardır.
enum DevRunner {
    private static let searchPaths: [DevTool: [String]] = [
        .docker: [
            "/usr/local/bin/docker", "/opt/homebrew/bin/docker",
            NSHomeDirectory() + "/.orbstack/bin/docker", "/Applications/Docker.app/Contents/Resources/bin/docker",
        ],
        .ddev: ["/usr/local/bin/ddev", "/opt/homebrew/bin/ddev"],
    ]

    nonisolated static func path(for tool: DevTool) -> String? {
        searchPaths[tool]?.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    /// Zaman aşımında süreci sonlandırır ve nil döner. Başlatılamazsa nil döner.
    nonisolated static func run(_ path: String, _ arguments: [String], timeout: TimeInterval) -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:\(NSHomeDirectory())/.orbstack/bin"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        var timedOut = false
        let watchdog = DispatchWorkItem { if process.isRunning { timedOut = true; process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()
        if timedOut { return nil }
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    /// Portları, çalışma klasörlerini ve konteynerleri okur. Hiçbir şeyi değiştirmez.
    nonisolated static func snapshot() -> DevOverview {
        let ports = PortScan.scan()
        let pids = Set(ports.map(\.pid))
        var cwds: [Int: String] = [:]
        if !pids.isEmpty,
           let result = run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-Fpn", "-p", pids.sorted().map(String.init).joined(separator: ",")], timeout: 8) {
            cwds = ProcessCwd.parse(result.output)
        }
        var containers: [DockerContainer] = []
        if let docker = path(for: .docker),
           let result = run(docker, ["ps", "-a", "--format", DockerContainer.format], timeout: 8), result.status == 0 {
            containers = DockerContainer.parse(result.output)
        }
        return DevOverview.build(
            ports: ports, cwds: cwds, containers: containers,
            home: NSHomeDirectory(), exists: { FileManager.default.fileExists(atPath: $0) })
    }

    /// Başarıda nil, başarısızlıkta kullanıcıya gösterilecek metin döner.
    nonisolated static func execute(_ action: DevAction) -> String? {
        guard let command = action.command else { return "Eylem geçersiz." }
        switch command {
        case .signal(let pid):
            return kill(pid_t(pid), SIGTERM) == 0 ? nil : "Süreç sonlandırılamadı: \(String(cString: strerror(errno)))."
        case .process(let tool, let arguments):
            guard let path = path(for: tool) else { return "\(tool == .docker ? "docker" : "ddev") bulunamadı." }
            guard let result = run(path, arguments, timeout: 120) else { return "Komut zaman aşımına uğradı veya başlatılamadı." }
            guard result.status != 0 else { return nil }
            let last = result.output.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
            return "Komut başarısız (kod \(result.status)). \(last)"
        }
    }
}
