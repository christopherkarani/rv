import Foundation
import RVIPC

enum DenyStrategy: Sendable {
    /// Cancel by operation ID; never binds (launch).
    case cancelByID
    /// Deny the exact bound challenge, binding first when needed.
    case denyBoundChallenge
}

/// Everything that differs between launch, action and hook review. The three
/// conformances are caseless enums: pure type-level policy, no state.
protocol ReviewMode {
    associatedtype ID: Hashable & Sendable
    associatedtype Item: Equatable & Sendable
    associatedtype Bundle: Equatable & Sendable
    associatedtype Status: Equatable & Sendable
    static func id(of item: Item) -> ID
    static func id(of bundle: Bundle) -> ID
    static func challengeID(of bundle: Bundle) -> UUID
    static func isTerminal(_ status: Status) -> Bool
    static var denyStrategy: DenyStrategy { get }
    static var authenticationReason: String { get }
    static var tracksArrivals: Bool { get }
    /// Pre-prompt gate: non-nil blocks authentication and shows the text.
    static func unavailableNotice(_ bundle: Bundle) -> String?
    /// Non-nil keeps the review bound and shows the text instead of
    /// completing; nil completes with the outcome as-is.
    static func notAuthenticatedNotice(_ outcome: UIAuthenticationOutcome) -> String?
}

extension ReviewMode {
    static var tracksArrivals: Bool { false }
    static func unavailableNotice(_: Bundle) -> String? { nil }
    static func notAuthenticatedNotice(_: UIAuthenticationOutcome) -> String? { nil }
}

/// Pure review state machine. SEC-001: the only bundle that can be
/// authenticated, completed or denied is the one whose ID equals the displayed
/// selection (`bound == nil || id(bound) == selectedID`). The model runs the
/// commands this returns and feeds replies back as events.
struct ReviewSession<Mode: ReviewMode>: Equatable, Sendable {
    typealias ID = Mode.ID

    enum Selection: Equatable, Sendable {
        case none
        case binding(ID)
        case unbound(ID)
        case bound(Mode.Bundle)
        case authorizing(Mode.Bundle)
        case bindingToDeny(ID)
        case denying(ID, Mode.Bundle?)
    }

    enum Event: Sendable {
        case connectRequested
        case connectReplied(ReviewFailure?)
        case refreshRequested
        case maintainTick
        case listReplied(gen: Int, Result<[Mode.Item], ReviewFailure>)
        case selectTapped(ID?)
        case bindReplied(ID, ticket: Int, Result<Mode.Bundle, ReviewFailure>)
        case allowTapped
        case authenticated(challenge: UUID, UIAuthenticationOutcome)
        case completeReplied(challenge: UUID, Result<Mode.Status, ReviewFailure>)
        case denyTapped
        case denyReplied(ID, Result<Mode.Status, ReviewFailure>)
        case dismissNotice
    }

    enum Command: Equatable, Sendable {
        case connect
        case list(gen: Int)
        case bind(ID, ticket: Int)
        case authenticate(Mode.Bundle)
        case complete(Mode.Bundle, UIAuthenticationOutcome)
        case deny(Mode.Bundle)
        case cancel(ID)
    }

    private(set) var connection: ReviewConnection = .disconnected
    private(set) var items: [Mode.Item] = []
    private(set) var selection: Selection = .none
    private(set) var lastStatus: Mode.Status?
    private(set) var notice: String?
    private(set) var arrivals = ArrivalLedger<ID>()
    private var listTicket = 0
    private var appliedList = 0
    private var bindTicket = 0
    private var baselinePending = false

    init() {}

    // MARK: Projections

    var selectedID: ID? {
        switch selection {
        case .none: nil
        case .binding(let id), .unbound(let id), .bindingToDeny(let id), .denying(let id, _): id
        case .bound(let bundle), .authorizing(let bundle): Mode.id(of: bundle)
        }
    }

    var bound: Mode.Bundle? {
        switch selection {
        case .bound(let bundle), .authorizing(let bundle), .denying(_, let bundle?): bundle
        case .none, .binding, .unbound, .bindingToDeny, .denying(_, nil): nil
        }
    }

    var isAuthorizing: Bool {
        if case .authorizing = selection { return true }
        return false
    }

    /// SEC-001.
    var selectionInvariantHolds: Bool {
        guard let bound else { return true }
        return Mode.id(of: bound) == selectedID
    }

    private var isBusy: Bool {
        switch selection {
        case .authorizing, .denying: true
        default: false
        }
    }

    // MARK: Reducer

    mutating func reduce(_ event: Event) -> [Command] {
        switch event {
        case .connectRequested:
            guard connection != .connecting, connection != .connected else { return [] }
            connection = .connecting
            notice = nil
            return [.connect]

        case .connectReplied(let failure):
            if let failure {
                connection = .failed(failure.message)
                return []
            }
            connection = .connected
            baselinePending = true
            return [nextList()]

        case .refreshRequested:
            guard connection == .connected else { return [] }
            return [nextList()]

        case .maintainTick:
            return connection == .connected ? reduce(.refreshRequested) : reduce(.connectRequested)

        case .listReplied(let gen, let result):
            guard gen > appliedList else { return [] }
            appliedList = gen
            applyList(result)
            return []

        case .selectTapped(let id):
            return select(id)

        case .bindReplied(let id, let ticket, let result):
            return applyBind(id, ticket: ticket, result)

        case .allowTapped:
            guard case .bound(let bundle) = selection else { return [] }
            if let unavailable = Mode.unavailableNotice(bundle) {
                notice = unavailable
                return []
            }
            selection = .authorizing(bundle)
            return [.authenticate(bundle)]

        case .authenticated(let challenge, let outcome):
            guard case .authorizing(let bundle) = selection,
                Mode.challengeID(of: bundle) == challenge
            else { return [] }
            if let text = Mode.notAuthenticatedNotice(outcome) {
                notice = text
                selection = .bound(bundle)
                return []
            }
            return [.complete(bundle, outcome)]

        case .completeReplied(let challenge, let result):
            guard case .authorizing(let bundle) = selection,
                Mode.challengeID(of: bundle) == challenge
            else { return [] }
            switch result {
            case .success(let status):
                lastStatus = status
                selection = Mode.isTerminal(status) ? .none : .bound(bundle)
                return connection == .connected ? [nextList()] : []
            case .failure(let failure):
                notice = failure.message
                selection = .bound(bundle)
                return []
            }

        case .denyTapped:
            return deny()

        case .denyReplied(let id, let result):
            guard case .denying(let denyingID, let bundle) = selection, denyingID == id
            else { return [] }
            switch result {
            case .success(let status):
                lastStatus = status
                selection = .none
                return connection == .connected ? [nextList()] : []
            case .failure(let failure):
                notice = failure.message
                selection = bundle.map(Selection.bound) ?? .unbound(id)
                return []
            }

        case .dismissNotice:
            notice = nil
            return []
        }
    }

    // MARK: Transitions

    private mutating func nextList() -> Command {
        listTicket += 1
        return .list(gen: listTicket)
    }

    private mutating func nextBind(_ id: ID) -> Command {
        bindTicket += 1
        return .bind(id, ticket: bindTicket)
    }

    private mutating func select(_ id: ID?) -> [Command] {
        switch selection {
        case .authorizing, .denying, .bindingToDeny: return []
        default: break
        }
        guard id != selectedID else { return [] }
        selection = .none
        guard let id, connection == .connected else { return [] }
        arrivals.open(id)
        selection = .binding(id)
        return [nextBind(id)]
    }

    private mutating func deny() -> [Command] {
        switch selection {
        case .none, .authorizing, .denying, .bindingToDeny:
            return []
        case .bound(let bundle):
            let id = Mode.id(of: bundle)
            switch Mode.denyStrategy {
            case .cancelByID:
                selection = .denying(id, bundle)
                return [.cancel(id)]
            case .denyBoundChallenge:
                selection = .denying(id, bundle)
                return [.deny(bundle)]
            }
        case .binding(let id), .unbound(let id):
            switch Mode.denyStrategy {
            case .cancelByID:
                selection = .denying(id, nil)
                return [.cancel(id)]
            case .denyBoundChallenge:
                selection = .bindingToDeny(id)
                return [nextBind(id)]
            }
        }
    }

    private mutating func applyBind(
        _ id: ID, ticket: Int, _ result: Result<Mode.Bundle, ReviewFailure>
    ) -> [Command] {
        guard ticket == bindTicket else { return [] }
        let resolved: Result<Mode.Bundle, ReviewFailure> = switch result {
        case .success(let bundle) where Mode.id(of: bundle) != id: .failure(.generic)
        default: result
        }
        switch selection {
        case .binding(id):
            switch resolved {
            case .success(let bundle):
                selection = .bound(bundle)
                notice = nil
            case .failure(let failure):
                selection = .unbound(id)
                notice = failure.message
            }
            return []
        case .bindingToDeny(id):
            switch resolved {
            case .success(let bundle):
                selection = .denying(id, bundle)
                return [.deny(bundle)]
            case .failure(let failure):
                selection = .unbound(id)
                notice = failure.message
                return []
            }
        case .denying(id, nil):
            // Launch cancel-by-ID tapped while the select bind was pending:
            // keep its bundle so a failed cancel returns to `.bound`.
            if case .success(let bundle) = resolved { selection = .denying(id, bundle) }
            return []
        default:
            return []
        }
    }

    private mutating func applyList(_ result: Result<[Mode.Item], ReviewFailure>) {
        switch result {
        case .success(let listed):
            items = listed
            if Mode.tracksArrivals { arrivals.observe(listed.map(Mode.id(of:))) }
            pruneSelection()
            notice = nil
        case .failure(let failure):
            notice = failure.message
        }
        if baselinePending {
            baselinePending = false
            if Mode.tracksArrivals { arrivals.baseline(items.map(Mode.id(of:))) }
        }
    }

    /// Drops a selection whose review vanished server-side. Busy states keep
    /// theirs: the in-flight call addresses a bundle the user already chose.
    private mutating func pruneSelection() {
        guard !isBusy, let id = selectedID else { return }
        if !items.contains(where: { Mode.id(of: $0) == id }) { selection = .none }
    }
}
