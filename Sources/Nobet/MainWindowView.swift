import SwiftUI

/// Ana pencere. Kenar çubuğu seçimi `mainSection` ayarında saklanır.
struct MainWindowView: View {
    @ObservedObject var model: NobetModel
    @AppStorage("mainSection") private var storedSection = NobetSection.general.rawValue
    @StateObject private var palette = PaletteSheetState()
    @ObservedObject private var center = AlertCenter.shared

    /// Kenar çubuğu rozeti. Genel: tüm açık sorunlar. Diğerleri: sayfanın modüllerindeki sorunlar. 0 ise rozet görünmez.
    private func badgeCount(_ section: NobetSection) -> Int {
        switch section {
        case .general: return center.visibleActive.count
        case .development, .servers, .secrets:
            return ModuleNames.order.filter { ModuleNames.section($0) == section }.reduce(0) { $0 + center.visibleCount(module: $1) }
        case .settings, .about: return 0
        }
    }

    var body: some View {
        let current = NobetSection(rawValue: storedSection) ?? .general
        let selection = Binding<NobetSection?>(
            get: { current },
            set: { storedSection = ($0 ?? .general).rawValue }
        )
        NavigationSplitView {
            List(selection: selection) {
                ForEach(NobetSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.symbol)
                        .badge(badgeCount(section))
                        .badgeProminence(.increased)
                        .tag(section)
                }
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            SectionPage(section: current, model: model)
                .id(current)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .background(AmbientBackground())
        }
        .navigationTitle(current.rawValue)
        .navigationSubtitle(StatusLabel.subtitle(alertCount: model.alertCount))
        .frame(minWidth: 820, minHeight: 560)
        .sheet(isPresented: $palette.shown) {
            CommandPaletteView { section in
                storedSection = section.rawValue
                palette.shown = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .nobetOpenPalette)) { _ in palette.shown = true }
    }
}

final class PaletteSheetState: ObservableObject {
    @Published var shown = false
}

/// Seçili sayfanın içeriği. Modüller hazır oldukça buradaki yer tutucu gerçek sayfayla değişir.
struct SectionPage: View {
    let section: NobetSection
    @ObservedObject var model: NobetModel

    var body: some View {
        switch section {
        case .development:
            DevelopmentPage(model: DevModel.shared)
        case .servers:
            ServersPage(model: ServerModel.shared)
        case .secrets:
            SecretsPage(model: SecretsModel.shared)
        case .general:
            GeneralPage(center: AlertCenter.shared, model: model)
        case .settings:
            SettingsPage()
        case .about:
            AboutPage(center: AlertCenter.shared)
        }
    }
}

/// Henüz yazılmamış modül sayfası. Yapılmadığını açıkça söyler.
struct ModulePlaceholder: View {
    let section: NobetSection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            CardHeader(symbol: section.symbol, title: section.rawValue)
            Text("Bu modül henüz yazılmadı.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: 520, alignment: .leading)
        .glassCard()
        .padding(24)
    }
}
