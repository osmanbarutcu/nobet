import AppKit
import SwiftUI

/// Sır tarayıcı: yerel dosyalardaki riskli izinleri ve açıkta kalan sırları listeler. Dosyaları değiştirmez.
struct SecretsPage: View {
    @ObservedObject var model: SecretsModel

    var body: some View {
        PageContainer {
                header
                foldersCard
                if model.scanned && model.findings.isEmpty {
                    EmptyState(symbol: "checkmark.shield", title: "Bulgu yok",
                               message: "Taranan yerlerde riskli dosya bulunamadı. Başka bir klasörü taramak için Klasör ekle düğmesini kullanın.")
                }
                ForEach(model.findings) { finding in
                    FindingCard(finding: finding, actionTitle: "Yok say") { model.ignore(finding) }
                }
                if !model.ignoredFindings.isEmpty {
                    Text("Yok sayılanlar (\(model.ignoredFindings.count))").font(.callout.weight(.medium)).padding(.top, 8)
                    ForEach(model.ignoredFindings) { finding in
                        FindingCard(finding: finding, actionTitle: "Geri al") { model.unignore(finding) }
                            .opacity(0.6)
                    }
                }
        }
        .onAppear { if !model.scanned { model.rescan() } }
    }

    private var header: some View {
        let summary = "\(model.findings.count) bulgu · \(SecretFinding.alertCount(model.findings)) uyarı"
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                CardHeader(symbol: "key", title: "Sırlar", trailing: model.scanned ? summary : "")
                if model.scanning { ProgressView().controlSize(.small) }
                Button { model.rescan() } label: { Image(systemName: "arrow.clockwise") }
                    .glassButton()
                    .controlSize(.small)
                    .disabled(model.scanning)
                    .help("Yeniden tara")
                    .accessibilityLabel("Yeniden tara")
            }
            Text("Nöbet yalnızca okur. Sır değerini göstermez, kaydetmez ve dosyaları değiştirmez. Düzeltme komutunu siz çalıştırırsınız.")
                .font(.nobetFootnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var foldersCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(symbol: "folder.badge.plus", title: "Taranan klasörler")
            Text(verbatim: "~ (ev klasörü, Desktop/Documents/Downloads/Library hariç)")
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(model.folders, id: \.self) { folder in
                HStack(spacing: 8) {
                    Text(verbatim: (folder as NSString).abbreviatingWithTildeInPath)
                        .font(.caption)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 6)
                    Button { model.removeFolder(folder) } label: { Image(systemName: "minus.circle") }
                        .glassButton()
                        .controlSize(.small)
                        .help("Klasörü listeden çıkar")
                        .accessibilityLabel("\(folder) klasörünü çıkar")
                }
            }
            Button("Klasör ekle…") { chooseFolder() }
                .glassButton()
                .controlSize(.small)
            if let error = model.errorText {
                Text(error).font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Ekle"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.addFolder(url.path)
        model.rescan()
    }
}

/// `@State` bu araç zincirinde derlenmez. Bu yüzden kopyalama bayrağı küçük bir nesnede durur.
private final class CopyFlag: ObservableObject {
    @Published var done = false
}

private struct FindingCard: View {
    let finding: SecretFinding
    let actionTitle: String
    let action: () -> Void
    @StateObject private var copy = CopyFlag()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(finding.severity.label)
                    .font(.nobetFootnote.weight(.semibold))
                    .foregroundStyle(color)
                Text(finding.kind.title).font(.callout.weight(.medium))
                Spacer()
                Button(actionTitle, action: action).buttonStyle(.link).font(.caption)
            }
            Text(verbatim: (finding.path as NSString).abbreviatingWithTildeInPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            if !finding.detail.isEmpty {
                Text(verbatim: finding.detail)
                    .font(.nobetFootnote)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let advice = finding.rotationAdvice {
                Text(verbatim: advice).font(.nobetFootnote).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let command = finding.suggestedCommand {
                HStack(spacing: 8) {
                    Text(verbatim: command)
                        .font(.nobetFootnote.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                    Spacer(minLength: 6)
                    Button(copy.done ? "Kopyalandı" : "Komutu kopyala") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(command, forType: .string)
                        copy.done = true
                    }
                    .glassButton()
                    .controlSize(.small)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var color: Color {
        switch finding.severity {
        case .high: return .red
        case .medium: return .orange
        case .info: return .secondary
        }
    }
}
