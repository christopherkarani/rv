import Foundation
import RVDomain

public enum PinnedRulePolarity: String, Sendable, Equatable {
    case allow
    case block
}

public enum RuleHardStopKind: Sendable, Equatable {
    case secretPath
    case protectedPath
    case protectedSharedBranch
    case workingTreeDiscard
    case outsideRepository
    case unresolvedPath
}

public struct RulePreview: Sendable, Equatable {
    public var sentence: String
    public var draft: String
    public var allowedToSave: Bool

    public init(sentence: String, draft: String, allowedToSave: Bool) {
        self.sentence = sentence
        self.draft = draft
        self.allowedToSave = allowedToSave
    }
}

public struct RuleSaveOutcome: Sendable, Equatable {
    public var ruleID: RuleID

    public init(ruleID: RuleID) {
        self.ruleID = ruleID
    }
}

public enum RulePinError: Error, Sendable, Equatable {
    case draftMismatch
    case hardStop
    case missingMatchingView
}

public enum RulePinning: Sendable {
    public static func preview(
        record: PendingApproval,
        polarity: PinnedRulePolarity
    ) -> RulePreview {
        let stop = hardStop(in: record.action)
        let allowedToSave = !(polarity == .allow && stop != nil)
        return RulePreview(
            sentence: sentence(polarity: polarity, stop: stop, allowedToSave: allowedToSave),
            draft: draft(record: record, polarity: polarity),
            allowedToSave: allowedToSave
        )
    }

    public static func draft(
        record: PendingApproval,
        polarity: PinnedRulePolarity
    ) -> String {
        let body = DraftBody(
            fingerprint: record.fingerprint.rawValue,
            id: record.id.rawValue,
            polarity: polarity.rawValue,
            v: 1
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(body),
              let text = String(data: data, encoding: .utf8)
        else {
            return "v1.\(polarity.rawValue).\(record.id.rawValue).\(record.fingerprint.rawValue)"
        }
        return text
    }

    public static func hardStop(in action: ProposedAction) -> RuleHardStopKind? {
        let verdict = ActionPolicyEngine.evaluate(action: action)
        if case .hardDeny(let deny) = verdict.decision {
            if deny.ruleID == ActionPolicyEngine.Builtin.workingTreeDiscard.ruleID {
                return .workingTreeDiscard
            }
            if deny.ruleID == ActionPolicyEngine.Builtin.outsideRepository.ruleID {
                return .outsideRepository
            }
            if deny.ruleID == ActionPolicyEngine.Builtin.unresolvedFilesystem.ruleID {
                return .unresolvedPath
            }
            if deny.ruleID == ActionPolicyEngine.Builtin.protectedPath.ruleID {
                return .protectedPath
            }
            return .protectedSharedBranch
        }
        if secretPathHit(action.supportingCommand) {
            return .secretPath
        }
        return nil
    }

    public static func blocksAllowOverride(_ deny: Deny) -> Bool {
        if deny.ruleID.pack == .coreSecrets {
            return true
        }
        if deny.ruleID == ActionPolicyEngine.Builtin.remoteSharedBranch.ruleID {
            return true
        }
        if deny.ruleID == ActionPolicyEngine.Builtin.workingTreeDiscard.ruleID {
            return true
        }
        if deny.ruleID == ActionPolicyEngine.Builtin.outsideRepository.ruleID {
            return true
        }
        if deny.ruleID == ActionPolicyEngine.Builtin.unresolvedFilesystem.ruleID {
            return true
        }
        if deny.ruleID == ActionPolicyEngine.Builtin.protectedPath.ruleID {
            return true
        }
        return false
    }

    public static func matchingView(of action: ProposedAction) -> MatchingView? {
        guard let command = action.supportingCommand else { return nil }
        let raw = command.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.isEmpty == false else { return nil }
        return MatchingView(raw)
    }

    public static func ruleID(
        record: PendingApproval,
        polarity: PinnedRulePolarity
    ) -> RuleID {
        let packName = polarity == .allow ? "pin.allow" : "pin.block"
        let seed = matchingView(of: record.action)?.rawValue ?? record.fingerprint.rawValue
        return RuleID(pack: PackID(rawValue: packName), pattern: String(sha256Hex(seed).prefix(16)))
    }

    private static func sentence(
        polarity: PinnedRulePolarity,
        stop: RuleHardStopKind?,
        allowedToSave: Bool
    ) -> String {
        if polarity == .allow, allowedToSave == false {
            switch stop {
            case .secretPath:
                return "This action reads a secret path. Always-allow cannot override that hard stop."
            case .protectedPath:
                return "This action mutates a protected host path. Always-allow cannot override that hard stop."
            case .workingTreeDiscard:
                return "This action discards the working tree. Always-allow cannot override that hard stop."
            case .outsideRepository:
                return "This action writes outside the repository. Always-allow cannot override that hard stop."
            case .unresolvedPath:
                return "This action has an unresolved path. Always-allow cannot override that hard stop."
            case .protectedSharedBranch, nil:
                return "This action mutates a protected shared branch. Always-allow cannot override that hard stop."
            }
        }
        switch polarity {
        case .allow:
            return "Always allow this action. Future matches in this scope will not wait."
        case .block:
            return "Always block this action. This wait and future matches will be denied."
        }
    }
}

private struct DraftBody: Codable, Equatable {
    var fingerprint: String
    var id: String
    var polarity: String
    var v: Int
}

private func secretPathHit(_ command: ShellCommand?) -> Bool {
    guard let command else { return false }
    let candidates = pathCandidates(in: command.rawValue)
    guard candidates.isEmpty == false else { return false }
    for candidate in candidates {
        for rule in SecretPathCatalog.dayOne.rules {
            if secretPathMatches(candidate, rule.kind) {
                return true
            }
        }
    }
    return false
}

private func pathCandidates(in command: String) -> [String] {
    var collected: [String] = []
    for token in command.split(whereSeparator: \.isWhitespace) {
        let decoded = String(token)
        if decoded.hasPrefix("-"), decoded.contains("=") == false {
            continue
        }
        let value: String
        if let eq = decoded.firstIndex(of: "="), eq > decoded.startIndex {
            value = String(decoded[decoded.index(after: eq)...])
        } else {
            value = decoded
        }
        if value.isEmpty == false {
            collected.append(value)
        }
    }
    return collected
}

private func secretPathMatches(_ candidate: String, _ kind: SecretPathKind) -> Bool {
    switch kind {
    case .basename(let name):
        return lastPathComponent(candidate) == name
    case .envVariant:
        return lastPathComponent(candidate).hasPrefix(".env.")
    case .homeSuffix(let parts), .hostAuth(let parts):
        return matchesHomeSuffix(candidate, parts: parts)
    }
}

private func lastPathComponent(_ path: String) -> String {
    path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? path
}

private func matchesHomeSuffix(_ candidate: String, parts: [String]) -> Bool {
    let joined = parts.joined(separator: "/")
    if hasPathPrefix(candidate, prefix: "~/" + joined) { return true }
    if hasPathPrefix(candidate, prefix: "$HOME/" + joined) { return true }
    if hasPathPrefix(candidate, prefix: "${HOME}/" + joined) { return true }
    let components = candidate.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    return containsContiguous(components, parts)
}

private func hasPathPrefix(_ candidate: String, prefix: String) -> Bool {
    candidate == prefix || candidate.hasPrefix(prefix + "/")
}

private func containsContiguous(_ haystack: [String], _ needle: [String]) -> Bool {
    guard needle.isEmpty == false, haystack.count >= needle.count else { return false }
    let lastStart = haystack.count - needle.count
    var start = 0
    while start <= lastStart {
        if haystack[start..<(start + needle.count)].elementsEqual(needle) {
            return true
        }
        start += 1
    }
    return false
}
