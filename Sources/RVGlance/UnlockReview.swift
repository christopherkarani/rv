import Foundation
import RVDomain
import RVIPC

// K2 review state for the menu bar's unlock sheet, as a pure reducer: the
// shell runs the commands it returns (rvd calls, the Touch ID prompt) and
// feeds the replies back as events. The rules it keeps:
// - Touch ID starts only from an Allow tap on the sheet, which shows the
//   whole command, and that tap names the challenge it answers: a tap
//   meant for one review can never land on another. Nothing else (a
//   banner action, a list reply, a bind reply) starts it;
// - every Allow asks for a fresh device-owner authentication, whose prompt
//   names the command in rvd's own words;
// - a completion echoes exactly the challenge rvd bound for the ask on the
//   sheet, and only once: rvd spends the challenge on any answer, so a
//   retry binds afresh. A cancelled or failed prompt is reported as such:
//   rvd grants nothing, audits it, and counts it toward the owner-check
//   lockout; the sheet then binds again so the person can retry;
// - Deny sends no answer: it closes the review and the command stays
//   stopped, its code still good in a terminal.
//
// TODO(F2): loosen proposals ("loosen is a proposal") plug in beside this
// as their own review (`ProposalReview`) on their own wire key, sharing
// `UnlockSheet`'s layout and this reducer's authenticate-then-complete
// shape. They must not become a `UIUnlockDecision` case: an unlock answers
// one exact command, a proposal changes policy.

/// What a call to rvd failed with, in words for the sheet.
public struct UnlockFailure: Error, Sendable, Equatable {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public static let refused = UnlockFailure("rv didn't accept that answer. Nothing was allowed.")
    public static let unreachable = UnlockFailure("rv isn't answering. Nothing was allowed.")
}

/// rvd's unlock-review calls, as the sheet needs them. The macOS app adapts
/// the operator-UI XPC client; tests fake it.
public protocol UnlockBridge: Sendable {
    func list() async throws -> UIUnlockListDTO
    func bind(codeHash: String) async throws -> UIUnlockChallengeBundleDTO
    func complete(_ completion: UIUnlockCompletion) async throws -> UIUnlockStatusDTO
    func release(codeHash: String) async throws -> UIUnlockStatusDTO
}

/// One device-owner authentication. The macOS app makes a fresh
/// `LAContext` for every call; tests answer with a fixed outcome.
public protocol UnlockAuthenticator: Sendable {
    func authenticate(reason: String) async -> UIAuthenticationOutcome
}

public struct UnlockReview: Sendable, Equatable {
    public enum Phase: Sendable, Equatable {
        case idle
        /// Waiting for rvd to bind the review.
        case binding(codeHash: String)
        case reviewing(UIUnlockChallengeBundleDTO)
        case authenticating(UIUnlockChallengeBundleDTO, UIUnlockDecision)
        case completing(UIUnlockChallengeBundleDTO, UIUnlockDecision)
        /// The answer is in; the sheet shows the outcome until closed.
        case answered(codeHash: String, UIUnlockStatus)
    }

    public enum Event: Sendable, Equatable {
        case refreshRequested
        case listReplied(Result<UIUnlockListDTO, UnlockFailure>)
        /// Open the sheet for one ask. Only opens it.
        case openTapped(codeHash: String)
        case bindReplied(codeHash: String, Result<UIUnlockChallengeBundleDTO, UnlockFailure>)
        /// An Allow tap on the sheet showing `challenge`.
        case allowTapped(challenge: UUID, UIUnlockDecision)
        case authenticated(challenge: UUID, UIUnlockDecision, UIAuthenticationOutcome)
        case completeReplied(challenge: UUID, Result<UIUnlockStatus, UnlockFailure>)
        case denyTapped
        case closeTapped
    }

    public enum Command: Sendable, Equatable {
        case list
        case bind(codeHash: String)
        case authenticate(challenge: UUID, UIUnlockDecision, reason: String)
        case complete(UIUnlockCompletion)
        case release(codeHash: String)
    }

    /// The list's rows: no command text.
    public private(set) var items: [UIUnlockSummaryDTO] = []
    /// How many more asks rvd had past its list cap.
    public private(set) var omitted = 0
    public private(set) var phase: Phase = .idle
    public private(set) var notice: String?
    /// Asks the person denied: hidden until rvd stops listing them.
    public private(set) var dismissed: Set<String> = []
    /// False after rvd refused or missed the last list.
    public private(set) var reachable = true
    /// Lists refused or missed in a row; the poll backs off on them.
    public private(set) var listFailures = 0

    public init() {}

    /// The asks to show, oldest first.
    public var waiting: [UIUnlockSummaryDTO] {
        items.filter { !dismissed.contains($0.codeHash) }
    }

    /// The bundle on the sheet, whatever the phase.
    public var onSheet: UIUnlockChallengeBundleDTO? {
        switch phase {
        case .reviewing(let bundle), .authenticating(let bundle, _), .completing(let bundle, _): bundle
        case .idle, .binding, .answered: nil
        }
    }

    public var isBusy: Bool {
        switch phase {
        case .binding, .authenticating, .completing: true
        case .idle, .reviewing, .answered: false
        }
    }

    /// How long to wait before the next list: 4 s while rvd answers, then
    /// doubling on each refusal or miss up to 5 minutes, so a menu bar rvd
    /// won't answer (an unpinned build, rvd down) asks rarely.
    public var pollDelay: Duration { Self.pollDelay(afterFailures: listFailures) }

    public static func pollDelay(afterFailures failures: Int) -> Duration {
        let base = 4
        let cap = 300
        guard failures > 0 else { return .seconds(base) }
        return .seconds(min(cap, base << min(failures, 7)))
    }

    public mutating func reduce(_ event: Event) -> [Command] {
        switch event {
        case .refreshRequested:
            return [.list]

        case .listReplied(.success(let listed)):
            reachable = true
            listFailures = 0
            items = listed.items
            omitted = listed.omitted
            dismissed.formIntersection(listed.items.map(\.codeHash))
            if case .reviewing(let bundle) = phase, listed.omitted == 0,
                !listed.items.contains(where: { $0.codeHash == bundle.challenge.codeHash }) {
                phase = .idle
                notice = "That stop was answered elsewhere or expired."
            }
            return []

        case .listReplied(.failure):
            // Quiet: a menu bar without the operator role (or with rvd
            // down) simply has nothing to show, and asks less often.
            reachable = false
            listFailures += 1
            return []

        case .openTapped(let codeHash):
            guard !isBusy else { return [] }
            notice = nil
            phase = .binding(codeHash: codeHash)
            return [.bind(codeHash: codeHash)]

        case .bindReplied(let codeHash, let result):
            guard case .binding(let pending) = phase, pending == codeHash else { return [] }
            switch result {
            case .success(let bundle) where bundle.challenge.codeHash == codeHash && bundle.item.codeHash == codeHash:
                // Only shows the sheet: Touch ID waits for a tap on it.
                phase = .reviewing(bundle)
                return []
            case .success:
                // rvd bound something other than the ask on the sheet.
                phase = .idle
                notice = UnlockFailure.refused.message
                return [.list]
            case .failure(let failure):
                phase = .idle
                notice = failure.message
                return [.list]
            }

        case .allowTapped(let challenge, let decision):
            guard case .reviewing(let bundle) = phase, bundle.challenge.challengeID == challenge else { return [] }
            let sheet = UnlockSheet(bundle.item, challengeID: challenge, now: bundle.challenge.issuedWall)
            guard sheet.canApprove, let reason = UnlockSheet.touchIDReason(bundle.item, decision: decision) else {
                notice = sheet.unavailable
                return []
            }
            notice = nil
            phase = .authenticating(bundle, decision)
            return [.authenticate(challenge: challenge, decision, reason: reason)]

        case .authenticated(let challenge, let decision, let outcome):
            guard case .authenticating(let bundle, let asked) = phase,
                bundle.challenge.challengeID == challenge, asked == decision
            else { return [] }
            // Every outcome goes to rvd: an authenticated one may grant,
            // any other only spends the challenge and is recorded.
            notice = Self.notAuthenticated(outcome)
            phase = .completing(bundle, decision)
            return [.complete(UIUnlockCompletion(
                challengeID: bundle.challenge.challengeID, codeHash: bundle.challenge.codeHash,
                decision: decision, outcome: outcome))]

        case .completeReplied(let challenge, let result):
            guard case .completing(let bundle, _) = phase, bundle.challenge.challengeID == challenge else { return [] }
            let codeHash = bundle.challenge.codeHash
            switch result {
            case .success(.declined), .success(.lockedOut):
                // Nothing was granted and the challenge is spent: bind a
                // fresh one so the sheet stays up for another try.
                if case .success(.lockedOut) = result { notice = UnlockSheet.lockedOutLine }
                phase = .binding(codeHash: codeHash)
                return [.bind(codeHash: codeHash), .list]
            case .success(let status):
                phase = .answered(codeHash: codeHash, status)
            case .failure(let failure):
                // rvd spent the challenge: a retry must bind again.
                phase = .idle
                notice = failure.message
            }
            return [.list]

        case .denyTapped:
            guard case .reviewing(let bundle) = phase else { return [] }
            let codeHash = bundle.challenge.codeHash
            dismissed.insert(codeHash)
            phase = .idle
            notice = nil
            return [.release(codeHash: codeHash)]

        case .closeTapped:
            switch phase {
            case .reviewing(let bundle):
                phase = .idle
                return [.release(codeHash: bundle.challenge.codeHash)]
            case .answered, .idle:
                phase = .idle
                notice = nil
                return []
            case .binding, .authenticating, .completing:
                // An answer is in flight; it finishes first.
                return []
            }
        }
    }

    static func notAuthenticated(_ outcome: UIAuthenticationOutcome) -> String? {
        switch outcome {
        case .authenticated: nil
        case .cancelled: "Touch ID was cancelled. Nothing was allowed."
        case .unavailable: "Touch ID and your password aren't available here. Use rv unlock in a terminal."
        case .timedOut: "Touch ID timed out. Nothing was allowed."
        case .invalidated: "Touch ID was interrupted. Nothing was allowed."
        case .failed: "Touch ID didn't recognise you. Nothing was allowed."
        }
    }
}

/// Runs one reducer command against the ports and returns its reply event.
/// The shell's only effect interpreter, so tests drive the same code.
public enum UnlockReviewRunner {
    public static func run(
        _ command: UnlockReview.Command,
        bridge: any UnlockBridge,
        authenticator: any UnlockAuthenticator
    ) async -> UnlockReview.Event? {
        switch command {
        case .list:
            do {
                return .listReplied(.success(try await bridge.list()))
            } catch {
                return .listReplied(.failure(.unreachable))
            }
        case .bind(let codeHash):
            do {
                return .bindReplied(codeHash: codeHash, .success(try await bridge.bind(codeHash: codeHash)))
            } catch {
                return .bindReplied(codeHash: codeHash, .failure(.refused))
            }
        case .authenticate(let challenge, let decision, let reason):
            return .authenticated(challenge: challenge, decision, await authenticator.authenticate(reason: reason))
        case .complete(let completion):
            do {
                let reply = try await bridge.complete(completion)
                guard reply.codeHash == completion.codeHash else {
                    return .completeReplied(challenge: completion.challengeID, .failure(.refused))
                }
                return .completeReplied(challenge: completion.challengeID, .success(reply.status))
            } catch {
                return .completeReplied(challenge: completion.challengeID, .failure(.refused))
            }
        case .release(let codeHash):
            _ = try? await bridge.release(codeHash: codeHash)
            return nil
        }
    }

    /// Feeds `event` in and runs every command it leads to, in order.
    public static func send(
        _ event: UnlockReview.Event,
        to review: inout UnlockReview,
        bridge: any UnlockBridge,
        authenticator: any UnlockAuthenticator
    ) async {
        var queue = review.reduce(event)
        while !queue.isEmpty {
            let command = queue.removeFirst()
            if let reply = await run(command, bridge: bridge, authenticator: authenticator) {
                queue += review.reduce(reply)
            }
        }
    }
}
