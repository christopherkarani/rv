import Foundation
import RVDomain
import RVIPC

// K2 review state for the menu bar's unlock sheet, as a pure reducer: the
// shell runs the commands it returns (rvd calls, the Touch ID prompt) and
// feeds the replies back as events. The rules it keeps:
// - every Allow tap asks for a fresh device-owner authentication; nothing
//   is ever sent to rvd without one, and a cancelled or failed prompt
//   sends nothing (the review stays open for another try);
// - a completion echoes exactly the challenge rvd bound for the ask on the
//   sheet, and only once: rvd spends the challenge on any answer, so a
//   retry binds afresh;
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
        /// Waiting for rvd to bind the review; `then` is an answer the
        /// person already gave (from a notification's Allow once).
        case binding(codeHash: String, then: UIUnlockDecision?)
        case reviewing(UIUnlockChallengeBundleDTO)
        case authenticating(UIUnlockChallengeBundleDTO, UIUnlockDecision)
        case completing(UIUnlockChallengeBundleDTO, UIUnlockDecision)
        /// The answer is in; the sheet shows the outcome until closed.
        case answered(codeHash: String, UIUnlockStatus)
    }

    public enum Event: Sendable, Equatable {
        case refreshRequested
        case listReplied(Result<[UIUnlockItemDTO], UnlockFailure>)
        /// Open the sheet for one ask. `then` answers right after the bind
        /// (a notification's Allow once): the Touch ID prompt still runs.
        case openTapped(codeHash: String, then: UIUnlockDecision?)
        case bindReplied(codeHash: String, Result<UIUnlockChallengeBundleDTO, UnlockFailure>)
        case allowTapped(UIUnlockDecision)
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

    public private(set) var items: [UIUnlockItemDTO] = []
    public private(set) var phase: Phase = .idle
    public private(set) var notice: String?
    /// Asks the person denied: hidden until rvd stops listing them.
    public private(set) var dismissed: Set<String> = []
    /// False after rvd refused or missed the last list.
    public private(set) var reachable = true

    public init() {}

    /// The asks to show, oldest first.
    public var waiting: [UIUnlockItemDTO] {
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

    public mutating func reduce(_ event: Event) -> [Command] {
        switch event {
        case .refreshRequested:
            return [.list]

        case .listReplied(.success(let listed)):
            reachable = true
            items = listed
            dismissed.formIntersection(listed.map(\.codeHash))
            if case .reviewing(let bundle) = phase,
                !listed.contains(where: { $0.codeHash == bundle.challenge.codeHash }) {
                phase = .idle
                notice = "That stop was answered elsewhere or expired."
            }
            return []

        case .listReplied(.failure):
            // Quiet: a menu bar without the operator role (or with rvd
            // down) simply has nothing to show. The sheet says so if open.
            reachable = false
            return []

        case .openTapped(let codeHash, let then):
            guard !isBusy else { return [] }
            notice = nil
            phase = .binding(codeHash: codeHash, then: then)
            return [.bind(codeHash: codeHash)]

        case .bindReplied(let codeHash, let result):
            guard case .binding(let pending, let then) = phase, pending == codeHash else { return [] }
            switch result {
            case .success(let bundle) where bundle.challenge.codeHash == codeHash && bundle.item.codeHash == codeHash:
                phase = .reviewing(bundle)
                return then.map { reduce(.allowTapped($0)) } ?? []
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

        case .allowTapped(let decision):
            guard case .reviewing(let bundle) = phase else { return [] }
            guard bundle.item.approvable, let code = AllowOnceUnlockCode(validating: bundle.item.code) else {
                notice = UnlockSheet(bundle.item, now: bundle.challenge.issuedWall).unavailable
                return []
            }
            notice = nil
            phase = .authenticating(bundle, decision)
            return [.authenticate(
                challenge: bundle.challenge.challengeID, decision,
                reason: UnlockSheet.touchIDReason(code: code, decision: decision))]

        case .authenticated(let challenge, let decision, let outcome):
            guard case .authenticating(let bundle, let asked) = phase,
                bundle.challenge.challengeID == challenge, asked == decision
            else { return [] }
            guard outcome == .authenticated else {
                // Nothing goes to rvd: it would spend the challenge for an
                // answer the owner never gave.
                phase = .reviewing(bundle)
                notice = Self.notAuthenticated(outcome)
                return []
            }
            phase = .completing(bundle, decision)
            return [.complete(UIUnlockCompletion(
                challengeID: bundle.challenge.challengeID, codeHash: bundle.challenge.codeHash,
                decision: decision, outcome: .authenticated))]

        case .completeReplied(let challenge, let result):
            guard case .completing(let bundle, _) = phase, bundle.challenge.challengeID == challenge else { return [] }
            switch result {
            case .success(let status):
                phase = .answered(codeHash: bundle.challenge.codeHash, status)
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
        case .unavailable: "Touch ID and your password aren't available here. Use rv allow-once in a terminal."
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
                return .listReplied(.success(try await bridge.list().items))
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
