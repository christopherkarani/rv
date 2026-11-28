import Foundation
import RVDomain

// MARK: - Unlock-review wire (K2, Approvals with Touch ID)
//
// The menu bar's answer to a stop that handed the agent an allow-once code
// (`rv allow-once a7c835`). It rides the operator-UI channel on its own
// request key and vocabulary, beside launch, action and hook review, and
// shares their one authenticated UI session. Same rules as the hook-review
// wire: descriptive DTOs only, the UI retains the bound challenge verbatim
// and echoes its exact ids, and rvd re-validates every decisive call
// against the challenge it retained, the authenticated operator-UI peer,
// the bound UI connection, the code it issued, and expiry. Decoded data
// alone is never authority.
//
// Two answers exist and both need a fresh device-owner authentication:
// allow this exact command once, or always allow this exact command (one
// exact-command allowlist entry, as `rv allowlist add-command` writes it).
// Nothing here loosens a rule or a pack: that is a proposal, and proposals
// get their own request key and vocabulary (TODO(F2): `rv.ui-proposal-request`
// once the F2 "loosen is a proposal" approve path lands; do not add a
// loosen case to `UIUnlockDecision`).

/// Narrow UI service API for unlock reviews. No generic mutation endpoint,
/// and no deny: declining leaves the command stopped, so the UI only
/// releases its review.
public enum UIUnlockBridgeRequest: Sendable, Equatable {
    case unlockList
    case unlockBind(codeHash: String)
    case unlockComplete(UIUnlockCompletion)
    case unlockRelease(codeHash: String)
}

extension UIUnlockBridgeRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case unlockList
        case unlockBind
        case unlockComplete
        case unlockRelease
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .unlockList:
            try container.encode(EmptyPayload(), forKey: .unlockList)
        case .unlockBind(let codeHash):
            try container.encode(codeHash, forKey: .unlockBind)
        case .unlockComplete(let completion):
            try container.encode(completion, forKey: .unlockComplete)
        case .unlockRelease(let codeHash):
            try container.encode(codeHash, forKey: .unlockRelease)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Exactly one key: a frame naming two requests is malformed, never
        // "whichever decodes first".
        guard container.allKeys.count == 1 else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "one UIUnlockBridgeRequest per frame"))
        }
        if container.contains(.unlockList) {
            self = .unlockList
        } else if let codeHash = try container.decodeIfPresent(String.self, forKey: .unlockBind) {
            self = .unlockBind(codeHash: codeHash)
        } else if let completion = try container.decodeIfPresent(UIUnlockCompletion.self, forKey: .unlockComplete) {
            self = .unlockComplete(completion)
        } else if let codeHash = try container.decodeIfPresent(String.self, forKey: .unlockRelease) {
            self = .unlockRelease(codeHash: codeHash)
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unknown UIUnlockBridgeRequest"))
        }
    }
}

/// What the person chose on the sheet. Closed: an unknown string fails
/// decode, so an old rvd never reads a new answer as one it knows.
public enum UIUnlockDecision: String, Sendable, Equatable, Codable, CaseIterable {
    /// This exact command, in this folder, once: the grant `rv allow-once`
    /// plants.
    case allowOnce
    /// This exact command, from now on: one exact-command allowlist entry
    /// (the one `rv allowlist add-command` writes), plus the once grant so
    /// the waiting retry goes through.
    case alwaysAllow
}

/// One answer. The UI reports its fresh device-owner-authentication outcome;
/// descriptive only until rvd validates peer, connection, challenge, the
/// code it issued, and liveness.
public struct UIUnlockCompletion: Sendable, Equatable, Codable {
    public let challengeID: UUID
    public let codeHash: String
    public let decision: UIUnlockDecision
    public let outcome: UIAuthenticationOutcome

    public init(challengeID: UUID, codeHash: String, decision: UIUnlockDecision, outcome: UIAuthenticationOutcome) {
        self.challengeID = challengeID
        self.codeHash = codeHash
        self.decision = decision
        self.outcome = outcome
    }
}

/// Where one unlock ask stands. Raw values are the wire strings; unknown
/// strings fail decode. `unknown` means rvd has no live code by that hash
/// (never issued, expired, already answered, or rvd restarted).
public enum UIUnlockStatus: String, Sendable, Equatable, Codable, CaseIterable {
    case waiting
    case awaitingAuthentication
    case allowedOnce
    case alwaysAllowed
    /// Planted by another answer first (the terminal's `rv allow-once`, or
    /// another window): nothing new was granted.
    case alreadyAnswered
    case unknown
}

/// One stop waiting for the person, projected for trusted display. Every
/// field comes from what rvd kept when it issued the code, never from the
/// same-user pending file.
public struct UIUnlockItemDTO: Sendable, Equatable, Codable {
    /// sha256 hex of the code: the id the UI echoes back.
    public let codeHash: String
    /// The code the stop printed (`a7c835`). Not a secret: the agent has it.
    public let code: String
    /// `CheckWords.words(for:)` of the code, as `rv wait` prints them.
    public let checkWords: [String]
    /// The agent that was stopped. Nil only if rvd did not record one.
    public let host: HookHost?
    /// The exact command the hook stopped, every character shown
    /// (`DisplayedText.approvalField`: invisible and control characters as
    /// visible escapes). Never shortened.
    public let command: String
    public let workingDirectory: String
    public let rule: String?
    /// The agent's own description of the command, when its host sent one.
    /// The agent wrote it: the UI must label it as the agent's words.
    public let agentSays: String?
    /// rvd's own owner-prompt text for this code, the words the terminal's
    /// `rv allow-once` approves (`AllowOncePromptText`). Nil when the
    /// command is too long to show there: then nothing can be approved
    /// here either.
    public let promptText: String?
    public let status: UIUnlockStatus
    public let advisoryExpiresWall: Date

    /// Approvable only when rvd could show the whole command in its prompt,
    /// as the terminal requires.
    public var approvable: Bool { promptText != nil }

    public init(
        codeHash: String, code: String, checkWords: [String], host: HookHost?, command: String,
        workingDirectory: String, rule: String?, agentSays: String?, promptText: String?,
        status: UIUnlockStatus, advisoryExpiresWall: Date
    ) {
        self.codeHash = codeHash
        self.code = code
        self.checkWords = checkWords
        self.host = host
        self.command = command
        self.workingDirectory = workingDirectory
        self.rule = rule
        self.agentSays = agentSays
        self.promptText = promptText
        self.status = status
        self.advisoryExpiresWall = advisoryExpiresWall
    }
}

public struct UIUnlockListDTO: Sendable, Equatable, Codable {
    public let items: [UIUnlockItemDTO]

    public init(items: [UIUnlockItemDTO]) {
        self.items = items
    }
}

/// rvd-issued unlock-review challenge, retained verbatim by the UI from
/// bind through completion. Advisory timing only; rvd's state decides.
public struct UIUnlockChallengeDTO: Sendable, Equatable, Codable {
    public let challengeID: UUID
    public let codeHash: String
    public let uiConnectionID: UUID
    public let issuedWall: Date
    public let advisoryLifetimeSeconds: Double

    public init(
        challengeID: UUID, codeHash: String, uiConnectionID: UUID, issuedWall: Date,
        advisoryLifetimeSeconds: Double
    ) {
        self.challengeID = challengeID
        self.codeHash = codeHash
        self.uiConnectionID = uiConnectionID
        self.issuedWall = issuedWall
        self.advisoryLifetimeSeconds = advisoryLifetimeSeconds
    }
}

public struct UIUnlockChallengeBundleDTO: Sendable, Equatable, Codable {
    public let challenge: UIUnlockChallengeDTO
    public let item: UIUnlockItemDTO

    public init(challenge: UIUnlockChallengeDTO, item: UIUnlockItemDTO) {
        self.challenge = challenge
        self.item = item
    }
}

/// Safe status projection. Never grant contents, never authority.
public struct UIUnlockStatusDTO: Sendable, Equatable, Codable {
    public let codeHash: String
    public let status: UIUnlockStatus

    public init(codeHash: String, status: UIUnlockStatus) {
        self.codeHash = codeHash
        self.status = status
    }
}
