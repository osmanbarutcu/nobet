import Foundation

/// Tanılama raporunun girdisi. Alan olarak konu, adres veya yol taşımaz.
struct DiagnosticsInfo {
    let version: String
    let build: String
    let system: String
    let architecture: String
    let issues: [AlertIssue]
    let eventCount: Int
    let snoozeCount: Int

    static func current(issues: [AlertIssue], eventCount: Int, snoozeCount: Int) -> DiagnosticsInfo {
        let bundle = Bundle.main
        var uts = utsname()
        uname(&uts)
        let machine = withUnsafePointer(to: &uts.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
        return DiagnosticsInfo(
            version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "geliştirme",
            build: bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0",
            system: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: machine,
            issues: issues,
            eventCount: eventCount,
            snoozeCount: snoozeCount
        )
    }
}

/// Destek için kopyalanan düz metin rapor. Yalnızca sürüm ve sayılar içerir.
enum DiagnosticsReport {
    static func text(_ info: DiagnosticsInfo) -> String {
        var lines = [
            "Nöbet \(info.version) (\(info.build))",
            "Sistem: \(info.system) · \(info.architecture)",
            "",
            "Açık sorun: \(info.issues.count)",
        ]
        let high = info.issues.filter { $0.severity == .high }.count
        let medium = info.issues.filter { $0.severity == .medium }.count
        let low = info.issues.count - high - medium
        lines.append("Yüksek: \(high) · Orta: \(medium) · Bilgi: \(low)")
        for key in ModuleNames.order {
            let count = info.issues.filter { $0.module == key }.count
            if count > 0 { lines.append("\(ModuleNames.title(key)): \(count)") }
        }
        lines += [
            "",
            "Kayıtlı olay: \(info.eventCount)",
            "Ertelenen: \(info.snoozeCount)",
            "",
            "Parola, anahtar, adres ve dosya yolu yok.",
        ]
        return lines.joined(separator: "\n")
    }
}
