import Foundation
import Testing
@testable import Nobet

struct UpdateCheckTests {
    private func json(_ tag: String, draft: Bool = false, pre: Bool = false, url: String = "https://github.com/osmanbarutcu/nobet/releases/tag/v1") -> Data {
        Data(#"{"tag_name":"\#(tag)","draft":\#(draft),"prerelease":\#(pre),"html_url":"\#(url)"}"#.utf8)
    }

    @Test func parsesStableRelease() {
        #expect(UpdateCheck.parse(json("v0.3.0"))?.version == "0.3.0")
    }

    @Test func rejectsDraftPrereleaseBrokenAndForeignHost() {
        #expect(UpdateCheck.parse(json("v1", draft: true)) == nil)
        #expect(UpdateCheck.parse(json("v1", pre: true)) == nil)
        #expect(UpdateCheck.parse(Data("x".utf8)) == nil)
        #expect(UpdateCheck.parse(json("v1", url: "https://evil.example/x")) == nil)
        #expect(UpdateCheck.parse(json("v1", url: "http://github.com/x")) == nil)
    }

    @Test func comparesVersionsNumerically() {
        #expect(UpdateCheck.isNewer("0.10.0", than: "0.9.0"))
        #expect(UpdateCheck.isNewer("1.0", than: "0.9.9"))
        #expect(!UpdateCheck.isNewer("0.2.2", than: "0.2.2"))
        #expect(!UpdateCheck.isNewer("0.2.1", than: "0.2.2"))
        #expect(!UpdateCheck.isNewer("abc", than: "0.2.2"))
    }

    @Test func dueAfter24Hours() {
        let now = Date()
        #expect(UpdateCheck.isDue(lastCheck: nil, now: now))
        #expect(!UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-3_600), now: now))
        #expect(UpdateCheck.isDue(lastCheck: now.addingTimeInterval(-86_400), now: now))
    }

    @Test func updateNotificationRoutesToSettings() {
        #expect(NotificationRoute.section(for: UpdateCheck.notificationId) == .settings)
    }
}
