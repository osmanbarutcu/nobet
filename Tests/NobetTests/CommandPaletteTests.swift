import Foundation
import Testing
@testable import Nobet

struct CommandPaletteTests {
    @Test func emptyQueryListsEverySectionInSidebarOrder() {
        #expect(CommandPalette.matches("").map(\.section) == NobetSection.allCases)
    }

    @Test func queryIgnoresCaseAccentAndDotlessI() {
        #expect(CommandPalette.matches("GELISTIRME").map(\.section) == [.development])
        #expect(CommandPalette.matches("sirlar").map(\.section) == [.secrets])
        #expect(CommandPalette.matches("HAKKINDA").map(\.section) == [.about])
    }

    @Test func queryMatchesKeywords() {
        #expect(CommandPalette.matches("ssh").map(\.section) == [.servers])
        #expect(CommandPalette.matches("tema").map(\.section) == [.settings])
    }

    @Test func unknownQueryGivesNothing() {
        #expect(CommandPalette.matches("zzzz").isEmpty)
    }
}
