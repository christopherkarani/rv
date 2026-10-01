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
    @State private var model = OperatorReviewModel(bridge: OperatorReviewModel.makeBridge())

    var body: some Scene {
        WindowGroup("RV Operator Review") {
            OperatorReviewView(model: model)
        }
        .windowResizability(.contentSize)
    }
}

extension OperatorReviewModel {
    @MainActor
    static func makeBridge() -> any OperatorUIBridge {
        #if canImport(XPC)
        XPCOperatorUIClient()
        #else
        UnavailableBridge()
        #endif
    }
}

#if !canImport(XPC)
/// Non-XPC platforms: the UI cannot reach rvd. Present, never crash.
struct UnavailableBridge: OperatorUIBridge {
    func connect() async throws { throw BridgeUnavailable() }
    func list() async throws -> UIReviewListDTO { throw BridgeUnavailable() }
    func bind(operationID _: UUID) async throws -> UIChallengeBundleDTO { throw BridgeUnavailable() }
    func complete(_: UIOperatorCompletion) async throws -> UIOperationStatusDTO { throw BridgeUnavailable() }
    func cancel(operationID _: UUID) async throws -> UIOperationStatusDTO { throw BridgeUnavailable() }
    func status(operationID _: UUID) async throws -> UIOperationStatusDTO { throw BridgeUnavailable() }
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
