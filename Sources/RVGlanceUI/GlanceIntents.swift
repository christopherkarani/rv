#if canImport(SwiftUI) && canImport(AppKit) && canImport(AppIntents)
import AppIntents
import Foundation
import RVGlance
import Synchronization

/// Where intents find rv. The app sets it once at launch; until then
/// intents say they aren't connected and can't freeze.
public enum GlanceIntentEnvironment {
    private static let store = Mutex(GlanceIntentServices.unconnected)

    public static var services: GlanceIntentServices {
        get { store.withLock { $0 } }
        set { store.withLock { $0 = newValue } }
    }
}

/// "rv Status": what rv is doing, as one sentence. Read-only.
public struct GetRVStatusIntent: AppIntent {
    public static var title: LocalizedStringResource { "rv Status" }
    public static var description: IntentDescription {
        IntentDescription("Says what rv is doing right now. Read-only: it never changes rv.")
    }
    public static var openAppWhenRun: Bool { false }

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let sentence = await GlanceIntentEnvironment.services.statusSentence(now: Date())
        return .result(value: sentence, dialog: "\(sentence)")
    }
}

// Freeze is built but not registered. rvd has no freeze verb yet (see
// UnavailableFreezeControl), so a "Freeze Agents" phrase or a Focus that
// "freezes agents" would do nothing while the user believes agents are
// stopped. App Intents registers every intent type compiled into the app,
// so the types themselves stay out of the build until rvd exposes the
// verb and the app wires a real GlanceFreezeControl; then build with
// `-D RV_FREEZE_CONTROL`.
#if RV_FREEZE_CONTROL
/// "Freeze Agents": stops every agent rv watches. Only ever stricter.
public struct FreezeAgentsIntent: AppIntent {
    public static var title: LocalizedStringResource { "Freeze Agents" }
    public static var description: IntentDescription {
        IntentDescription(
            "Freezes every agent rv watches mid-step; nothing is killed. This only ever makes rv stricter: thawing is done in rv itself.")
    }
    public static var openAppWhenRun: Bool { false }

    public init() {}

    public func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        let services = GlanceIntentEnvironment.services
        let message = await services.freezeAll(origin: .intent).dialog(calendar: services.calendar)
        return .result(value: message, dialog: "\(message)")
    }
}

/// rv's Focus filter. Starting the Focus may freeze agents; ending it
/// never thaws them.
public struct RVFocusFilter: SetFocusFilterIntent {
    public static var title: LocalizedStringResource { "rv" }
    public static var description: IntentDescription? {
        IntentDescription("Can freeze agents when this Focus starts. Ending the Focus never thaws them.")
    }

    @Parameter(title: "Freeze agents when this Focus starts", default: false)
    public var freezeAgentsOnStart: Bool

    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: freezeAgentsOnStart ? "Freeze agents on start" : "Leave agents running")
    }

    public init() {}

    /// The system calls this when the Focus starts or its settings change,
    /// and with the defaults (off) when it ends, so an end plans nothing.
    public func perform() async throws -> some IntentResult {
        let filter = GlanceFocusFilter(freezeOnStart: freezeAgentsOnStart)
        _ = await GlanceIntentEnvironment.services.focusChanged(filter, .started)
        return .result()
    }
}
#endif

/// Lets the app's metadata include these intents.
public struct RVGlanceIntentsPackage: AppIntentsPackage {}
#endif
