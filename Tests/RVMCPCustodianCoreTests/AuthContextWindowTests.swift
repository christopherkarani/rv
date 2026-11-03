import Foundation
import LocalAuthentication
import Synchronization
import Testing
@testable import RVMCPCustodianCore

@Suite("Approval keychain auth window")
struct AuthContextWindowTests {
    final class Clock: Sendable {
        private let start = ContinuousClock.now
        private let offset = Mutex(Duration.zero)
        var now: ContinuousClock.Instant { start + offset.withLock { $0 } }
        func advance(_ by: Duration) { offset.withLock { $0 += by } }
    }

    @Test func contextIsReusedInsideTheWindow() {
        let clock = Clock()
        let window = AuthContextWindow(duration: .seconds(30), now: { clock.now })
        let first = window.current()
        clock.advance(.seconds(29))
        #expect(window.current() === first)
    }

    @Test func contextExpiresAtTheDeadlineAndTheOldOneIsInvalidated() {
        let clock = Clock()
        let window = AuthContextWindow(duration: .seconds(30), now: { clock.now })
        let first = window.current()
        clock.advance(.seconds(30))
        let second = window.current()
        #expect(second !== first)
        // A burst keeps reusing the replacement until its own deadline.
        clock.advance(.seconds(10))
        #expect(window.current() === second)
        clock.advance(.seconds(20))
        #expect(window.current() !== second)
    }

    @Test func idleTimeBeforeFirstUseDoesNotShortenTheWindow() {
        let clock = Clock()
        let window = AuthContextWindow(duration: .seconds(30), now: { clock.now })
        clock.advance(.seconds(600))
        let first = window.current()
        clock.advance(.seconds(29))
        #expect(window.current() === first)
    }

    @Test func resetEndsTheWindowEarly() {
        let clock = Clock()
        let window = AuthContextWindow(duration: .seconds(30), now: { clock.now })
        let first = window.current()
        window.reset()
        #expect(window.current() !== first)
    }

    @Test func eachContextCarriesTheConfiguredTouchIDReuse() {
        let window = AuthContextWindow(duration: .seconds(30))
        #expect(window.current().touchIDAuthenticationAllowableReuseDuration == 30)
    }
}
