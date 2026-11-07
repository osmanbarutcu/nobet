import Foundation

private func realPath(_ path: String) -> String? {
    guard let resolved = realpath(path, nil) else { return nil }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Klasör ağacında `.env` dosyalarını arar. Sembolik bağları izlemez. Derinlik, giriş sayısı ve süre sınırı vardır.
enum FileWalker {
    /// Ağır klasörler ve macOS'un izin istemi çıkardığı kişisel klasörler. Kök olarak açıkça verilirse taranır.
    static let skippedDirectories: Set<String> = [
        "node_modules", "vendor", ".git", "Library", ".Trash", ".cache", ".npm", ".nvm", ".cargo", ".rustup", ".pyenv", ".gradle",
        ".build", "build", "dist", ".next", "venv", ".venv", "Pods", "DerivedData",
        "Desktop", "Documents", "Downloads", "Movies", "Music", "Pictures",
    ]

    /// `maxDepth`: kökten sayılan klasör derinliği. Kökteki dosya derinlik 1'dedir.
    static func envFiles(under root: String, maxDepth: Int, maxEntries: Int, deadline: Date) -> [String] {
        let url = URL(fileURLWithPath: root, isDirectory: true)
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys, options: [], errorHandler: { _, _ in true }) else {
            return []
        }
        // Sayaç sembolik bağları çözülmüş yol verir (/var → /private/var). Yollar kullanıcının verdiği kök yazımıyla döner.
        // `resolvingSymlinksInPath` /private önekini geri attığı için gerçek yol `realpath` ile alınır.
        let resolvedRoot = realPath(root) ?? root
        func spelled(_ path: String) -> String {
            path.hasPrefix(resolvedRoot) ? root + path.dropFirst(resolvedRoot.count) : path
        }
        var found: [String] = []
        var seen = 0
        while let item = enumerator.nextObject() as? URL {
            seen += 1
            if seen > maxEntries || Date() >= deadline { break }
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values?.isDirectory == true {
                if skippedDirectories.contains(item.lastPathComponent) || enumerator.level >= maxDepth { enumerator.skipDescendants() }
                continue
            }
            if enumerator.level <= maxDepth, EnvFile.isEnvFileName(item.lastPathComponent) { found.append(spelled(item.path)) }
        }
        return found
    }
}

protocol GitProbing {
    func status(ofFile path: String) -> GitStatus
    /// Dosya adı herhangi bir dalın geçmişinde geçiyor mu. Yalnızca commit varlığına bakar, içeriği okumaz.
    func inHistory(ofFile path: String) -> Bool
}

extension GitProbing {
    func inHistory(ofFile path: String) -> Bool { false }
}

/// Sistemdeki `git` ile dosyanın depoda izlenip izlenmediğini ve yok sayılıp sayılmadığını sorar. Hiçbir şeyi değiştirmez.
struct SystemGit: GitProbing {
    /// `/usr/bin/git` Command Line Tools yokken kurulum penceresi açar. Bu yüzden gerçek yollar denenir.
    static let gitPath: String? = [
        "/opt/homebrew/bin/git", "/usr/local/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git",
        "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
    ].first { FileManager.default.isExecutableFile(atPath: $0) }

    func status(ofFile path: String) -> GitStatus {
        guard let git = Self.gitPath else { return GitStatus(inRepo: false, tracked: false, ignored: false) }
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        func exitCode(_ arguments: [String]) -> Int32? {
            DevRunner.run(git, ["-C", directory] + arguments, timeout: 5)?.status
        }
        guard exitCode(["rev-parse", "--is-inside-work-tree"]) == 0 else {
            return GitStatus(inRepo: false, tracked: false, ignored: false)
        }
        return GitStatus(
            inRepo: true,
            tracked: exitCode(["ls-files", "--error-unmatch", "--", name]) == 0,
            ignored: exitCode(["check-ignore", "-q", "--", name]) == 0)
    }
}

extension SystemGit {
    func inHistory(ofFile path: String) -> Bool {
        guard let git = Self.gitPath else { return false }
        let directory = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        let output = DevRunner.run(git, ["-C", directory, "log", "--all", "-n", "1", "--format=%H", "--", name], timeout: 5)
        return output?.status == 0 && output?.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
}

/// Yerel sır taraması. Yalnızca okur. Bulguda sır değeri yer almaz.
enum SecretScanner {
    static let maxEnvFileBytes = 64 * 1024
    static let headBytes = 4096
    static let maxDepth = 6
    static let maxEntries = 300_000

    static func scan(roots: [String], home: String, git: GitProbing, deadline: Date) -> [SecretFinding] {
        var findings = sshFindings(home: home)
        findings += credentialFindings(home: home)
        var visited = Set<String>()
        for root in roots {
            for path in FileWalker.envFiles(under: root, maxDepth: maxDepth, maxEntries: maxEntries, deadline: deadline)
            where visited.insert(path).inserted {
                findings += envFindings(path: path, git: git)
            }
        }
        var unique: [String: SecretFinding] = [:]
        for finding in findings { unique[finding.id] = finding }
        return SecretFinding.sorted(Array(unique.values))
    }

    private static func mode(of path: String) -> UInt16? {
        (try? FileManager.default.attributesOfItem(atPath: path))?[.posixPermissions].flatMap { ($0 as? NSNumber)?.uint16Value }
    }

    private static func size(of path: String) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    private static func head(of path: String, bytes: Int) -> String {
        guard let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        return String(decoding: handle.readData(ofLength: bytes), as: UTF8.self)
    }

    private static func sshFindings(home: String) -> [SecretFinding] {
        let directory = home + "/.ssh"
        guard let dirMode = mode(of: directory), let names = try? FileManager.default.contentsOfDirectory(atPath: directory) else { return [] }
        let entries = names.sorted().compactMap { name -> SSHEntry? in
            let path = directory + "/" + name
            guard let fileMode = mode(of: path), size(of: path) <= 32 * 1024 else { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else { return nil }
            return SSHEntry(path: path, mode: fileMode, head: head(of: path, bytes: headBytes))
        }
        return SSHAudit.evaluate(dirPath: directory, dirMode: dirMode, entries: entries)
    }

    private static func credentialFindings(home: String) -> [SecretFinding] {
        CredentialSpec.all.compactMap { spec in
            let path = home + "/" + spec.relativePath
            guard let fileMode = mode(of: path) else { return nil }
            return CredentialAudit.evaluate(path: path, spec: spec, mode: fileMode, head: head(of: path, bytes: maxEnvFileBytes))
        }
    }

    private static func envFindings(path: String, git: GitProbing) -> [SecretFinding] {
        guard size(of: path) <= maxEnvFileBytes, let fileMode = mode(of: path) else { return [] }
        let secrets = EnvFile.secrets(in: head(of: path, bytes: maxEnvFileBytes))
        guard !secrets.isEmpty else { return [] }
        let status = git.status(ofFile: path)
        let history = status.inRepo && !status.tracked && git.inHistory(ofFile: path)
        return EnvAudit.evaluate(path: path, secrets: secrets, mode: fileMode, git: status, inHistory: history)
    }
}
