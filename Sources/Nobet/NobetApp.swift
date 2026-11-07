import SwiftUI

@main
struct NobetApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @ObservedObject private var model = NobetModel.shared

    init() {
        // ssh parola sorarken bu ikiliyi çağırır. Bu durumda parolayı yazıp çıkar, arayüz açılmaz.
        AskpassMode.runIfRequested()
        ServerModel.shared.startPolling()
        RemoteModel.shared.startPolling()
        if DemoMode.isOn {
            // Sahte veri kipi: gerçek diski taramaz, kısayol ve bildirim izni istemez.
            DemoMode.ingestFakeModules(into: .shared, nobet: .shared)
            return
        }
        let enabled = UserDefaults.standard.object(forKey: "hotkeyEnabled") as? Bool ?? true
        if enabled { GlobalHotKey.register() }
        SystemAlertNotifier().requestAuthorization()
        DevModel.shared.startPolling()
        SecretsModel.shared.startPolling()
    }

    var body: some Scene {
        MenuBarExtra {
            PanelView(model: model).nobetAppearance()
        } label: {
            MenuBarLabel(model: model)
        }
        .menuBarExtraStyle(.window)

        Window("Nöbet", id: "main") {
            MainWindowView(model: model).nobetAppearance()
        }
        .defaultSize(width: 920, height: 680)
        .defaultLaunchBehavior(.presented)
        .commands {
            CommandMenu("Sayfa") {
                Button("Sayfa ara…") { NotificationCenter.default.post(name: .nobetOpenPalette, object: nil) }
                    .keyboardShortcut("k", modifiers: .command)
                ForEach(NobetSection.allCases) { section in
                    let open = { UserDefaults.standard.set(section.rawValue, forKey: "mainSection") }
                    if let key = section.shortcut {
                        Button(section.rawValue, action: open).keyboardShortcut(key, modifiers: .command)
                    }
                }
            }
        }
    }
}

/// Menü çubuğu etiketi. Ana pencereyi açma isteğini de burada dinler, çünkü etiket her zaman canlıdır.
struct MenuBarLabel: View {
    @ObservedObject var model: NobetModel
    @ObservedObject private var center = AlertCenter.shared
    @AppStorage(AppearanceIconStyle.key) private var iconStyle = AppearanceIconStyle.binoculars.rawValue
    @Environment(\.openWindow) private var openWindow

    private var iconColor: Color {
        switch StatusLabel.tint(worst: center.worstVisibleSeverity) {
        case .none: return .primary
        case .warning: return .orange
        case .critical: return .red
        }
    }

    var body: some View {
        let title = StatusLabel.title(alertCount: model.alertCount)
        HStack(spacing: 4) {
            Image(systemName: AppearanceIconStyle(stored: iconStyle).symbol(filled: model.alertCount > 0))
                .symbolRenderingMode(.palette)
                .foregroundStyle(iconColor)
            if !title.isEmpty { Text(title).monospacedDigit() }
        }
        .accessibilityLabel(StatusLabel.accessibility(alertCount: model.alertCount))
        .onReceive(NotificationCenter.default.publisher(for: .nobetOpenMain)) { _ in
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
