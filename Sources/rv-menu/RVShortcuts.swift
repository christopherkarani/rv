#if canImport(SwiftUI) && canImport(AppKit) && canImport(AppIntents)
import AppIntents
import RVGlanceUI

/// Siri and Spotlight phrases. Status reads; Freeze only makes rv stricter.
struct RVShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: GetRVStatusIntent(),
            phrases: ["What is \(.applicationName) doing", "\(.applicationName) status"],
            shortTitle: "rv Status",
            systemImageName: "diamond")
        AppShortcut(
            intent: FreezeAgentsIntent(),
            phrases: ["Freeze agents with \(.applicationName)", "\(.applicationName) freeze agents"],
            shortTitle: "Freeze Agents",
            systemImageName: "snowflake")
    }
}

/// Pulls RVGlanceUI's intents into this app's metadata.
struct RVMenuIntentsPackage: AppIntentsPackage {
    static var includedPackages: [any AppIntentsPackage.Type] { [RVGlanceIntentsPackage.self] }
}
#endif
