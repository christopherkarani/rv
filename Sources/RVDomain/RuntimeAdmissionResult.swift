import Foundation

/// Why a parked or resumed approval ended without executing. Raw values are
/// the persisted evidence spellings.
public enum RuntimeAdmissionApprovalCause: String, Sendable, Equatable, Codable, CaseIterable {
    case unavailable = "approvalUnavailable"
    case channelGone = "resumedButChannelGone"
    case principalRevoked
    case timeout = "approvalTimeout"
    case replay = "approvalReplay"
    case cancelled = "approvalCancelled"
    case expired = "approvalExpired"
    case invalidated = "approvalInvalidated"
    case failed = "approvalFailed"
    case unknown = "approvalUnknown"
}

/// Name of an HTTP transfer failure that started a transfer.
public enum RuntimeAdmissionHTTPFailureKind: String, Sendable, Equatable, Codable, CaseIterable {
    case redirect
    case responseTooLarge
    case timedOut
    case cancelled
    case transport
    case malformedResponse
    case unsupportedTransfer
    case tooManyHeaders

    public init(_ failure: HTTPOpenFailure) {
        switch failure {
        case .redirect: self = .redirect
        case .responseTooLarge: self = .responseTooLarge
        case .timedOut: self = .timedOut
        case .cancelled: self = .cancelled
        case .transport: self = .transport
        case .malformedResponse: self = .malformedResponse
        case .unsupportedTransfer: self = .unsupportedTransfer
        case .tooManyHeaders: self = .tooManyHeaders
        }
    }
}

/// The `result` of one admission evidence row. Encodes as the single string
/// older rows already carry (`authorized`, `exit:0`, `http:200`, a rule ID,
/// a rejection name, ...), so persisted JSONL stays byte-identical.
///
/// Decoding is by spelling. Three spellings name more than one cause and
/// decode to the first listed here: `cancelled` and `unavailable` decode to
/// `executorFailed`, never `httpNotOpened` / `httpFailed`. Both re-encode to
/// the same bytes.
public enum RuntimeAdmissionResult: Sendable, Equatable, Codable {
    case authorized
    case exit(Int32)
    case http(Int)
    case evaluationFailed
    case approvalEnded(RuntimeAdmissionApprovalCause)
    case rejected(RuntimeAdmissionRejection)
    case denied(RuleID)
    case pending(ApprovalReason)
    case executorFailed(RuntimeAdmissionExecutorError)
    case httpNotOpened(HTTPNotOpened)
    case httpFailed(RuntimeAdmissionHTTPFailureKind)
    case credentialGranted(String)
    case credentialUnwired(String)
    case credentialWithheld(String)

    public var wire: String {
        switch self {
        case .authorized: "authorized"
        case .exit(let status): "exit:\(status)"
        case .http(let status): "http:\(status)"
        case .evaluationFailed: "evaluationFailed"
        case .approvalEnded(let cause): cause.rawValue
        case .rejected(let reason): reason.rawValue
        case .denied(let ruleID): ruleID.rawValue
        case .pending(let reason): reason.rawValue
        case .executorFailed(let error): error.rawValue
        case .httpNotOpened(let reason): reason.rawValue
        case .httpFailed(let kind): kind.rawValue
        case .credentialGranted(let name): "credentialGranted:\(name)"
        case .credentialUnwired(let name): "credentialUnwired:\(name)"
        case .credentialWithheld(let reason): "credentialWithheld:\(reason)"
        }
    }

    public init?(wire: String) {
        if wire == "authorized" { self = .authorized; return }
        if wire == "evaluationFailed" { self = .evaluationFailed; return }
        if let cause = RuntimeAdmissionApprovalCause(rawValue: wire) { self = .approvalEnded(cause); return }
        if let reason = RuntimeAdmissionRejection(rawValue: wire) { self = .rejected(reason); return }
        if let error = RuntimeAdmissionExecutorError(rawValue: wire) { self = .executorFailed(error); return }
        if let reason = HTTPNotOpened(rawValue: wire) { self = .httpNotOpened(reason); return }
        if let kind = RuntimeAdmissionHTTPFailureKind(rawValue: wire) { self = .httpFailed(kind); return }
        if let reason = ApprovalReason(rawValue: wire) { self = .pending(reason); return }
        if let rest = wire.dropPrefix("exit:"), let status = Int32(rest) { self = .exit(status); return }
        if let rest = wire.dropPrefix("http:"), let status = Int(rest) { self = .http(status); return }
        if let rest = wire.dropPrefix("credentialGranted:") { self = .credentialGranted(rest); return }
        if let rest = wire.dropPrefix("credentialUnwired:") { self = .credentialUnwired(rest); return }
        if let rest = wire.dropPrefix("credentialWithheld:") { self = .credentialWithheld(rest); return }
        if let ruleID = RuleID(rawValue: wire) { self = .denied(ruleID); return }
        return nil
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let wire = try container.decode(String.self)
        guard let value = RuntimeAdmissionResult(wire: wire) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "unrecognized admission result \(wire)")
        }
        self = value
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wire)
    }
}

private extension String {
    func dropPrefix(_ prefix: String) -> String? {
        hasPrefix(prefix) ? String(dropFirst(prefix.count)) : nil
    }
}
