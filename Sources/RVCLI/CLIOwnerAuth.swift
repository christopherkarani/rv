import Foundation
import RVIPC

#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// Device-owner authentication failed or was unavailable.
enum AllowOnceAuthError: Error, Equatable {
    case required
    /// M5: the LA-prompt budget is exhausted (too many authentication
    /// prompts in the sliding window). Fail closed without prompting.
    case throttled
}

/// LA tripwire for `rv allow-once` mint/redeem. Step 8B P5c.
///
/// The TTY gate alone cannot stop a same-user coding agent with pty
/// access from redeeming a code it scraped from hook-deny output, so the
/// CLI requires one fresh device-owner authentication before minting or
/// redeeming. This never auto-prompts on agent ASK: it runs only inside an
/// explicit human `rv allow-once` invocation, after the TTY/robot/format
/// gates pass (typos and pipes never prompt).
///
/// Production (no `CLIProcess` context) always runs live
/// LocalAuthentication. A seamed test context authenticates only with an
/// explicit `.authenticated` override; any other outcome — or none —
/// fails closed, and tests never reach the live prompt.
enum CLIOwnerAuth {
    static let reason = "Authenticate to allow this command once."

    /// The device owner approved this action.
    ///
    /// macOS: runs LocalAuthentication. Linux: the owner's login password,
    /// verified by rvd (`OwnerConfirmation`), never just read and trusted
    /// here: a password this process merely reads proves nothing.
    static func requireAuthenticated(reason: String = reason) async throws {
        if let context = CLIProcess.context {
            guard context.ownerAuthOutcome == .authenticated else {
                throw AllowOnceAuthError.required
            }
            return
        }
        #if canImport(LocalAuthentication)
        guard await liveOutcome(reason: reason) == .authenticated else {
            throw AllowOnceAuthError.required
        }
        #else
        do {
            try await OwnerConfirmation.require(reason)
        } catch {
            FileHandle.standardError.write(Data("\(error)\n".utf8))
            throw AllowOnceAuthError.required
        }
        #endif
    }

    /// Owner proof for allow-once redeem, which carries it to rvd inside
    /// `attestTTYRedemption`. macOS: runs LocalAuthentication and returns nil
    /// (rvd trusts the pinned `.cli`). Linux: reads the login password from
    /// the terminal and returns it unverified; rvd verifies it before it
    /// plants anything, so callers must forward it, never act on it.
    static func ownerProofForAttestation(reason: String = reason) async throws -> OwnerProof? {
        if let context = CLIProcess.context {
            guard context.ownerAuthOutcome == .authenticated else {
                throw AllowOnceAuthError.required
            }
            return nil
        }
        #if canImport(LocalAuthentication)
        guard await liveOutcome(reason: reason) == .authenticated else {
            throw AllowOnceAuthError.required
        }
        return nil
        #else
        guard let password = OwnerConfirmation.readOwnerPassword(
            prompt: "\(reason)\nPassword for \(UserName.current ?? "your account"): ")
        else {
            throw AllowOnceAuthError.required
        }
        return OwnerProof(password: password)
        #endif
    }

    private static func liveOutcome(reason: String) async -> UIAuthenticationOutcome {
        #if canImport(LocalAuthentication)
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return .unavailable
        }
        do {
            try await context.evaluatePolicy(
                .deviceOwnerAuthentication, localizedReason: reason)
            return .authenticated
        } catch let error as LAError {
            switch error.code {
            case .userCancel, .userFallback, .appCancel:
                return .cancelled
            case .systemCancel:
                return .invalidated
            case .biometryNotAvailable, .biometryNotEnrolled, .passcodeNotSet,
                .biometryLockout, .touchIDLockout, .notInteractive, .invalidContext:
                return .unavailable
            // Deprecated Touch ID aliases, Apple Watch/companion and accessory
            // biometry: no usable owner proof on this Mac.
            case .touchIDNotAvailable, .touchIDNotEnrolled, .watchNotAvailable,
                .biometryNotPaired, .biometryDisconnected:
                return .unavailable
            case .authenticationFailed, .invalidDimensions:
                return .failed
            @unknown default:
                // Fail closed: an unrecognized code is never treated as success.
                return .failed
            }
        } catch {
            return .failed
        }
        #else
        // No device-owner authentication on this platform: fail closed.
        // Piping a scraped code through redeem must not become authority.
        return .unavailable
        #endif
    }
}

extension CLIOwnerAuth {
    /// The live LocalAuthentication outcome, which needs no rvd. Used by
    /// `DaemonDownOwnerConfirmation` when rvd is down. `.unavailable` off macOS.
    static func localDeviceOwnerOutcome(reason: String) async -> UIAuthenticationOutcome {
        await liveOutcome(reason: reason)
    }
}
