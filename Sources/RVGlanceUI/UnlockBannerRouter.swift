#if canImport(SwiftUI) && canImport(AppKit) && canImport(UserNotifications)
import AppKit
import RVGlance
import SwiftUI
import UserNotifications

/// Routes a tap on an unlock banner (K2). "Allow once…" and a plain tap
/// both open the sheet in a panel, showing the whole command; Touch ID
/// starts only when the person taps Allow there. A dismissal does nothing
/// and the command stays stopped. Set as the notification delegate at
/// launch, so a tap that launched the app is not lost: a route that comes
/// before the model is attached waits for it.
public final class UnlockBannerRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    public static let shared = UnlockBannerRouter()
    @MainActor private var unlocks: UnlockReviewModel?
    @MainActor private var pending: UnlockNoticeAction.Route?
    @MainActor private var panel: NSPanel?

    @MainActor public func attach(_ unlocks: UnlockReviewModel) {
        self.unlocks = unlocks
        if let pending {
            self.pending = nil
            show(pending)
        }
    }

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
        guard let unlocks else {
            pending = route
            return
        }
        let panel = panel ?? Self.makePanel(unlocks)
        self.panel = panel
        NSApplication.shared.activate()
        panel.center()
        panel.makeKeyAndOrderFront(nil)
        unlocks.open(codeHash: route.codeHash)
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
