#if canImport(SwiftUI) && canImport(AppKit) && canImport(UserNotifications)
import Foundation
import RVGlance
import Synchronization
import UserNotifications

/// Hands the etiquette's notices to UserNotifications. A banner can't
/// answer anything: most carry no actions, and the one about a single
/// unlockable stop (K2) carries "Allow once…", which only opens the
/// approval sheet and starts Touch ID (`UnlockNoticeAction.route`).
public struct UserNotificationSink: GlanceNoticeSink {
    private static let authorized = Mutex<Bool?>(nil)

    public init() {}

    /// UNUserNotificationCenter traps outside an app bundle (a bare SwiftPM
    /// executable has no bundle identity), so notices are dropped there.
    public static var canNotify: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    public func deliver(_ actions: [GlanceNoticeAction]) async {
        guard Self.canNotify else { return }
        let center = UNUserNotificationCenter.current()
        for action in actions {
            switch action {
            case .post(let notice):
                guard await Self.authorize(center) else { continue }
                let request = UNNotificationRequest(identifier: notice.id, content: Self.content(for: notice), trigger: nil)
                try? await center.add(request)
            case .remove(let ids):
                center.removeDeliveredNotifications(withIdentifiers: ids)
                center.removePendingNotificationRequests(withIdentifiers: ids)
            }
        }
    }

    /// Asks once per launch; the system remembers the answer.
    private static func authorize(_ center: UNUserNotificationCenter) async -> Bool {
        if let known = authorized.withLock({ $0 }) { return known }
        center.setNotificationCategories([unlockCategory])
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        authorized.withLock { $0 = granted }
        return granted
    }

    /// "Allow once…" brings the app forward (the sheet and the Touch ID
    /// prompt need it) and only on an unlocked Mac.
    static var unlockCategory: UNNotificationCategory {
        UNNotificationCategory(
            identifier: UnlockNoticeAction.category,
            actions: [UNNotificationAction(
                identifier: UnlockNoticeAction.allowOnce, title: UnlockNoticeAction.allowOnceTitle,
                options: [.foreground, .authenticationRequired])],
            intentIdentifiers: [], options: [])
    }

    static func content(for notice: GlanceNotice) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.body
        content.threadIdentifier = notice.thread
        if let codeHash = notice.unlockCodeHash {
            content.categoryIdentifier = UnlockNoticeAction.category
            content.userInfo = [UnlockNoticeAction.codeHashKey: codeHash]
        }
        switch notice.level {
        case .passive:
            content.interruptionLevel = .passive
            content.relevanceScore = 0.2
        case .active:
            content.interruptionLevel = .active
            content.relevanceScore = 0.5
            content.sound = .default
        case .timeSensitive:
            // Needs the time-sensitive entitlement in the signed app; without
            // it the system delivers the notice as active.
            content.interruptionLevel = .timeSensitive
            content.relevanceScore = 1
            content.sound = .default
        }
        return content
    }
}
#endif
