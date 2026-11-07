import SwiftUI

/// İlk açılış karşılaması. Kapatınca bir daha görünmez.
final class Onboarding: ObservableObject {
    static let key = "onboarding.done"
    static let steps = [
        "Geliştirme sayfası Docker, portlar ve bağımlılıkları okur.",
        "Sunucular sayfasında web sitesi ve SSH sunucusu ekleyin.",
        "Sırlar sayfası seçtiğiniz klasörde sızan anahtarları arar.",
        "Parolalar yalnızca macOS Anahtar Zinciri'nde durur.",
    ]

    @Published private(set) var isVisible: Bool
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isVisible = !defaults.bool(forKey: Self.key)
    }

    func finish() {
        defaults.set(true, forKey: Self.key)
        isVisible = false
    }
}

struct OnboardingCard: View {
    @ObservedObject var onboarding: Onboarding

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                CardHeader(symbol: "hand.wave", title: "Nöbet'e hoş geldiniz")
                Button("Anladım") { onboarding.finish() }
                    .glassProminentButton()
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .topLeading), GridItem(.flexible(), alignment: .topLeading)], spacing: 8) {
                ForEach(Array(Onboarding.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1)")
                            .font(.nobetFootnote.weight(.bold).monospacedDigit())
                            .frame(width: 18, height: 18)
                            .background(Color.accentColor.opacity(0.18), in: Circle())
                            .accessibilityHidden(true)
                        Text(step).font(.caption).fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("\(index + 1). \(step)")
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard()
    }
}
