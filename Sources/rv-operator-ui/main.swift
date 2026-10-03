#if canImport(SwiftUI)
import Foundation
import RVIPC
import SwiftUI
import RVOperatorUI
#if canImport(XPC)
import RVService
#endif

@main
struct RVOperatorUIApplication: App {
    // One shared client: launch review and action review ride the same
    // persistent action connection and registered UI session. The two
    // models hold fully separate state and vocabularies.
    @State private var sharedClient = OperatorReviewModel.makeBridge()
    @State private var launchModel: OperatorReviewModel?
    @State private var actionModel: OperatorActionReviewModel?

    var body: some Scene {
        WindowGroup("RV Operator Review") {
            TabView {
                if let launchModel {
                    OperatorReviewView(model: launchModel)
                        .tabItem { Label("Launch requests", systemImage: "app.badge") }
                }
                if let actionModel {
                    OperatorActionReviewView(model: actionModel)
                        .tabItem { Label("Action approvals", systemImage: "checkmark.shield") }
                }
            }
            .task {
                if launchModel == nil {
                    launchModel = OperatorReviewModel(bridge: sharedClient)
                }
                if actionModel == nil {
                    actionModel = OperatorActionReviewModel(bridge: sharedClient)
                }
            }
        }
        .windowResizability(.contentSize)
    }
}

extension OperatorReviewModel {
    @MainActor
    static func makeBridge() -> any OperatorUIBridge & OperatorActionUIBridge {
        #if canImport(XPC)
        XPCOperatorUIClient()
        #else
        UnavailableBridge()
        #endif
    }
}

#if !canImport(XPC)
/// Non-XPC platforms: the UI cannot reach rvd. Present, never crash.
struct UnavailableBridge: OperatorUIBridge, OperatorActionUIBridge {
    func connect() async throws { throw BridgeUnavailable() }
    func list() async throws -> UIReviewListDTO { throw BridgeUnavailable() }
    func bind(operationID _: UUID) async throws -> UIChallengeBundleDTO { throw BridgeUnavailable() }
    func complete(_: UIOperatorCompletion) async throws -> UIOperationStatusDTO { throw BridgeUnavailable() }
    func cancel(operationID _: UUID) async throws -> UIOperationStatusDTO { throw BridgeUnavailable() }
    func status(operationID _: UUID) async throws -> UIOperationStatusDTO { throw BridgeUnavailable() }
    func actionList() async throws -> UIActionReviewListDTO { throw BridgeUnavailable() }
    func actionBind(approvalID _: UUID) async throws -> UIActionChallengeBundleDTO { throw BridgeUnavailable() }
    func actionComplete(_: UIActionCompletion) async throws -> UIActionStatusDTO { throw BridgeUnavailable() }
    func actionDeny(_: UIActionDeny) async throws -> UIActionStatusDTO { throw BridgeUnavailable() }
    func actionCancel(approvalID _: UUID) async throws -> UIActionStatusDTO { throw BridgeUnavailable() }
    func actionStatus(approvalID _: UUID) async throws -> UIActionStatusDTO { throw BridgeUnavailable() }
}

struct BridgeUnavailable: Error {}
#endif
#else
import Foundation

@main
struct RVOperatorUIApplication {
    static func main() {
        fputs("rv-operator-ui requires macOS with SwiftUI\n", stderr)
        exit(1)
    }
}
#endif
