import Foundation
import Testing
@testable import Nobet

struct DiagnosticsTests {
    private func issue(_ module: String, _ subject: String, _ severity: Severity) -> AlertIssue {
        AlertIssue(key: "\(module)|\(subject)", module: module, subject: subject, title: "Başlık", severity: severity)
    }

    @Test func reportCountsIssuesByModuleAndSeverity() {
        let info = DiagnosticsInfo(
            version: "0.2.1", build: "1", system: "macOS 15.0", architecture: "arm64",
            issues: [issue("servers", "sunucu-a", .high), issue("servers", "sunucu-b", .info), issue("secrets", "x", .medium)],
            eventCount: 7, snoozeCount: 2
        )
        let text = DiagnosticsReport.text(info)
        #expect(text.contains("Nöbet 0.2.1 (1)"))
        #expect(text.contains("Açık sorun: 3"))
        #expect(text.contains("Yüksek: 1"))
        #expect(text.contains("Web siteleri: 2"))
        #expect(text.contains("Sırlar: 1"))
        #expect(text.contains("Kayıtlı olay: 7"))
        #expect(text.contains("Ertelenen: 2"))
    }

    @Test func reportNamesNoSubjectsPathsOrHosts() {
        let info = DiagnosticsInfo(
            version: "1", build: "1", system: "macOS", architecture: "arm64",
            issues: [issue("servers", "192.0.2.10", .high), issue("secrets", "/Users/biri/proje/.env", .high)],
            eventCount: 0, snoozeCount: 0
        )
        let text = DiagnosticsReport.text(info)
        #expect(!text.contains("192.0.2"))
        #expect(!text.contains("/Users/"))
        #expect(!text.contains(".env"))
    }

    @Test func reportStatesWhatItLeavesOut() {
        let text = DiagnosticsReport.text(DiagnosticsInfo(version: "1", build: "1", system: "m", architecture: "a", issues: [], eventCount: 0, snoozeCount: 0))
        #expect(text.contains("Parola, anahtar, adres ve dosya yolu yok"))
    }
}
