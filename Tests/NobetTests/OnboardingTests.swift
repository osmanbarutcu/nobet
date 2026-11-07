import Foundation
import Testing
@testable import Nobet

struct OnboardingTests {
    private func defaults() -> UserDefaults {
        let name = "nobet-onboarding-test-\(UUID().uuidString)"
        let store = TestDefaults.make(name)
        store.removePersistentDomain(forName: name)
        return store
    }

    @Test func showsOnFirstRun() {
        #expect(Onboarding(defaults: defaults()).isVisible)
    }

    @Test func finishHidesItAndRemembersTheChoice() {
        let store = defaults()
        let first = Onboarding(defaults: store)
        first.finish()
        #expect(!first.isVisible)
        #expect(!Onboarding(defaults: store).isVisible)
    }

    @Test func stepsAreShortAndNumbered() {
        #expect(Onboarding.steps.count == 4)
        #expect(Onboarding.steps.allSatisfy { $0.split(separator: " ").count <= 20 })
    }
}
