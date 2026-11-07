import AppKit
import Carbon
import UserNotifications

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if Bundle.main.bundleIdentifier != nil { UNUserNotificationCenter.current().delegate = self }
        NotificationAction.register()
        KeychainDiag.runIfRequested()
        // Geliştirme: NOBET_DIAG_CLOSE_MAIN=1 ana pencereyi 3 sn sonra kapatır. Uygulamanın yaşayıp yaşamadığını sınar.
        if ProcessInfo.processInfo.environment["NOBET_DIAG_CLOSE_MAIN"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                for window in NSApp.windows where window.identifier?.rawValue.contains("main") == true { window.close() }
            }
        }
        // Giriş öğesi olarak başlatıldıysa pencere açılmaz, yalnızca menü çubuğu kalır.
        let event = NSAppleEventManager.shared().currentAppleEvent
        let launchedAtLogin = event?.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue
            == OSType(keyAELaunchedAsLogInItem)
        guard launchedAtLogin else { return }
        DispatchQueue.main.async {
            for window in NSApp.windows where window.identifier?.rawValue.contains("main") == true {
                window.close()
            }
        }
    }

    /// Uygulama öndeyken de bildirim başlığı gösterilir.
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    /// Bildirime tıklayınca ilgili sayfayı ana pencerede açar.
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        let identifier = response.notification.request.identifier
        let snoozeKey = NotificationAction.snoozeKey(action: response.actionIdentifier, userInfo: response.notification.request.content.userInfo)
        DispatchQueue.main.async {
            if let snoozeKey {
                AlertCenter.shared.snooze(key: snoozeKey, for: NotificationAction.snoozeSeconds)
                completionHandler()
                return
            }
            if let section = NotificationRoute.section(for: identifier) {
                UserDefaults.standard.set(section.rawValue, forKey: "mainSection")
                NotificationCenter.default.post(name: .nobetOpenMain, object: nil)
                NSApp.activate(ignoringOtherApps: true)
            }
            completionHandler()
        }
    }

    /// Ana pencere kapanınca uygulama çıkmaz. Menü çubuğu öğesi çalışmaya devam eder.
    /// Çıkış için panelde "Çık" ya da ⌘Q kullanılır.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock simgesine tıklanınca görünür pencere yoksa ana pencere açılır.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { NotificationCenter.default.post(name: .nobetOpenMain, object: nil) }
        return true
    }
}
