import SwiftUI

/// Süzgeç çubuğunun durumu. `@State` bu araç zincirinde derlenmez.
final class FilterModel: ObservableObject {
    @Published var filter = AlertFilter() { didSet { page = 0 } }
    @Published var sort = AlertSort.severity
    @Published var pageSize = PageSize.twenty { didSet { page = 0 } }
    @Published var page = 0
    @Published var panelShown = false
    @Published var saveShown = false
    @Published var saveName = ""
    @Published private(set) var saved: [SavedFilters.Entry]

    private let store: SavedFilters

    init(store: SavedFilters = SavedFilters(), sort: AlertSort = .severity) {
        self.store = store
        self.sort = sort
        saved = store.all
    }

    func saveCurrent() {
        store.save(name: saveName, filter: filter)
        saved = store.all
        saveName = ""
        saveShown = false
    }

    func delete(_ name: String) {
        store.delete(name: name)
        saved = store.all
    }

    func toggle(severity: Severity) {
        var next = filter
        if next.severities.contains(severity) { next.severities.remove(severity) } else { next.severities.insert(severity) }
        filter = next
    }

    func toggle(module: String) {
        var next = filter
        if next.modules.contains(module) { next.modules.remove(module) } else { next.modules.insert(module) }
        filter = next
    }
}

/// Ortak süzgeç çubuğu: arama, önem, modül, durum, süre, sıralama, çipler ve kayıtlı süzgeçler.
struct FilterBar: View {
    @ObservedObject var model: FilterModel
    var showsRange = true

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Ara", text: Binding(get: { model.filter.text }, set: { model.filter.text = $0 }))
                    .textFieldStyle(.roundedBorder).frame(maxWidth: 180)
                Button { model.panelShown.toggle() } label: {
                    Label(panelTitle, systemImage: "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(.link)
                .popover(isPresented: $model.panelShown) { panel }
                Menu {
                    Picker("Sırala", selection: $model.sort) {
                        ForEach(AlertSort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.inline)
                } label: {
                    Text("Sırala: \(model.sort.title)")
                }
                .fixedSize()
                .accessibilityLabel("Sırala, şu an \(model.sort.title)")
                savedMenu
            }
            .menuStyle(.borderlessButton)
            .font(.caption)
            if showsRange && model.filter.range == .custom {
                HStack {
                    DatePicker("Başlangıç", selection: Binding(get: { model.filter.from == .distantPast ? Date().addingTimeInterval(-86_400) : model.filter.from },
                                                              set: { model.filter.from = $0 }))
                    DatePicker("Bitiş", selection: Binding(get: { model.filter.to == .distantFuture ? Date() : model.filter.to },
                                                          set: { model.filter.to = $0 }))
                }
                .font(.caption)
            }
            if model.filter.isActive { chips }
        }
    }

    /// Metin dışındaki etkin süzgeç sayısı.
    private var activeCount: Int { model.filter.chips.filter { $0.dimension != .text }.count }

    private var panelTitle: String { activeCount == 0 ? "Süzgeçler" : "Süzgeçler (\(activeCount))" }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Süzgeçler").font(.callout.weight(.semibold))
            VStack(alignment: .leading, spacing: 4) {
                Text("Önem").font(.caption).foregroundStyle(.secondary)
                HStack {
                    ForEach([Severity.high, .medium, .info], id: \.self) { level in
                        Toggle(level.label, isOn: Binding(get: { model.filter.severities.contains(level) }, set: { _ in model.toggle(severity: level) }))
                            .toggleStyle(.button)
                    }
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Modül").font(.caption).foregroundStyle(.secondary)
                HStack {
                    ForEach(ModuleNames.order, id: \.self) { key in
                        Toggle(isOn: Binding(get: { model.filter.modules.contains(key) }, set: { _ in model.toggle(module: key) })) {
                            Label(ModuleNames.title(key), systemImage: ModuleNames.symbol(key))
                        }
                        .toggleStyle(.button)
                    }
                }
            }
            Picker("Durum", selection: Binding(get: { model.filter.status }, set: { model.filter.status = $0 })) {
                ForEach(AlertStatus.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            if showsRange {
                Picker("Süre", selection: Binding(get: { model.filter.range }, set: { model.filter.range = $0 })) {
                    ForEach(AlertRange.allCases, id: \.self) { Text($0.title).tag($0) }
                }
            }
            HStack {
                Spacer()
                Button("Temizle") { model.filter = model.filter.cleared() }.disabled(!model.filter.isActive)
            }
        }
        .controlSize(.small)
        .padding(14)
        .frame(width: 520)
    }

    private var chips: some View {
        HStack(spacing: 6) {
            ForEach(model.filter.chips) { chip in
                Button { model.filter = model.filter.removing(chip.dimension) } label: {
                    HStack(spacing: 4) {
                        Text(chip.title)
                        Image(systemName: "xmark")
                    }
                    .font(.nobetFootnote)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(chip.title) süzgecini kaldır")
            }
            Button("Temizle") { model.filter = model.filter.cleared() }.buttonStyle(.link).font(.caption)
        }
    }

    private var savedMenu: some View {
        Menu("Kayıtlı") {
            ForEach(model.saved, id: \.name) { entry in
                Button(entry.name) { model.filter = entry.filter }
            }
            if !model.saved.isEmpty {
                Menu("Sil") {
                    ForEach(model.saved, id: \.name) { entry in Button(entry.name) { model.delete(entry.name) } }
                }
            }
            Button("Geçerli süzgeci kaydet…") { model.saveShown = true }.disabled(!model.filter.isActive)
        }
        .popover(isPresented: $model.saveShown) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Süzgeç adı").font(.caption).foregroundStyle(.secondary)
                TextField("Örn. Üretim, yüksek", text: $model.saveName).frame(width: 220)
                HStack {
                    Spacer()
                    Button("Kaydet") { model.saveCurrent() }.keyboardShortcut(.defaultAction)
                        .disabled(model.saveName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(12)
        }
    }
}

/// Sayfalama çubuğu. Tek sayfa varsa yalnızca sayfa boyutu seçici görünür.
struct PagerBar: View {
    @ObservedObject var model: FilterModel
    let total: Int

    var body: some View {
        let pages = model.pageSize.pageCount(for: total)
        HStack(spacing: 8) {
            Text("\(total) kayıt").font(.caption).foregroundStyle(.secondary)
            Spacer()
            Picker("Sayfa boyutu", selection: $model.pageSize) {
                ForEach(PageSize.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .frame(maxWidth: 130).font(.caption)
            if pages > 1 {
                Button { model.page = max(0, model.page - 1) } label: { Image(systemName: "chevron.left") }
                    .disabled(model.page == 0)
                Text("\(min(model.page, pages - 1) + 1) / \(pages)").font(.caption.monospacedDigit())
                Button { model.page = min(pages - 1, model.page + 1) } label: { Image(systemName: "chevron.right") }
                    .disabled(model.page >= pages - 1)
            }
        }
        .buttonStyle(.borderless)
    }
}
