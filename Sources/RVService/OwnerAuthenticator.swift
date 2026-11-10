import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// Service-owned authentication. No client-provided success flags are accepted.
protocol OwnerAuthenticating: Sendable {
    /// False when no prompt can be shown at all (no passcode set, no GUI
    /// session). A false here is not a decline.
    func isAvailable() -> Bool
    /// Shows the owner prompt. Cancelling the calling task dismisses it.
    func authenticate(reason: String) async -> Bool
}

extension OwnerAuthenticating {
    func isAvailable() -> Bool { true }
}

struct LocalOwnerAuthenticator: OwnerAuthenticating {
    func isAvailable() -> Bool {
        #if canImport(LocalAuthentication)
        let context = LAContext()
        defer { context.invalidate() }
        var error: NSError?
        return context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
        #else
        return false
        #endif
    }

    func authenticate(reason: String) async -> Bool {
        #if canImport(LocalAuthentication)
        let held = HeldContext()
        let context = held.context
        context.touchIDAuthenticationAllowableReuseDuration = 0
        defer { context.invalidate() }
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        // invalidate() dismisses an open prompt; evaluatePolicy then
        // answers false (appCancel), which resumes the continuation.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                    continuation.resume(returning: success)
                }
            }
        } onCancel: {
            held.context.invalidate()
        }
        #else
        return false
        #endif
    }
}

#if canImport(LocalAuthentication)
/// LAContext is thread-safe for invalidate(), which the cancellation
/// handler calls from another thread.
private final class HeldContext: @unchecked Sendable {
    let context = LAContext()
}
#endif
