import Foundation
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif

/// Service-owned authentication. No client-provided success flags are accepted.
protocol OwnerAuthenticating: Sendable {
    func authenticate(reason: String) async -> Bool
}

struct LocalOwnerAuthenticator: OwnerAuthenticating {
    func authenticate(reason: String) async -> Bool {
        #if canImport(LocalAuthentication)
        let context = LAContext()
        context.touchIDAuthenticationAllowableReuseDuration = 0
        defer { context.invalidate() }
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            return false
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
        #else
        return false
        #endif
    }
}
