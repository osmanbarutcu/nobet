import SwiftUI

/// `@State` bu araç zincirinde derlenmez. Bu yüzden onay bayrağı küçük bir nesnede durur.
private final class EnvEditorUIState: ObservableObject {
    @Published var confirmSave = false
}

/// `.env` dosyasını satır satır düzenler. Değerler varsayılan gizlidir. Kaydetmeden önce modal onay ister.
struct EnvEditorSheet: View {
    @StateObject private var model: SecretEditModel
    @StateObject private var ui = EnvEditorUIState()
    private let displayPath: String
    private let onSaved: () -> Void
    private let onClose: () -> Void

    init(path: String, onSaved: @escaping () -> Void, onClose: @escaping () -> Void) {
        _model = StateObject(wrappedValue: SecretEditModel(path: path))
        displayPath = (path as NSString).abbreviatingWithTildeInPath
        self.onSaved = onSaved
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(symbol: "pencil", title: ".env düzenle")
            Text(verbatim: displayPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("Değerler gizli. Göz simgesi bir değeri gösterir. Silinen satır, Kaydet'e basana kadar dosyada kalır. Yorumlar ve diğer satırlar aynen korunur.")
                .font(.nobetFootnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if let error = model.errorText {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            if let document = model.document {
                entries(document)
            }
            footer
        }
        .padding(20)
        .frame(width: 560)
        .onAppear { model.load() }
        .alert("Dosya değiştirilsin mi?", isPresented: $ui.confirmSave) {
            Button("Kaydet") { if model.save() { onSaved() } }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("\(model.summary). Dosya yerinde değişir ve geri alınamaz. Nöbet yedek tutmaz.")
        }
    }

    private func entries(_ document: EnvDocument) -> some View {
        let rows = document.lines.filter { $0.key != nil }
        return Group {
            if rows.isEmpty {
                Text("Dosyada KEY=VALUE satırı yok.").font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(rows) { row in entryRow(row) }
                    }
                }
                .frame(maxHeight: 360)
            }
        }
    }

    private func entryRow(_ line: EnvLine) -> some View {
        let key = line.key ?? ""
        let binding = Binding(get: { model.document?.lines[line.id].value ?? "" }, set: { model.setValue(line.id, $0) })
        return HStack(spacing: 8) {
            Text(verbatim: key)
                .font(.callout.monospaced())
                .strikethrough(line.deleted)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 170, alignment: .leading)
            Group {
                if model.revealed.contains(line.id) {
                    TextField("", text: binding)
                } else {
                    SecureField("", text: binding)
                }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(line.deleted)
            .accessibilityLabel("\(key) değeri")
            Button { toggleReveal(line.id) } label: {
                Image(systemName: model.revealed.contains(line.id) ? "eye.slash" : "eye")
            }
            .glassButton()
            .controlSize(.small)
            .help(model.revealed.contains(line.id) ? "Değeri gizle" : "Değeri göster")
            .accessibilityLabel(model.revealed.contains(line.id) ? "\(key) değerini gizle" : "\(key) değerini göster")
            Button { model.toggleDelete(line.id) } label: {
                Image(systemName: line.deleted ? "arrow.uturn.backward" : "trash")
            }
            .glassButton()
            .controlSize(.small)
            .help(line.deleted ? "Silmeyi geri al" : "Satırı sil")
            .accessibilityLabel(line.deleted ? "\(key) silmeyi geri al" : "\(key) satırını sil")
        }
        .opacity(line.deleted ? 0.55 : 1)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Text(model.summary).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button("Vazgeç", action: onClose).glassButton()
            Button("Kaydet") { ui.confirmSave = true }
                .glassButton()
                .disabled(!model.hasChanges)
        }
    }

    private func toggleReveal(_ id: Int) {
        if model.revealed.contains(id) { model.revealed.remove(id) } else { model.revealed.insert(id) }
    }
}
