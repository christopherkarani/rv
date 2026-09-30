import Foundation
import LocalAuthentication
let context = LAContext()
var error: NSError?
let available = context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error)
print("canEvaluatePolicy=\(available) error=\(String(describing: error))")
fflush(stdout)
if available {
    context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "RV Phase 2 platform probe: authenticate this single test operation") { success, error in
        print("evaluatePolicy=\(success) error=\(String(describing: error))")
        fflush(stdout)
        exit(success ? 0 : 2)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
        context.invalidate()
        print("evaluatePolicy=timeout")
        fflush(stdout)
        exit(3)
    }
    RunLoop.main.run()
} else { exit(2) }
