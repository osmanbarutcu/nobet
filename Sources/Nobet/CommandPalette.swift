import SwiftUI

/// ⌘K paletinin bir satırı. Satır bir sayfaya gider.
struct PaletteEntry: Equatable, Identifiable {
    let section: NobetSection
    let keywords: [String]

    var id: String { section.rawValue }
}

enum CommandPalette {
    static let entries: [PaletteEntry] = [
        PaletteEntry(section: .general, keywords: ["uyarı", "sorun", "özet", "zaman çizelgesi"]),
        PaletteEntry(section: .development, keywords: ["docker", "port", "bağımlılık", "sbom", "git"]),
        PaletteEntry(section: .servers, keywords: ["ssh", "site", "sertifika", "uptime", "sunucu"]),
        PaletteEntry(section: .secrets, keywords: ["parola", "anahtar", "token", "env"]),
        PaletteEntry(section: .settings, keywords: ["tema", "renk", "bildirim", "ses", "görünüm"]),
        PaletteEntry(section: .about, keywords: ["sürüm", "tanılama", "rapor"]),
    ]

    static func matches(_ query: String) -> [PaletteEntry] {
        let needle = AlertFilter.fold(query.trimmingCharacters(in: .whitespaces))
        guard !needle.isEmpty else { return entries }
        return entries.filter { entry in
            ([entry.section.rawValue] + entry.keywords).contains { AlertFilter.fold($0).contains(needle) }
        }
    }
}

final class PaletteModel: ObservableObject {
    @Published var query = ""
}

/// Komut paleti. Yazınca süzer, Return ilk satıra gider.
struct CommandPaletteView: View {
    @StateObject private var model = PaletteModel()
    let onSelect: (NobetSection) -> Void

    var body: some View {
        let results = CommandPalette.matches(model.query)
        VStack(alignment: .leading, spacing: 10) {
            TextField("Sayfa ara", text: $model.query)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if let first = results.first { onSelect(first.section) } }
            if results.isEmpty {
                Text("Eşleşen sayfa yok.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(results) { entry in
                Button { onSelect(entry.section) } label: {
                    Label(entry.section.rawValue, systemImage: entry.section.symbol)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(16)
        .frame(width: 360)
    }
}
