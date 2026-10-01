import Foundation
import RVIPC

#if canImport(LocalAuthentication)
import LocalAuthentication

/// Fresh device-owner authentication for one explicit Authorize tap. Each
/// attempt uses a new `LAContext` with `.deviceOwnerAuthentication` and zero
/// credential reuse: success proves the device owner was present for THIS
/// review, not an earlier one. The outcome is descriptive only — it
/// authorizes nothing until rvd validates peer, connection, challenge,
/// epoch, bindings, and liveness.
///
/// The `evaluate` seam exists for tests; production always uses the live
/// LocalAuthentication path.
public struct OperatorAuthenticator: Sendable {
    public var evaluate: (@Sendable (String) async -> UIAuthenticationOutcome)?

    public init(evaluate: (@Sendable (String) async -> UIAuthenticationOutcome)? = nil) {
        self.evaluate = evaluate
    }

    public func authenticate(reason: String) async -> UIAuthenticationOutcome {
        if let evaluate {
            return await evaluate(reason)
        }
        return await Self.live(reason: reason)
    }

    @MainActor
    private static func live(reason: String) async -> UIAuthenticationOutcome {
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable
        }
        do {
            try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
            return .authenticated
        } catch let error as LAError {
            return map(error)
        } catch {
            return .failed
        }
    }

    private static func map(_ error: LAError) -> UIAuthenticationOutcome {
        switch error.code {
        case .userCancel, .userFallback, .appCancel:
            return .cancelled
        case .systemCancel:
            return .invalidated
        case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet,
            .biometryLockout, .touchIDLockout, .notInteractive, .invalidContext:
            return .unavailable
        case .authenticationFailed:
            return .failed
        @unknown default:
            return .failed
        }
    }
}
#else
/// Non-Apple platforms cannot authenticate a device owner; every attempt is
/// unavailable. RVOperatorUI ships on macOS only.
public struct OperatorAuthenticator: Sendable {
    public var evaluate: (@Sendable (String) async -> UIAuthenticationOutcome)?

    public init(evaluate: (@Sendable (String) async -> UIAuthenticationOutcome)? = nil) {
        self.evaluate = evaluate
    }

    public func authenticate(reason _: String) async -> UIAuthenticationOutcome {
        if let evaluate {
            return await evaluate("unavailable")
        }
        return .unavailable
    }
}
#endif
