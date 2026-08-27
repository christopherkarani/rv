import Foundation
import RVDomain
import RVIPC

public enum PendingApprovalsBinding: Sendable {
    case automatic
    case coordinator(any PendingApprovalCoordinating)
    case missing
}

enum PendingListProjection {
    static let missingFolder = "."
    static let coordinatorUnavailable = IPCError.engine("pending coordinator unavailable")

    static func items(from records: [PendingApproval]) -> [PendingListItem] {
        let ordered = records.sorted { lhs, rhs in
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.rawValue < rhs.id.rawValue
        }
        return applyingSessionSuffix(ordered.compactMap(item(from:)))
    }

    static func fingerprint(_ records: [PendingApproval]) -> [String] {
        records.map(\.id.rawValue).sorted()
    }

    static func ipcError(from error: PendingApprovalError) -> IPCError {
        switch error {
        case .notFound:
            return .pendingNotFound
        case .alreadyResolved, .expired, .canceled, .timedOut, .alreadyConsumed:
            return .pendingAlreadyTerminal
        case .identityMismatch:
            return .pendingIdentityMismatch
        case .fingerprintMismatch:
            return .pendingFingerprintMismatch
        case .invalidRequest, .duplicateID, .continuationMismatch, .notResolved, .encodeFailed,
            .lockFailed:
            return coordinatorUnavailable
        }
    }

    static func ipcError(from error: Error) -> IPCError {
        if let error = error as? IPCError {
            return error
        }
        if let error = error as? PendingApprovalError {
            return ipcError(from: error)
        }
        return coordinatorUnavailable
    }

    private static func item(from record: PendingApproval) -> PendingListItem? {
        guard let host = HookHost(rawValue: record.identity.agent.rawValue) else {
            return nil
        }
        return PendingListItem(
            id: record.id,
            host: host,
            folder: folder(of: record.action),
            actionKind: actionKind(of: record.action),
            identity: record.identity
        )
    }

    private static func folder(of action: ProposedAction) -> String {
        guard let directory = action.scope.workingDirectory else {
            return missingFolder
        }
        let last = URL(fileURLWithPath: directory.rawValue).lastPathComponent
        return last.isEmpty ? missingFolder : last
    }

    private static func actionKind(of action: ProposedAction) -> String {
        let labels = action.effects.kinds.map { kind -> String in
            switch kind {
            case .remoteSharedBranchMutation:
                return "shared branch mutation"
            case .localBranchCreate:
                return "create local branch"
            case .workingTreeDiscard:
                return "discard working tree"
            }
        }
        let base = labels.isEmpty ? "shell" : labels.joined(separator: ", ")
        switch (action.resources.remoteName, action.resources.branchName) {
        case let (remote?, branch?) where remote.isEmpty == false && branch.isEmpty == false:
            return "\(base) on \(remote)/\(branch)"
        case let (_, branch?) where branch.isEmpty == false:
            return "\(base) on \(branch)"
        case let (remote?, _) where remote.isEmpty == false:
            return "\(base) on \(remote)"
        default:
            return base
        }
    }

    private struct AskLine: Hashable {
        var host: HookHost
        var folder: String
        var actionKind: String
    }

    private static func applyingSessionSuffix(_ items: [PendingListItem]) -> [PendingListItem] {
        var counts: [AskLine: Int] = [:]
        for item in items {
            counts[AskLine(host: item.host, folder: item.folder, actionKind: item.actionKind), default: 0] += 1
        }
        return items.map { item in
            let key = AskLine(host: item.host, folder: item.folder, actionKind: item.actionKind)
            guard counts[key, default: 0] > 1 else {
                return item
            }
            var next = item
            next.sessionSuffix = sessionSuffix(item.identity.session)
            return next
        }
    }

    private static func sessionSuffix(_ session: SessionIdentity) -> String? {
        let raw = session.rawValue
        if raw.isEmpty {
            return nil
        }
        if raw.count <= 4 {
            return raw
        }
        return String(raw.suffix(4))
    }
}
