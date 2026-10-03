import Foundation
import RVDomain

// MARK: - Operator UI bridge wire (rvd ↔ RVOperatorUI)
//
// Descriptive DTOs only. Nothing here is authority: the service re-validates
// every completion against its stored Step 3 record, the authenticated peer,
// and the bound UI connection. Decoded data alone never creates trust.

/// XPC dictionary keys for the operator-UI channel. Results ride the standard
/// `rv.ipc` IPCResponse envelope, mirroring the host bridge.
///
/// Launch review and action review ride separate request keys so the two
/// modes can never be confused at the transport layer; both share the one
/// authenticated UI session and connection.
public enum UIBridgeWire {
    public static let requestKey = "rv.ui-request"
    public static let actionRequestKey = "rv.ui-action-request"

    public static let maxBodyBytes = 1_048_576
}

/// Narrow UI service API. No generic mutation endpoint; launch authorization
/// stays specific.
public enum UIBridgeRequest: Sendable, Equatable {
    case register
    case list
    case bind(operationID: UUID)
    case complete(UIOperatorCompletion)
    case cancel(operationID: UUID)
    case status(operationID: UUID)
}

extension UIBridgeRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case register
        case list
        case bind
        case complete
        case cancel
        case status
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .register:
            try container.encode(EmptyPayload(), forKey: .register)
        case .list:
            try container.encode(EmptyPayload(), forKey: .list)
        case .bind(let operationID):
            try container.encode(operationID, forKey: .bind)
        case .complete(let completion):
            try container.encode(completion, forKey: .complete)
        case .cancel(let operationID):
            try container.encode(operationID, forKey: .cancel)
        case .status(let operationID):
            try container.encode(operationID, forKey: .status)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.register) {
            self = .register
        } else if container.contains(.list) {
            self = .list
        } else if let operationID = try container.decodeIfPresent(UUID.self, forKey: .bind) {
            self = .bind(operationID: operationID)
        } else if let completion = try container.decodeIfPresent(
            UIOperatorCompletion.self, forKey: .complete) {
            self = .complete(completion)
        } else if let operationID = try container.decodeIfPresent(UUID.self, forKey: .cancel) {
            self = .cancel(operationID: operationID)
        } else if let operationID = try container.decodeIfPresent(UUID.self, forKey: .status) {
            self = .status(operationID: operationID)
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unknown UIBridgeRequest")
            )
        }
    }
}

/// Outcome of one UI-side authentication attempt, as reported by RVOperatorUI.
/// Descriptive only: `authenticated` here authorizes nothing until the service
/// validates peer, connection, challenge, epoch, bindings, and liveness.
public struct UIOperatorCompletion: Sendable, Equatable, Codable {
    public let challengeID: UUID
    public let operationID: UUID
    public let outcome: UIAuthenticationOutcome

    public init(challengeID: UUID, operationID: UUID, outcome: UIAuthenticationOutcome) {
        self.challengeID = challengeID
        self.operationID = operationID
        self.outcome = outcome
    }
}

public enum UIAuthenticationOutcome: String, Sendable, Equatable, Codable {
    case authenticated
    case cancelled
    case unavailable
    case timedOut
    case invalidated
    case failed
}

/// Service-issued challenge projection, retained verbatim by the UI from review
/// through completion. Advisory timing only; service monotonic state decides.
public struct UIChallengeDTO: Sendable, Equatable, Codable {
    public let challengeID: UUID
    public let operationID: UUID
    public let intentDigestHex: String
    public let kind: String
    public let uiConnectionID: UUID
    public let issuedWall: Date
    public let advisoryLifetimeSeconds: Double

    public init(
        challengeID: UUID, operationID: UUID, intentDigestHex: String, kind: String,
        uiConnectionID: UUID, issuedWall: Date, advisoryLifetimeSeconds: Double
    ) {
        self.challengeID = challengeID
        self.operationID = operationID
        self.intentDigestHex = intentDigestHex
        self.kind = kind
        self.uiConnectionID = uiConnectionID
        self.issuedWall = issuedWall
        self.advisoryLifetimeSeconds = advisoryLifetimeSeconds
    }
}

/// Structured IO description for review rendering.
public enum UIIODTO: Sendable, Equatable {
    case discard
    case pseudoTerminal(rows: Int, columns: Int)
}

extension UIIODTO: Codable {
    private enum CodingKeys: String, CodingKey {
        case discard
        case pseudoTerminal
    }

    private enum PTYCodingKeys: String, CodingKey {
        case rows
        case columns
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .discard:
            try container.encode(EmptyPayload(), forKey: .discard)
        case .pseudoTerminal(let rows, let columns):
            var nested = container.nestedContainer(keyedBy: PTYCodingKeys.self, forKey: .pseudoTerminal)
            try nested.encode(rows, forKey: .rows)
            try nested.encode(columns, forKey: .columns)
        }
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.discard) {
            self = .discard
        } else if container.contains(.pseudoTerminal) {
            let nested = try container.nestedContainer(keyedBy: PTYCodingKeys.self, forKey: .pseudoTerminal)
            self = .pseudoTerminal(
                rows: try nested.decode(Int.self, forKey: .rows),
                columns: try nested.decode(Int.self, forKey: .columns))
        } else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "unknown UIIODTO")
            )
        }
    }
}

/// One reviewable pending operation, projected for trusted display.
public struct UIReviewItemDTO: Sendable, Equatable, Codable {
    public let operationID: UUID
    public let kind: String
    public let definitionID: String?
    public let definitionRevisionDigest: String?
    public let executable: String
    public let expectedContentDigest: String?
    public let workspaceSessionID: UUID
    public let workingDirectory: String
    public let arguments: [String]
    public let io: UIIODTO
    public let environmentPolicy: String
    public let intentDigestHex: String
    public let status: String
    public let advisoryExpiresWall: Date?

    public init(
        operationID: UUID, kind: String, definitionID: String?,
        definitionRevisionDigest: String?, executable: String, expectedContentDigest: String?,
        workspaceSessionID: UUID, workingDirectory: String, arguments: [String], io: UIIODTO,
        environmentPolicy: String, intentDigestHex: String, status: String,
        advisoryExpiresWall: Date?
    ) {
        self.operationID = operationID
        self.kind = kind
        self.definitionID = definitionID
        self.definitionRevisionDigest = definitionRevisionDigest
        self.executable = executable
        self.expectedContentDigest = expectedContentDigest
        self.workspaceSessionID = workspaceSessionID
        self.workingDirectory = workingDirectory
        self.arguments = arguments
        self.io = io
        self.environmentPolicy = environmentPolicy
        self.intentDigestHex = intentDigestHex
        self.status = status
        self.advisoryExpiresWall = advisoryExpiresWall
    }
}

public struct UIReviewListDTO: Sendable, Equatable, Codable {
    public let items: [UIReviewItemDTO]

    public init(items: [UIReviewItemDTO]) {
        self.items = items
    }
}

/// Bound review: the retained challenge plus the item under review.
public struct UIChallengeBundleDTO: Sendable, Equatable, Codable {
    public let challenge: UIChallengeDTO
    public let item: UIReviewItemDTO

    public init(challenge: UIChallengeDTO, item: UIReviewItemDTO) {
        self.challenge = challenge
        self.item = item
    }
}

/// Registration receipt. The UI connection UUID is a session handle, not a
/// secret: it only names the connection the server already authenticated.
public struct UIRegisteredDTO: Sendable, Equatable, Codable {
    public let uiConnection: UUID

    public init(uiConnection: UUID) {
        self.uiConnection = uiConnection
    }
}

/// Safe status projection. Never permit contents, never a reference.
public struct UIOperationStatusDTO: Sendable, Equatable, Codable {
    public let operationID: UUID
    public let status: String

    public init(operationID: UUID, status: String) {
        self.operationID = operationID
        self.status = status
    }
}

// MARK: - Host prepare wire (rvd → workspace host reverse RPC)
//
// rvd asks the authenticated registered host to prepare exactly one launch and
// return its immutable description. No redemption, no dispatch.

public enum HostPrepareWire {
    public static let prepareKey = "rv.host-prepare"
    public static let maxBodyBytes = 1_048_576
}

/// Untrusted proposal hints. The host resolves and prepares; the returned
/// description's own bindings are authoritative, never these fields.
public struct HostPrepareRequestDTO: Sendable, Equatable, Codable {
    public let requestID: UUID
    /// "named" or "custom".
    public let kind: String
    public let definitionID: String?
    public let executable: String?
    public let expectedDigest: String?
    public let arguments: [String]
    public let io: UIIODTO

    public init(
        requestID: UUID, kind: String, definitionID: String?, executable: String?,
        expectedDigest: String?, arguments: [String], io: UIIODTO
    ) {
        self.requestID = requestID
        self.kind = kind
        self.definitionID = definitionID
        self.executable = executable
        self.expectedDigest = expectedDigest
        self.arguments = arguments
        self.io = io
    }
}

/// Authenticated host-prepared description. The single source from which rvd
/// derives Step 3 pending state after self-consistency verification.
public struct HostPreparedDescriptionDTO: Sendable, Equatable, Codable {
    public let workspaceSessionID: UUID
    public let hostID: UUID
    public let generation: UUID
    public let preparedID: UUID
    public let requestID: UUID?
    /// "named" or "custom".
    public let target: String
    public let definitionID: String?
    public let revisionDigest: String?
    public let executable: String
    public let expectedDigest: String?
    public let workingDirectory: String
    public let arguments: [String]
    public let io: UIIODTO
    public let environmentPolicy: String
    public let intentDigestHex: String
    public let environmentDigestHex: String
    public let preparedAt: Date
    public let expiresAt: Date

    public init(
        workspaceSessionID: UUID, hostID: UUID, generation: UUID, preparedID: UUID,
        requestID: UUID?, target: String, definitionID: String?, revisionDigest: String?,
        executable: String, expectedDigest: String?, workingDirectory: String,
        arguments: [String], io: UIIODTO, environmentPolicy: String, intentDigestHex: String,
        environmentDigestHex: String, preparedAt: Date, expiresAt: Date
    ) {
        self.workspaceSessionID = workspaceSessionID
        self.hostID = hostID
        self.generation = generation
        self.preparedID = preparedID
        self.requestID = requestID
        self.target = target
        self.definitionID = definitionID
        self.revisionDigest = revisionDigest
        self.executable = executable
        self.expectedDigest = expectedDigest
        self.workingDirectory = workingDirectory
        self.arguments = arguments
        self.io = io
        self.environmentPolicy = environmentPolicy
        self.intentDigestHex = intentDigestHex
        self.environmentDigestHex = environmentDigestHex
        self.preparedAt = preparedAt
        self.expiresAt = expiresAt
    }
}

public struct HostPrepareResponseDTO: Sendable, Equatable, Codable {
    public let description: HostPreparedDescriptionDTO?
    /// Machine-readable refusal when description is nil (e.g. "unknownDefinition").
    public let error: String?

    public init(description: HostPreparedDescriptionDTO?, error: String? = nil) {
        self.description = description
        self.error = error
    }
}

/// Resolve + prepare + describe exactly one launch. Sync: runs on the host
/// bridge's XPC event handler. Refusals are data, never throws.
public typealias HostPrepareHandler = @Sendable (HostPrepareRequestDTO) -> HostPrepareResponseDTO
