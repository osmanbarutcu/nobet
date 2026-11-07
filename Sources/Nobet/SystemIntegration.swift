import AppKit
import Carbon.HIToolbox
import os
import ServiceManagement

/// Günlük: `log show --predicate 'subsystem == "local.nobet"' --last 5m`
let integrationLog = Logger(subsystem: "local.nobet", category: "integration")

/// Genel kısayol ⌥⌘N. Carbon `RegisterEventHotKey` kullanır, erişilebilirlik izni gerektirmez.
enum GlobalHotKey {
    private static var hotKeyRef: EventHotKeyRef?
    private static var handlerRef: EventHandlerRef?
    /// Son kayıt denemesinin sonucu. `noErr` kayıtlı demektir.
    private(set) static var lastStatus: OSStatus = noErr

    /// Kayıt sonucunu döndürür ve günlüğe yazar. Olay işleyicisi bir kez kurulur,
    /// yoksa kısayolu kapatıp açmak işleyiciyi çoğaltır ve panel iki kez değişir.
    @discardableResult
    static func register() -> OSStatus {
        guard hotKeyRef == nil else { return lastStatus }
        var installStatus = noErr
        if handlerRef == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            installStatus = InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
                DispatchQueue.main.async { PanelToggle.toggle() }
                return noErr
            }, 1, &spec, nil, &handlerRef)
        }
        let identifier = EventHotKeyID(signature: OSType(0x4E4F4254), id: 1)
        let status = installStatus != noErr
            ? installStatus
            : RegisterEventHotKey(UInt32(kVK_ANSI_N), UInt32(optionKey | cmdKey), identifier, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr { hotKeyRef = nil }
        lastStatus = status
        if status == noErr {
            integrationLog.info("Kısayol ⌥⌘N kaydedildi")
        } else {
            integrationLog.error("Kısayol ⌥⌘N kaydedilemedi, hata kodu \(status)")
        }
        return status
    }

    static func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        lastStatus = noErr
    }

    /// Kullanıcıya gösterilen hata metni. Başarıda nil döner.
    static func failureText(_ status: OSStatus) -> String? {
        switch status {
        case noErr: return nil
        case OSStatus(eventHotKeyExistsErr): return "Kısayol ⌥⌘N kaydedilemedi: başka bir uygulama bu kısayolu tutuyor."
        default: return "Kısayol ⌥⌘N kaydedilemedi (hata \(status))."
        }
    }
}

/// MenuBarExtra paneli için açma API'si yoktur. Durum çubuğu düğmesinde eylem varsa ona tıklanır.
/// macOS 27'de SwiftUI düğmesinin eylemi yoktur; tıklama, fare olayı ve doğrudan `mouseDown` panel açmaz
/// (günlükle doğrulandı). O durumda kısayol ana pencereyi açar veya kapatır.
enum PanelToggle {
    /// Sistem iç sınıf adını değiştirirse düzey (status bar) eşleşmeyi sürdürür.
    static func isStatusItemWindow(className: String, level: Int) -> Bool {
        className.contains("StatusBar") || level == NSWindow.Level.statusBar.rawValue
    }

    /// Ana pencere görünür ve uygulama öndeyse kısayol pencereyi kapatır. Aksi halde açar.
    static func shouldCloseMain(isVisible: Bool, isActive: Bool) -> Bool {
        isVisible && isActive
    }

    @MainActor
    static func toggle() {
        for window in NSApp.windows where isStatusItemWindow(className: String(describing: type(of: window)), level: window.level.rawValue) {
            if let button = firstButton(in: window.contentView), button.action != nil {
                integrationLog.info("Panel düğmesine tıklandı")
                button.performClick(nil)
                return
            }
        }
        toggleMainWindow()
    }

    @MainActor
    private static func toggleMainWindow() {
        let main = NSApp.windows.first { $0.identifier?.rawValue.contains("main") == true }
        if let main, shouldCloseMain(isVisible: main.isVisible, isActive: NSApp.isActive) {
            integrationLog.info("Kısayol: ana pencere kapatıldı")
            main.close()
        } else {
            integrationLog.info("Kısayol: ana pencere açıldı")
            NotificationCenter.default.post(name: .nobetOpenMain, object: nil)
        }
    }

    private static func firstButton(in view: NSView?) -> NSButton? {
        guard let view else { return nil }
        if let button = view as? NSButton { return button }
        for child in view.subviews {
            if let found = firstButton(in: child) { return found }
        }
        return nil
    }
}

/// Girişte başlatma. macOS Giriş Öğeleri listesine kaydeder; kullanıcı onayı gerekebilir.
@MainActor
final class LoginItem: ObservableObject {
    @Published private(set) var isEnabled = SMAppService.mainApp.status == .enabled
    @Published private(set) var errorText: String?

    func set(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            errorText = nil
        } catch {
            errorText = error.localizedDescription
        }
        isEnabled = SMAppService.mainApp.status == .enabled
    }
}
