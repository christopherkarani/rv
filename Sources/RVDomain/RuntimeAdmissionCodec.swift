import Foundation

/// Versioned admission frames. Length-prefixed JSON, bounded body, exact keys.
///
/// The agent may send a command, a request id, a capability, and a session
/// claim. It cannot send a workspace, a host, or an approval.
public enum RuntimeAdmissionCodec {
    public static let version = 1
    public static let maxBodyBytes = AgentRequestLimits.maxCommandUTF8Count + 4_096

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
        let body = WireRequest(
            v: frame.version,
            id: frame.requestID.rawValue.uuidString,
            capability: frame.capability.rawValue,
            session: frame.claimedSession.rawValue.uuidString,
            command: frame.command.rawValue
        )
        return encodeJSON(body)
    }

    public static func decodeRequest(
        _ data: Data
    ) -> Result<RuntimeActionFrame, RuntimeAdmissionDecodeError> {
        guard data.count <= maxBodyBytes else { return .failure(.oversized) }
        guard keys(in: data) == ["v", "id", "capability", "session", "command"] else {
            return .failure(.malformed)
        }
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
                command: ShellCommand(rawValue: command)
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
                approval: nil
            )
        }
        return encodeJSON(wire)
    }

    private static func encodeJSON<T: Encodable>(
        _ value: T
    ) -> Result<Data, RuntimeAdmissionDecodeError> {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let body = try? encoder.encode(value), body.count <= maxBodyBytes else {
            return .failure(.malformed)
        }
        return encodeFrame(body: body)
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

private struct WireResponse: Encodable {
    var v: Int
    var id: String?
    var status: String
    var exit: Int?
    var rule: String?
    var reason: String?
    var approval: String?
}
