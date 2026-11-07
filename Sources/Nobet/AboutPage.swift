import AppKit
import SwiftUI

/// Hakkında sayfası: sürüm bilgisi ve sırsız tanılama raporu.
struct AboutPage: View {
    @ObservedObject var center: AlertCenter
    @StateObject private var state = AboutState()

    var body: some View {
        let report = DiagnosticsReport.text(
            .current(issues: center.active, eventCount: center.history.count, snoozeCount: center.snoozes.count)
        )
        PageContainer {
            VStack(alignment: .leading, spacing: 12) {
                CardHeader(symbol: "info.circle", title: "Hakkında")
                Text("Nöbet, Mac için yerel izleme uygulamasıdır. Veri bu Mac'te kalır.")
                    .font(.callout)
                Text(report)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.1)))
                HStack {
                    Button("Raporu kopyala") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(report, forType: .string)
                        state.copied = true
                    }
                    if state.copied { Text("Kopyalandı.").font(.caption).foregroundStyle(.secondary) }
                }
            }
            .padding(16)
            .frame(maxWidth: 560, alignment: .leading)
            .glassCard()
        }
    }
}

final class AboutState: ObservableObject {
    @Published var copied = false
}
