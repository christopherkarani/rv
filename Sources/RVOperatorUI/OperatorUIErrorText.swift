import Foundation

#if canImport(RVXPC)
import RVXPC
#endif

/// Connection lifecycle shared by the three review models.
public enum ReviewConnection: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

/// A bridge failure reduced to its user-visible text. Crossing this boundary
/// keeps the reducer free of `Error` existentials and XPC types.
struct ReviewFailure: Error, Equatable, Sendable {
    let message: String

    /// Text for a reply the session cannot trust (for example a bind reply
    /// whose bundle is not the requested review).
    static let generic = ReviewFailure(message: "Request failed.")

    init(message: String) {
        self.message = message
    }

    init(_ error: any Error) {
        self.message = OperatorUIErrorText.describe(error)
    }
}

enum OperatorUIErrorText {
    static func describe(_ error: any Error) -> String {
        #if canImport(XPC)
        if let error = error as? XPCOperatorUIClientError {
            switch error {
            case .denied:
                return "Denied: review is no longer valid. Refresh and rebind."
            case .authenticationFailed:
                return "Service identity check failed. Is rvd running?"
            case .connectFailed:
                return "Lost connection to rvd."
            case .protocolMismatch:
                return "Unexpected reply from rvd."
            case .cancelled:
                return "Cancelled."
            }
        }
        #endif
        return "Request failed."
    }
}
