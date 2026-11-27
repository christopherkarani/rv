#if canImport(SwiftUI) && canImport(AppKit) && canImport(UserNotifications)
import Foundation
import Testing
import UserNotifications
import RVGlance
@testable import RVGlanceUI

/// How a notice becomes UserNotifications content.
struct GlanceNotifierTests {
    private func notice(_ level: GlanceNoticeLevel) -> GlanceNotice {
        GlanceNotice(id: "rv.ask.claude", thread: "rv.ask.claude", title: "claude needs you", body: "1 request", level: level)
    }

    @Test func levelsMapToInterruptionLevels() {
        #expect(UserNotificationSink.content(for: notice(.timeSensitive)).interruptionLevel == .timeSensitive)
        #expect(UserNotificationSink.content(for: notice(.active)).interruptionLevel == .active)
        #expect(UserNotificationSink.content(for: notice(.passive)).interruptionLevel == .passive)
    }

    @Test func onlyAudibleLevelsPlayASound_andTheThreadGroupsPerAgent() {
        let quiet = UserNotificationSink.content(for: notice(.passive))
        #expect(quiet.sound == nil)
        #expect(UserNotificationSink.content(for: notice(.timeSensitive)).sound != nil)
        #expect(quiet.threadIdentifier == "rv.ask.claude")
        #expect(quiet.title == "claude needs you")
    }

    @Test func noticesCarryNoActions() {
        #expect(UserNotificationSink.content(for: notice(.timeSensitive)).categoryIdentifier.isEmpty)
    }

    @Test func aBareExecutableNeverTouchesTheCenter() async {
        // swift test runs outside an .app bundle: deliver must be a no-op, not a trap.
        #expect(!UserNotificationSink.canNotify)
        await UserNotificationSink().deliver([.post(notice(.timeSensitive)), .remove(["rv.ask.claude"])])
    }
}
#endif
