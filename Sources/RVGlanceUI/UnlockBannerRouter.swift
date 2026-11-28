#if canImport(SwiftUI) && canImport(AppKit) && canImport(UserNotifications)
import AppKit
import RVGlance
import SwiftUI
import UserNotifications

/// Routes a tap on an unlock banner (K2). "Allow once…" opens the sheet in
/// a panel and starts Touch ID for that one code; a plain tap opens the
/// sheet; a dismissal does nothing and the command stays stopped. If the
/// prompt cannot run from here, the sheet is already open to try again.
public final class UnlockBannerRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = UnlockBannerRouter()
    @MainActor public var unlocks: UnlockReviewModel?
    @MainActor private var panel: NSPanel?

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    ) async {
        let codeHash = response.notification.request.content.userInfo[UnlockNoticeAction.codeHashKey] as? String
        guard let route = UnlockNoticeAction.route(actionID: response.actionIdentifier, codeHash: codeHash)
        else { return }
        await MainActor.run { self.show(route) }
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    @MainActor private func show(_ route: UnlockNoticeAction.Route) {
        guard let unlocks else { return }
        let panel = panel ?? Self.makePanel(unlocks)
        self.panel = panel
        NSApplication.shared.activate()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        unlocks.open(codeHash: route.codeHash, then: route.then)
    }

    @MainActor private static func makePanel(_ unlocks: UnlockReviewModel) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
            styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        panel.title = "rv"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.contentViewController = NSHostingController(rootView: UnlockSheetView(model: unlocks))
        return panel
    }
}
#endif
