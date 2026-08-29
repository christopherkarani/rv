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
    case unwrapLimited
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
        if unwrapLimitedCommand(action.supportingCommand) {
            return .unwrapLimited
        }
        if secretPathHit(action.supportingCommand) {
            return .secretPath
        }
        return nil
    }

    public static func blocksAllowOverride(_ result: EvaluationResult) -> Bool {
        if case .deny(let deny) = result.decision, blocksAllowOverride(deny) {
            return true
        }
        if result.analysis.innermost == .unwrapLimited {
            return true
        }
        if result.analysis.filesystemAction?.primaryTarget?.scope == .protectedPath {
            return true
        }
        return false
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
        if deny.ruleID == ActionPolicyEngine.Builtin.unwrapLimited.ruleID {
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
            case .unwrapLimited:
                return "This action exceeded unwrap limits. Always-allow cannot override that hard stop."
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

private func unwrapLimitedCommand(_ command: ShellCommand?) -> Bool {
    guard let raw = command?.rawValue.trimmingCharacters(in: .whitespacesAndNewlines),
          raw.isEmpty == false
    else {
        return false
    }
    let tokens = raw.split(whereSeparator: \.isWhitespace).map(String.init)
    guard let headIndex = tokens.firstIndex(where: { ["bash", "sh", "zsh"].contains($0.lowercased()) })
    else {
        return false
    }
    var index = headIndex + 1
    while index < tokens.count {
        let token = tokens[index]
        if token == "-c" || token == "--command" {
            guard index + 1 < tokens.count else { return true }
            let payload = tokens[index + 1]
            if payload.hasPrefix("'") || payload.hasPrefix("\"") {
                return false
            }
            return true
        }
        if token.hasPrefix("-") {
            index += 1
            continue
        }
        return false
    }
    return false
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
    secretPathKindMatches(candidate, kind)
}

// Matching helpers now live in RVDomain/SecretPathMatching.swift — single matcher.
