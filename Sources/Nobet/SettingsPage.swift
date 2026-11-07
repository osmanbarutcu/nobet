import SwiftUI

/// Kısayol kayıt hatasını görünümde tutar. `@State` bu derleme ortamında çalışmaz.
@MainActor
final class HotkeyStatus: ObservableObject {
    @Published var errorText: String?
}

/// Genel ayarlar: kısayol ve girişte başlatma.
struct SettingsPage: View {
    @AppStorage("hotkeyEnabled") private var hotkeyEnabled = true
    @StateObject private var loginItem = LoginItem()
    @StateObject private var hotkey = HotkeyStatus()
    @AppStorage(AlertCenter.notifyKey) private var notify = true
    @AppStorage(AlertCenter.weeklyKey) private var weekly = true
    @AppStorage(AppearanceAccent.key) private var accent = AppearanceAccent.indigo.rawValue
    @AppStorage(AppearanceTheme.key) private var theme = AppearanceTheme.system.rawValue
    @AppStorage(AppearanceDensity.key) private var density = AppearanceDensity.comfortable.rawValue
    @AppStorage(AppearanceTextScale.key) private var textScale = AppearanceTextScale.standard.rawValue
    @AppStorage(GlassDensity.key) private var glass = GlassDensity.standard
    @AppStorage(AppearanceIconStyle.key) private var iconStyle = AppearanceIconStyle.binoculars.rawValue
    @AppStorage(PanelLayout.key) private var panelLayout = PanelLayout.standard.rawValue
    @AppStorage(UpdateCheck.enabledKey) private var updateCheckEnabled = false
    @ObservedObject private var updates = UpdateModel.shared
    @AppStorage("history.persist") private var persistHistory = false
    @AppStorage(AlertCenter.quietEnabledKey) private var quietEnabled = true
    @AppStorage(AlertCenter.quietStartKey) private var quietStart = 23 * 60
    @AppStorage(AlertCenter.quietEndKey) private var quietEnd = 8 * 60
    @AppStorage(AlertCenter.weekendCustomKey) private var weekendCustom = false
    @AppStorage(AlertCenter.weekendStartKey) private var weekendStart = 0
    @AppStorage(AlertCenter.weekendEndKey) private var weekendEnd = 10 * 60
    @AppStorage(AlertCenter.soundKey) private var sound = AlertSoundMode.highOnly.rawValue

    private func hourBinding(_ minutes: Binding<Int>) -> Binding<Int> {
        Binding(get: { minutes.wrappedValue / 60 }, set: { minutes.wrappedValue = $0 * 60 })
    }

    private func hourPicker(_ title: String, _ minutes: Binding<Int>) -> some View {
        Picker(title, selection: hourBinding(minutes)) {
            ForEach(0..<24, id: \.self) { Text(String(format: "%02d:00", $0)).tag($0) }
        }
        .frame(maxWidth: 200)
    }

    var body: some View {
        PageContainer {
                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(symbol: "paintbrush", title: "Görünüm")
                    Picker("Tema", selection: $theme) {
                        ForEach(AppearanceTheme.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 320)
                    HStack(spacing: 10) {
                        Text("Vurgu rengi").font(.callout)
                        ForEach(AppearanceAccent.allCases, id: \.rawValue) { option in
                            Button { accent = option.rawValue } label: {
                                Circle().fill(option.color).frame(width: 18, height: 18)
                                    .overlay(Circle().strokeBorder(Color.primary, lineWidth: accent == option.rawValue ? 2 : 0).padding(-3))
                            }
                            .buttonStyle(.plain)
                            .help(option.title)
                            .accessibilityLabel("\(option.title)\(accent == option.rawValue ? ", seçili" : "")")
                        }
                    }
                    Picker("Yoğunluk", selection: $density) {
                        ForEach(AppearanceDensity.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 320)
                    Picker("Menü çubuğu simgesi", selection: $iconStyle) {
                        ForEach(AppearanceIconStyle.allCases, id: \.rawValue) { style in
                            Label(style.title, systemImage: style.symbol(filled: false)).tag(style.rawValue)
                        }
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 360)
                    Picker("Menü paneli", selection: $panelLayout) {
                        ForEach(PanelLayout.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 320)
                    Picker("Yazı boyutu", selection: $textScale) {
                        ForEach(AppearanceTextScale.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }
                    .pickerStyle(.segmented).frame(maxWidth: 320)
                    HStack(spacing: 10) {
                        Text("Cam yoğunluğu").font(.callout)
                        Slider(value: $glass, in: GlassDensity.range).frame(maxWidth: 220)
                            .accessibilityLabel("Cam yoğunluğu")
                            .accessibilityValue(A11y.percent(glass * 100))
                        Button("Sıfırla") { glass = GlassDensity.standard }.buttonStyle(.link).font(.caption)
                    }
                    Text("Düşük değer camı saydamlaştırır. Yüksek değer metni okunaklı yapar.").font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()

                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(symbol: "keyboard", title: "Kısayol")
                    Toggle("⌥⌘N ile ana pencereyi aç veya kapat", isOn: $hotkeyEnabled)
                        .toggleStyle(RightSwitchStyle())
                        .controlSize(.small)
                        .onChange(of: hotkeyEnabled) { _, enabled in
                            if enabled {
                                hotkey.errorText = GlobalHotKey.failureText(GlobalHotKey.register())
                            } else {
                                GlobalHotKey.unregister()
                                hotkey.errorText = nil
                            }
                        }
                    if let error = hotkey.errorText {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()

                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(symbol: "bell", title: "Bildirimler")
                    Toggle("Yeni sorunda ve düzelmede bildirim gönder", isOn: $notify)
                        .toggleStyle(RightSwitchStyle())
                        .controlSize(.small)
                    Picker("Bildirim sesi", selection: $sound) {
                        ForEach(AlertSoundMode.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }
                    .frame(maxWidth: 320)
                    Toggle("Pazartesi 09:00'da haftalık özet gönder", isOn: $weekly)
                        .toggleStyle(RightSwitchStyle())
                        .controlSize(.small)
                    Toggle("Grafik geçmişini diske kaydet (yeniden açılışta geçerli)", isOn: $persistHistory)
                        .toggleStyle(RightSwitchStyle())
                        .controlSize(.small)
                    Toggle("Sessiz saatlerde bildirim gönderme", isOn: $quietEnabled)
                        .toggleStyle(RightSwitchStyle())
                        .controlSize(.small)
                        .disabled(!notify)
                    if quietEnabled && notify {
                        hourPicker("Başlangıç", $quietStart)
                        hourPicker("Bitiş", $quietEnd)
                        Toggle("Hafta sonu için ayrı saat", isOn: $weekendCustom)
                            .toggleStyle(RightSwitchStyle())
                            .controlSize(.small)
                        if weekendCustom {
                            hourPicker("Hafta sonu başlangıç", $weekendStart)
                            hourPicker("Hafta sonu bitiş", $weekendEnd)
                        }
                    }
                    Text("Sessiz saatte sorunlar yine Genel sayfasındaki geçmişe yazılır.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()

                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(symbol: "arrow.down.circle", title: "Güncellemeler", trailing: "Sürüm \(UpdateCheck.currentVersion)")
                    Toggle("Yeni sürümü GitHub'dan denetle", isOn: $updateCheckEnabled)
                        .toggleStyle(RightSwitchStyle())
                        .controlSize(.small)
                        .onChange(of: updateCheckEnabled) { _, enabled in
                            if enabled { Task { await updates.checkIfDue() } }
                        }
                    if let update = updates.availableUpdate, updateCheckEnabled {
                        Text("Yeni sürüm var: \(update.version)").font(.caption.weight(.semibold))
                        Button("Sürüm sayfasını aç") { NSWorkspace.shared.open(update.url) }
                            .controlSize(.small)
                    }
                    Text("Kapalıdır. Açarsanız Nöbet günde en çok 1 kez api.github.com adresine istek gönderir. GitHub IP adresinizi görür. Veri gönderilmez, indirme yapılmaz.")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()

                VStack(alignment: .leading, spacing: 10) {
                    CardHeader(symbol: "power", title: "Başlatma")
                    Toggle("Girişte başlat", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.set($0) }))
                        .toggleStyle(RightSwitchStyle())
                        .controlSize(.small)
                    if let error = loginItem.errorText {
                        Text(error).font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard()
        }
    }
}
