import AppKit
import SwiftUI

/// `@State` bu araç zincirinde derlenmez. Bu yüzden sheet durumu küçük bir nesnede durur.
private final class SecretsPageState: ObservableObject {
    @Published var editing: SecretFinding?
    @Published var query = ""
}

/// Sır tarayıcı: yerel dosyalardaki riskli izinleri ve açıkta kalan sırları listeler.
/// Dosyayı yalnızca kullanıcı `.env` bulgusunda Düzenle deyip onaylarsa değiştirir.
struct SecretsPage: View {
    @ObservedObject var model: SecretsModel
    @StateObject private var state = SecretsPageState()

    var body: some View {
        PageContainer {
                header
                searchField
                if !shownKeys.isEmpty { keysCard }
                foldersCard
                if isSearching && shownKeys.isEmpty && shownFindings.isEmpty && shownIgnored.isEmpty {
                    EmptyState(symbol: "magnifyingglass", title: "Eşleşme yok",
                               message: "\"\(state.query)\" için bulgu veya SSH anahtarı bulunamadı. Başka bir sözcük deneyin.")
                }
                if !isSearching && model.scanned && model.findings.isEmpty {
                    EmptyState(symbol: "checkmark.shield", title: "Bulgu yok",
                               message: "Taranan yerlerde riskli dosya bulunamadı. Başka bir klasörü taramak için Klasör ekle düğmesini kullanın.")
                }
                ForEach(shownFindings) { finding in
                    FindingCard(finding: finding, actionTitle: "Yok say", action: { model.ignore(finding) },
                                onEdit: SecretEditor.canEdit(finding) ? { state.editing = finding } : nil)
                }
                if !shownIgnored.isEmpty {
                    Text("Yok sayılanlar (\(shownIgnored.count))").font(.callout.weight(.medium)).padding(.top, 8)
                    ForEach(shownIgnored) { finding in
                        FindingCard(finding: finding, actionTitle: "Geri al") { model.unignore(finding) }
                            .opacity(0.6)
                    }
                }
        }
        .onAppear { if !model.scanned { model.rescan() } }
        .sheet(item: $state.editing) { finding in
            EnvEditorSheet(path: finding.path) {
                model.didEdit(path: finding.path)
                state.editing = nil
            } onClose: {
                state.editing = nil
            }
        }
    }

    private var isSearching: Bool { !state.query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var shownFindings: [SecretFinding] { model.findings.filter { SecretSearch.matches($0, query: state.query) } }
    private var shownIgnored: [SecretFinding] { model.ignoredFindings.filter { SecretSearch.matches($0, query: state.query) } }
    private var shownKeys: [SSHKeyInfo] { model.sshKeys.filter { SecretSearch.matches($0, query: state.query) } }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Ara: dosya adı, yol, ssh, anahtar", text: $state.query)
                .textFieldStyle(.plain)
                .accessibilityLabel("Sırlarda ara")
            if isSearching {
                Button { state.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("Aramayı temizle")
                    .accessibilityLabel("Aramayı temizle")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }

    private var keysCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(symbol: "key.horizontal", title: "SSH anahtarları", trailing: "\(shownKeys.count)")
            Text("~/.ssh içindeki özel anahtar dosyaları. Nöbet içeriği okumaz, yalnızca yolu gösterir.")
                .font(.nobetFootnote)
                .foregroundStyle(.secondary)
            ForEach(shownKeys) { key in SSHKeyRow(key: key) }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
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
            Text("Nöbet taramada yalnızca okur. Sır değerini listede göstermez ve kaydetmez. Dosyayı yalnızca .env bulgusunda Düzenle deyip onaylarsanız değiştirir. Diğer düzeltme komutlarını siz çalıştırırsınız.")
                .font(.nobetFootnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let notice = model.notice {
                HStack(spacing: 8) {
                    Text(verbatim: notice).font(.caption).foregroundStyle(.green)
                    Spacer(minLength: 6)
                    Button("Tamam") { model.dismissNotice() }.buttonStyle(.link).font(.caption)
                }
            }
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
            Toggle(isOn: Binding(get: { model.scanSource }, set: { model.setScanSource($0) })) {
                Text("Kaynak kodda jeton ara").font(.callout)
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            Text("Kod ve yapılandırma dosyalarında GitHub, AWS, Stripe gibi bilinen jeton biçimlerini arar. Dosyalar yalnızca okunur. Jeton değeri gösterilmez. Çok dosya okuduğu için varsayılan kapalıdır.")
                .font(.nobetFootnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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

private struct SSHKeyRow: View {
    let key: SSHKeyInfo
    @StateObject private var copy = CopyFlag()
    @StateObject private var copyPublic = CopyFlag()

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: key.name).font(.callout.weight(.medium))
                Text(verbatim: (key.path as NSString).abbreviatingWithTildeInPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: "\(key.isEncrypted ? "parolalı" : "parolasız") · izin \(FileMode.octal(key.mode))\(key.isLoose ? " (gevşek)" : "")")
                    .font(.nobetFootnote)
                    .foregroundStyle(key.isLoose ? .orange : .secondary)
            }
            Spacer(minLength: 6)
            if let publicKey = PublicKey.load(forKeyAt: key.path) {
                Button(copyPublic.done ? "Kopyalandı" : "Açık anahtarı kopyala") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(publicKey, forType: .string)
                    copyPublic.done = true
                }
                .glassButton()
                .controlSize(.small)
                .help("Sunucuya eklemek için .pub dosyasının içeriğini kopyalar")
            }
            Button(copy.done ? "Kopyalandı" : "Yolu kopyala") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(key.path, forType: .string)
                copy.done = true
            }
            .glassButton()
            .controlSize(.small)
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: key.path)]) } label: { Image(systemName: "folder") }
                .glassButton()
                .controlSize(.small)
                .help("Finder'da göster")
                .accessibilityLabel("\(key.name) dosyasını Finder'da göster")
        }
    }
}

private struct FindingCard: View {
    let finding: SecretFinding
    let actionTitle: String
    let action: () -> Void
    var onEdit: (() -> Void)?
    @StateObject private var copy = CopyFlag()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(finding.severity.label)
                    .font(.nobetFootnote.weight(.semibold))
                    .foregroundStyle(color)
                Text(finding.kind.title).font(.callout.weight(.medium))
                Spacer()
                if let onEdit { Button("Düzenle", action: onEdit).buttonStyle(.link).font(.caption) }
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
