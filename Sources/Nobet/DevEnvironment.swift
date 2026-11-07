import Foundation

/// `lsof -a -d cwd -Fpn` çıktısını süreç numarası → çalışma klasörü eşlemesine çevirir.
enum ProcessCwd {
    static func parse(_ output: String) -> [Int: String] {
        var pid: Int?
        var map: [Int: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            guard let tag = line.first else { continue }
            let value = String(line.dropFirst())
            switch tag {
            case "p": pid = Int(value)
            case "n": if let pid, map[pid] == nil { map[pid] = value }
            default: continue
            }
        }
        return map
    }
}

/// Bir klasörün hangi projeye ait olduğunu bulur. Klasörden yukarı doğru ilk proje işaretini arar.
enum ProjectRoot {
    static let markers = [
        ".git", ".ddev", "package.json", "composer.json", "Package.swift",
        "go.mod", "pyproject.toml", "Cargo.toml", "Gemfile", "pom.xml", "build.gradle",
    ]

    /// Ev klasörü ve üstü proje sayılmaz. İşaret bulunamazsa nil döner.
    static func find(from directory: String, home: String, exists: (String) -> Bool) -> String? {
        var current = directory
        while current != "/", !current.isEmpty {
            if current == home || home.hasPrefix(current + "/") { return nil }
            if markers.contains(where: { exists(current + "/" + $0) }) { return current }
            current = (current as NSString).deletingLastPathComponent
        }
        return nil
    }
}

/// Proje klasöründen okunur ad üretir. `api` veya `docker` gibi genel adlara üst klasör eklenir (en çok 3 parça).
enum ProjectName {
    private static let generic: Set<String> = [
        "api", "web", "app", "apps", "server", "client", "backend", "frontend", "docker", "src", "packages", "services",
    ]

    static func make(root: String) -> String {
        var parts = root.split(separator: "/").map(String.init)
        guard var head = parts.popLast() else { return root }
        var name = head
        var used = 1
        while generic.contains(head.lowercased()), used < 3, let parent = parts.popLast() {
            head = parent
            name = parent + "/" + name
            used += 1
        }
        return name
    }
}

/// `docker ps -a` satırı. Alanlar sekmeyle ayrılır, çünkü etiketler virgül ve boşluk içerir.
struct DockerContainer: Identifiable, Equatable {
    let id: String
    let name: String
    let image: String
    let state: String
    let status: String
    let ports: String
    let composeProject: String
    let ddevSite: String
    let ddevRoot: String
    let composeDir: String

    static let format = [
        "{{.ID}}", "{{.Names}}", "{{.Image}}", "{{.State}}", "{{.Status}}", "{{.Ports}}",
        "{{.Label \"com.docker.compose.project\"}}", "{{.Label \"com.ddev.site-name\"}}",
        "{{.Label \"com.ddev.approot\"}}", "{{.Label \"com.docker.compose.project.working_dir\"}}",
    ].joined(separator: "\t")

    var isRunning: Bool { state == "running" }

    /// Yayınlanan portlar "konak→konteyner". IPv4 ve IPv6 kayıtları tek satıra iner.
    var portSummary: String {
        var seen = Set<String>()
        var result: [String] = []
        for part in ports.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
            guard let arrow = part.range(of: "->") else { continue }
            let host = part[..<arrow.lowerBound].split(separator: ":", omittingEmptySubsequences: false).last.map(String.init) ?? ""
            let container = part[arrow.upperBound...].split(separator: "/").first.map(String.init) ?? ""
            guard !host.isEmpty, !container.isEmpty else { continue }
            let text = "\(host)→\(container)"
            if seen.insert(text).inserted { result.append(text) }
        }
        return result.joined(separator: ", ")
    }

    /// DDEV kök klasörü, yoksa compose çalışma klasörü. Bağımsız konteynerde nil.
    var projectRoot: String? {
        if !ddevRoot.isEmpty { return ddevRoot }
        return composeDir.isEmpty ? nil : composeDir
    }

    var projectName: String {
        if !ddevSite.isEmpty { return ddevSite }
        return composeProject.isEmpty ? name : composeProject
    }

    /// Alan sayısı 10 olmayan satırlar atlanır.
    static func parse(_ output: String) -> [DockerContainer] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 10 else { return nil }
            return DockerContainer(
                id: fields[0], name: fields[1], image: fields[2], state: fields[3], status: fields[4], ports: fields[5],
                composeProject: fields[6], ddevSite: fields[7], ddevRoot: fields[8], composeDir: fields[9])
        }
    }
}

struct DDEVSiteState: Equatable {
    let name: String
    let running: Bool
}

struct DevProject: Identifiable, Equatable {
    let name: String
    let root: String?
    var ports: [ListeningPort]
    var containers: [DockerContainer]

    var id: String { root ?? "konteyner:\(name)" }

    /// Aynı DDEV sitesinin konteynerleri tek satırda toplanır. Herhangi biri çalışıyorsa site çalışıyordur.
    var ddevSites: [DDEVSiteState] {
        let names = Set(containers.map(\.ddevSite).filter { !$0.isEmpty })
        return names.sorted().map { name in
            DDEVSiteState(name: name, running: containers.contains { $0.ddevSite == name && $0.isRunning })
        }
    }

    /// DDEV'e ait olmayan konteynerler. Her biri ayrı yönetilir.
    var standaloneContainers: [DockerContainer] {
        containers.filter { $0.ddevSite.isEmpty }
    }
}

/// Portları ve konteynerleri proje başına toplar.
struct DevOverview: Equatable {
    let projects: [DevProject]
    /// Hiçbir projeye bağlanamayan portlar (sistem servisleri gibi).
    let otherPorts: [ListeningPort]

    static let empty = DevOverview(projects: [], otherPorts: [])

    /// Aynı portu birden çok süreç tutuyorsa çakışmadır.
    var conflicts: [PortConflict] {
        PortScan.conflicts(projects.flatMap(\.ports) + otherPorts)
    }

    /// Projeye ait olup tüm ağ arayüzlerini dinleyen port sayısı ile çakışmalar. Menü çubuğu uyarısını besler.
    var alertCount: Int {
        projects.flatMap(\.ports).filter { $0.scope == .all }.count + conflicts.count
    }

    static func build(ports: [ListeningPort], cwds: [Int: String], containers: [DockerContainer],
                      home: String, exists: (String) -> Bool) -> DevOverview {
        var byKey: [String: DevProject] = [:]

        for container in containers {
            let key = container.projectRoot ?? "konteyner:\(container.projectName)"
            let name = container.ddevSite.isEmpty ? container.projectRoot.map(ProjectName.make(root:)) ?? container.projectName : container.ddevSite
            var project = byKey[key] ?? DevProject(name: name, root: container.projectRoot, ports: [], containers: [])
            project.containers.append(container)
            byKey[key] = project
        }

        var others: [ListeningPort] = []
        for port in ports {
            guard let cwd = cwds[port.pid], let root = ProjectRoot.find(from: cwd, home: home, exists: exists) else {
                others.append(port)
                continue
            }
            var project = byKey[root] ?? DevProject(name: ProjectName.make(root: root), root: root, ports: [], containers: [])
            project.ports.append(port)
            byKey[root] = project
        }

        let projects = byKey.values.map { project -> DevProject in
            var sorted = project
            sorted.ports.sort { $0.port < $1.port }
            sorted.containers.sort { $0.name < $1.name }
            return sorted
        }.sorted { $0.name.lowercased() < $1.name.lowercased() }

        return DevOverview(projects: projects, otherPorts: others.sorted { $0.port < $1.port })
    }
}

enum DevTool: Equatable {
    case docker
    case ddev
}

enum DevCommand: Equatable {
    /// Kabuk kullanılmaz. Argümanlar dizi olarak geçer.
    case process(tool: DevTool, arguments: [String])
    case signal(pid: Int)
}

/// Kullanıcının onayladığı eylemler. Sabit bir komut listesi vardır. Serbest komut çalışmaz.
enum DevAction: Equatable {
    case stopContainer(String)
    case startContainer(String)
    case ddevStop(String)
    case ddevStart(String)
    case terminate(pid: Int)

    /// Ad boş, çok uzun veya `-` ile ya da özel karakterle başlıyorsa nil. Komut enjeksiyonunu engeller.
    private static func isSafeName(_ name: String) -> Bool {
        guard (1...128).contains(name.utf8.count), let first = name.unicodeScalars.first else { return false }
        func alnum(_ scalar: Unicode.Scalar) -> Bool {
            ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
        }
        guard alnum(first) else { return false }
        return name.unicodeScalars.allSatisfy { alnum($0) || $0 == "_" || $0 == "." || $0 == "-" }
    }

    var command: DevCommand? {
        switch self {
        case .stopContainer(let name):
            return Self.isSafeName(name) ? .process(tool: .docker, arguments: ["stop", name]) : nil
        case .startContainer(let name):
            return Self.isSafeName(name) ? .process(tool: .docker, arguments: ["start", name]) : nil
        case .ddevStop(let name):
            return Self.isSafeName(name) ? .process(tool: .ddev, arguments: ["stop", name]) : nil
        case .ddevStart(let name):
            return Self.isSafeName(name) ? .process(tool: .ddev, arguments: ["start", name]) : nil
        case .terminate(let pid):
            let own = Int(ProcessInfo.processInfo.processIdentifier)
            return pid > 1 && pid != own ? .signal(pid: pid) : nil
        }
    }

    /// Onay penceresinde gösterilen metin.
    var summary: String {
        switch self {
        case .stopContainer(let name): return "Konteyner durdurulacak: \(name)"
        case .startContainer(let name): return "Konteyner başlatılacak: \(name)"
        case .ddevStop(let name): return "DDEV sitesi durdurulacak: \(name)"
        case .ddevStart(let name): return "DDEV sitesi başlatılacak: \(name)"
        case .terminate(let pid): return "Süreç sonlandırılacak (SIGTERM): PID \(pid)"
        }
    }
}

/// Geliştirme ortamının tek bakışlık özeti.
struct DevHealth: Equatable {
    enum Level { case ok, warning }

    let projects: Int
    let listening: Int
    let exposed: Int
    let conflicts: Int
    let containersRunning: Int
    let containersStopped: Int

    init(overview: DevOverview) {
        let ports = overview.projects.flatMap(\.ports) + overview.otherPorts
        let containers = overview.projects.flatMap(\.containers)
        projects = overview.projects.count
        listening = ports.count
        exposed = overview.projects.flatMap(\.ports).filter { $0.scope == .all }.count
        conflicts = overview.conflicts.count
        containersRunning = containers.filter(\.isRunning).count
        containersStopped = containers.count - containersRunning
    }

    private var issueCount: Int { exposed + conflicts }
    var level: Level { issueCount == 0 ? .ok : .warning }
    var headline: String { issueCount == 0 ? "Her şey yolunda" : "\(issueCount) sorun var" }
}
