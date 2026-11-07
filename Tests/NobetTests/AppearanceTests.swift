import Foundation
import Testing
@testable import Nobet

struct AppearanceTests {
    @Test func unknownStoredValuesFallBackToDefaults() {
        #expect(AppearanceAccent(stored: "yok") == .indigo)
        #expect(AppearanceAccent(stored: nil) == .indigo)
        #expect(AppearanceTheme(stored: "yok") == .system)
        #expect(AppearanceDensity(stored: "yok") == .comfortable)
        #expect(AppearanceTextScale(stored: "yok") == .standard)
    }

    @Test func storedValuesRoundTrip() {
        for accent in AppearanceAccent.allCases { #expect(AppearanceAccent(stored: accent.rawValue) == accent) }
        for theme in AppearanceTheme.allCases { #expect(AppearanceTheme(stored: theme.rawValue) == theme) }
        for density in AppearanceDensity.allCases { #expect(AppearanceDensity(stored: density.rawValue) == density) }
        for scale in AppearanceTextScale.allCases { #expect(AppearanceTextScale(stored: scale.rawValue) == scale) }
    }

    @Test func thereAreSixAccentColorsWithTurkishTitles() {
        #expect(AppearanceAccent.allCases.count == 6)
        #expect(AppearanceAccent.allCases.map(\.title) == ["Çivit", "Mavi", "Yeşil", "Turuncu", "Pembe", "Gri"])
    }

    @Test func themeTitlesAreTurkish() {
        #expect(AppearanceTheme.allCases.map(\.title) == ["Otomatik", "Açık", "Koyu"])
    }

    @Test func compactDensityIsTighterThanComfortable() {
        #expect(AppearanceDensity.compact.pageSpacing < AppearanceDensity.comfortable.pageSpacing)
        #expect(AppearanceDensity.compact.pagePadding < AppearanceDensity.comfortable.pagePadding)
    }

    @Test func textScaleGrowsMonotonically() {
        let factors = AppearanceTextScale.allCases.map(\.factor)
        #expect(factors == factors.sorted())
        #expect(AppearanceTextScale.standard.factor == 1)
    }

    @Test func iconStylesGiveDistinctFilledAndOutlineSymbols() {
        for style in AppearanceIconStyle.allCases {
            #expect(style.symbol(filled: false) != style.symbol(filled: true))
        }
        #expect(Set(AppearanceIconStyle.allCases.map { $0.symbol(filled: false) }).count == 3)
    }

    @Test func unknownIconStyleFallsBackToBinoculars() {
        #expect(AppearanceIconStyle(stored: "yok") == .binoculars)
        #expect(AppearanceIconStyle.allCases.map(\.title) == ["Dürbün", "Göz", "Kalkan"])
    }
}

struct PanelLayoutTests {
    @Test func unknownStoredValueFallsBackToStandard() {
        #expect(PanelLayout(stored: "yok") == .standard)
        #expect(PanelLayout(stored: nil) == .standard)
    }

    @Test func compactHidesServersAndSites() {
        #expect(PanelLayout.standard.showsServers && PanelLayout.standard.showsSites)
        #expect(!PanelLayout.compact.showsServers && !PanelLayout.compact.showsSites)
        #expect(PanelLayout.allCases.map(\.title) == ["Tam", "Kısa"])
    }
}

struct MotionTests {
    @Test func reducedMotionRemovesTheAnimation() {
        #expect(Motion.animation(.easeOut(duration: 0.5), reduceMotion: true) == nil)
    }

    @Test func normalMotionKeepsTheAnimation() {
        #expect(Motion.animation(.easeOut(duration: 0.5), reduceMotion: false) != nil)
    }
}
