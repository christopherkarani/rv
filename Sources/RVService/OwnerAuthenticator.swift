import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// What one owner prompt came to.
enum OwnerPromptOutcome: Sendable, Equatable {
    case approved
    /// The owner cancelled, failed or let it lapse: counts toward lockout.
    case declined
    /// No answer from the owner at all: the prompt could not be shown or
    /// the system cancelled it (background session, biometry lockout).
    /// Never counts toward lockout.
    case unavailable
}

/// Service-owned authentication. No client-provided success flags are accepted.
protocol OwnerAuthenticating: Sendable {
    /// False when no prompt can be shown at all (no passcode set, no GUI
    /// session). A false here is not a decline.
    func isAvailable() -> Bool
    /// Shows the owner prompt. Cancelling the calling task dismisses it.
    func authenticate(reason: String) async -> Bool
    /// `authenticate`, telling the owner's no apart from the environment's.
    func prompt(reason: String) async -> OwnerPromptOutcome
}

extension OwnerAuthenticating {
    func isAvailable() -> Bool { true }

    func prompt(reason: String) async -> OwnerPromptOutcome {
        await authenticate(reason: reason) ? .approved : .declined
    }
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
        await prompt(reason: reason) == .approved
    }

    func prompt(reason: String) async -> OwnerPromptOutcome {
        #if canImport(LocalAuthentication)
        let held = HeldContext()
        let context = held.context
        context.touchIDAuthenticationAllowableReuseDuration = 0
        defer { context.invalidate() }
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable
        }
        // invalidate() dismisses an open prompt; evaluatePolicy then
        // answers false (appCancel), which resumes the continuation.
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, error in
                    guard success == false else { return continuation.resume(returning: .approved) }
                    let code = (error as? LAError)?.code
                    continuation.resume(returning: code.map(Self.outcome(for:)) ?? .declined)
                }
            }
        } onCancel: {
            held.context.invalidate()
        }
        #else
        return .unavailable
        #endif
    }

    #if canImport(LocalAuthentication)
    /// The owner's own no (cancel, fallback, a failed match, our timeout's
    /// cancel) is a decline. A prompt the system could not show or took
    /// away is not. Anything else stays a decline: fail closed.
    static func outcome(for code: LAError.Code) -> OwnerPromptOutcome {
        switch code {
        case .systemCancel, .notInteractive, .passcodeNotSet, .biometryNotAvailable, .biometryNotEnrolled,
             .biometryLockout, .invalidContext:
            return .unavailable
        default:
            return .declined
        }
    }
    #endif
}

#if canImport(LocalAuthentication)
/// LAContext is thread-safe for invalidate(), which the cancellation
/// handler calls from another thread.
private final class HeldContext: @unchecked Sendable {
    let context = LAContext()
}
#endif
