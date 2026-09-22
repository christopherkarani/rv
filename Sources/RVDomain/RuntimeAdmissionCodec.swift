import Foundation

/// Versioned admission frames. Length-prefixed JSON, bounded body, exact keys.
///
/// The agent may send a command, a request id, a capability, and a session
/// claim. It cannot send a workspace, a host, or an approval.
public enum RuntimeAdmissionCodec {
    public static let version = 1
    public static let maxBodyBytes = AgentRequestLimits.maxCommandUTF8Count + 4_096
    /// Response frames can carry a bounded body. Request frames stay at `maxBodyBytes`.
    public static let maxResponseBytes = 131_072

    public static func encodeFrame(body: Data) -> Result<Data, RuntimeAdmissionDecodeError> {
        guard body.count <= maxBodyBytes, body.isEmpty == false else {
            return .failure(body.isEmpty ? .malformed : .oversized)
        }
        var header = UInt32(body.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(body)
        return .success(frame)
    }

    /// Reads one complete frame from the front of `buffer` and removes it.
    /// Nil means the buffer does not contain a whole frame yet.
    public static func takeFrame(
        from buffer: inout Data
    ) -> Result<Data, RuntimeAdmissionDecodeError>? {
        guard buffer.count >= 4 else { return nil }
        let declared = buffer.prefix(4).withUnsafeBytes { raw -> UInt32 in
            raw.loadUnaligned(as: UInt32.self).bigEndian
        }
        if declared == 0 {
            buffer.removeFirst(4)
            return .failure(.malformed)
        }
        if declared > UInt32(maxBodyBytes) {
            buffer.removeAll()
            return .failure(.oversized)
        }
        let total = 4 + Int(declared)
        guard buffer.count >= total else { return nil }
        let body = Data(buffer.prefix(total).dropFirst(4))
        buffer.removeFirst(total)
        return .success(body)
    }

    public static func encodeGrant(
        capability: RuntimeCapability,
        session: UUID
    ) -> Result<Data, RuntimeAdmissionDecodeError> {
        let body = WireGrant(
            v: version,
            type: "grant",
            capability: capability.rawValue,
            session: session.uuidString
        )
        return encodeJSON(body)
    }

    public static func encodeRequest(
        _ frame: RuntimeActionFrame
    ) -> Result<Data, RuntimeAdmissionDecodeError> {
        switch frame.action {
        case .shell(let command):
            let body = WireRequest(
                v: frame.version,
                id: frame.requestID.rawValue.uuidString,
                capability: frame.capability.rawValue,
                session: frame.claimedSession.rawValue.uuidString,
                command: command.rawValue
            )
            return encodeJSON(body)
        case .http(let method, let url):
            let body = WireHTTPRequest(
                v: frame.version,
                id: frame.requestID.rawValue.uuidString,
                capability: frame.capability.rawValue,
                session: frame.claimedSession.rawValue.uuidString,
                method: method,
                url: url
            )
            return encodeJSON(body)
        }
    }

    public static func decodeRequest(
        _ data: Data
    ) -> Result<RuntimeActionFrame, RuntimeAdmissionDecodeError> {
        guard data.count <= maxBodyBytes else { return .failure(.oversized) }
        guard let present = keys(in: data) else { return .failure(.malformed) }
        if present == ["v", "id", "capability", "session", "command"] {
            return decodeShell(data)
        }
        if present == ["v", "id", "capability", "session", "method", "url"] {
            return decodeHTTP(data)
        }
        return .failure(.malformed)
    }

    private static func decodeShell(
        _ data: Data
    ) -> Result<RuntimeActionFrame, RuntimeAdmissionDecodeError> {
        guard let wire = try? JSONDecoder().decode(WireRequest.self, from: data) else {
            return .failure(.malformed)
        }
        guard wire.v == version else { return .failure(.malformed) }
        guard let requestID = RuntimeActionRequestID(validating: wire.id),
            let capability = RuntimeCapability(validating: wire.capability),
            let claimedSession = RuntimeSessionClaim(validating: wire.session)
        else {
            return .failure(.malformed)
        }
        let command = wire.command
        if command.utf8.count > AgentRequestLimits.maxCommandUTF8Count
            || command.contains("\0")
            || command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return .failure(.malformed)
        }
        return .success(
            RuntimeActionFrame(
                version: wire.v,
                requestID: requestID,
                capability: capability,
                claimedSession: claimedSession,
                action: .shell(ShellCommand(rawValue: command))
            )
        )
    }

    private static func decodeHTTP(
        _ data: Data
    ) -> Result<RuntimeActionFrame, RuntimeAdmissionDecodeError> {
        guard let wire = try? JSONDecoder().decode(WireHTTPRequest.self, from: data) else {
            return .failure(.malformed)
        }
        guard wire.v == version else { return .failure(.malformed) }
        guard let requestID = RuntimeActionRequestID(validating: wire.id),
            let capability = RuntimeCapability(validating: wire.capability),
            let claimedSession = RuntimeSessionClaim(validating: wire.session)
        else {
            return .failure(.malformed)
        }
        if wire.method.utf8.count > 20 || wire.method.isEmpty || wire.method.contains("\0")
            || wire.url.utf8.count > HTTPEgressLimits.maxURLUTF8Bytes || wire.url.isEmpty
            || wire.url.contains("\0")
        {
            return .failure(.malformed)
        }
        return .success(
            RuntimeActionFrame(
                version: wire.v,
                requestID: requestID,
                capability: capability,
                claimedSession: claimedSession,
                action: .http(method: wire.method, url: wire.url)
            )
        )
    }

    public static func encodeResponse(
        _ response: RuntimeAdmissionResponse,
        requestID: String?
    ) -> Result<Data, RuntimeAdmissionDecodeError> {
        let wire: WireResponse
        switch response {
        case .executed(let exitStatus):
            wire = WireResponse(
                v: version,
                id: requestID,
                status: "executed",
                exit: Int(exitStatus),
                rule: nil,
                reason: nil,
                approval: nil
            )
        case .denied(let deny):
            wire = WireResponse(
                v: version,
                id: requestID,
                status: "denied",
                exit: nil,
                rule: deny.ruleID.rawValue,
                reason: deny.reason,
                approval: nil
            )
        case .pending(let reason):
            wire = WireResponse(
                v: version,
                id: requestID,
                status: "pending",
                exit: nil,
                rule: nil,
                reason: nil,
                approval: reason.rawValue
            )
        case .rejected(let reason):
            wire = WireResponse(
                v: version,
                id: requestID,
                status: "rejected",
                exit: nil,
                rule: nil,
                reason: reason.rawValue,
                approval: nil
            )
        case .evaluationFailed:
            wire = WireResponse(
                v: version,
                id: requestID,
                status: "evaluationFailed",
                exit: nil,
                rule: nil,
                reason: "evaluationFailed",
                approval: nil
            )
        case .approvalUnavailable:
            wire = WireResponse(
                v: version,
                id: requestID,
                status: "approvalUnavailable",
                exit: nil,
                rule: nil,
                reason: "approvalUnavailable",
                approval: nil
            )
        case .executorFailed(let error):
            wire = WireResponse(
                v: version,
                id: requestID,
                status: "executorFailed",
                exit: nil,
                rule: nil,
                reason: error.rawValue,
                approval: nil,
                httpStatus: nil,
                destination: nil,
                body: nil,
                headers: nil,
                location: nil
            )
        case .http(let receipt):
            wire = WireResponse(
                v: version,
                id: requestID,
                status: "http",
                exit: nil,
                rule: nil,
                reason: nil,
                approval: nil,
                httpStatus: receipt.status,
                destination: receipt.destination,
                body: receipt.body.base64EncodedString(),
                headers: receipt.headers.map {
                    WireHTTPHeader(name: $0.name, value: $0.value)
                },
                location: nil
            )
        case .httpFailed(let failure):
            let reason: String
            let httpStatus: Int?
            let location: String?
            switch failure {
            case .redirect(let status, let redirectLocation):
                reason = "redirect"
                httpStatus = status
                location = redirectLocation
            case .responseTooLarge:
                reason = "responseTooLarge"
                httpStatus = nil
                location = nil
            case .timedOut:
                reason = "timedOut"
                httpStatus = nil
                location = nil
            case .cancelled:
                reason = "cancelled"
                httpStatus = nil
                location = nil
            case .transport:
                reason = "transport"
                httpStatus = nil
                location = nil
            case .malformedResponse:
                reason = "malformedResponse"
                httpStatus = nil
                location = nil
            case .unsupportedTransfer:
                reason = "unsupportedTransfer"
                httpStatus = nil
                location = nil
            case .tooManyHeaders:
                reason = "tooManyHeaders"
                httpStatus = nil
                location = nil
            }
            wire = WireResponse(
                v: version,
                id: requestID,
                status: "httpFailed",
                exit: nil,
                rule: nil,
                reason: reason,
                approval: nil,
                httpStatus: httpStatus,
                destination: nil,
                body: nil,
                headers: nil,
                location: location
            )
        }
        let limit = responseLimit(response)
        let encoded = encodeJSON(wire, limit: limit)
        if case .http = response, case .failure = encoded {
            return encodeResponse(.httpFailed(.responseTooLarge), requestID: requestID)
        }
        return encoded
    }

    private static func responseLimit(_ response: RuntimeAdmissionResponse) -> Int {
        switch response {
        case .http, .httpFailed:
            return maxResponseBytes
        default:
            return maxBodyBytes
        }
    }

    private static func encodeJSON<T: Encodable>(
        _ value: T,
        limit: Int = maxBodyBytes
    ) -> Result<Data, RuntimeAdmissionDecodeError> {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let body = try? encoder.encode(value), body.count <= limit else {
            return .failure(.malformed)
        }
        return encodeFrame(body: body, limit: limit)
    }

    private static func encodeFrame(
        body: Data,
        limit: Int
    ) -> Result<Data, RuntimeAdmissionDecodeError> {
        guard body.count <= limit, body.isEmpty == false else {
            return .failure(body.isEmpty ? .malformed : .oversized)
        }
        var header = UInt32(body.count).bigEndian
        var frame = Data(bytes: &header, count: 4)
        frame.append(body)
        return .success(frame)
    }

    private static func keys(in data: Data) -> Set<String>? {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return Set(value.keys)
    }
}

private struct WireGrant: Encodable {
    var v: Int
    var type: String
    var capability: String
    var session: String
}

private struct WireRequest: Codable {
    var v: Int
    var id: String
    var capability: String
    var session: String
    var command: String
}

private struct WireHTTPRequest: Codable {
    var v: Int
    var id: String
    var capability: String
    var session: String
    var method: String
    var url: String
}

private struct WireHTTPHeader: Encodable {
    var name: String
    var value: String
}

private struct WireResponse: Encodable {
    var v: Int
    var id: String?
    var status: String
    var exit: Int?
    var rule: String?
    var reason: String?
    var approval: String?
    var httpStatus: Int? = nil
    var destination: String? = nil
    var body: String? = nil
    var headers: [WireHTTPHeader]? = nil
    var location: String? = nil

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(v, forKey: .v)
        try container.encodeIfPresent(id, forKey: .id)
        try container.encode(status, forKey: .status)
        try container.encodeIfPresent(exit, forKey: .exit)
        try container.encodeIfPresent(rule, forKey: .rule)
        try container.encodeIfPresent(reason, forKey: .reason)
        try container.encodeIfPresent(approval, forKey: .approval)
        try container.encodeIfPresent(httpStatus, forKey: .httpStatus)
        try container.encodeIfPresent(destination, forKey: .destination)
        try container.encodeIfPresent(body, forKey: .body)
        try container.encodeIfPresent(headers, forKey: .headers)
        try container.encodeIfPresent(location, forKey: .location)
    }

    private enum CodingKeys: String, CodingKey {
        case v
        case id
        case status
        case exit
        case rule
        case reason
        case approval
        case httpStatus
        case destination
        case body
        case headers
        case location
    }
}
