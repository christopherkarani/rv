import Foundation

/// The bytes the egress proxy writes when it refuses a request: status line,
/// an RFC 9209 `Proxy-Status` header, and a small `rv.egress.denied.v1`
/// JSON body the caged agent can act on (relay the exact CLI to the user)
/// instead of retrying blindly. Performs no I/O.
///
/// Oracle rules. The body is read by the cage, so it says only what the
/// cage could already learn or may safely learn:
/// - `binary-mismatch` and `unattributed-peer` go out as `denied-policy`
///   without a proposal, byte-identical to a policy denial that minted
///   none: binary and pin state stay off the wire (the log keeps them).
/// - `dns-failed` and `address-filtered` go out as `dial-failed`, the old
///   catch-all: otherwise the cage could probe which names the host's
///   resolver knows and which resolve to private addresses.
/// - The 407 is one constant shape for missing, malformed, and unknown
///   credentials, and is decided before the binary gate runs.
/// - No binary path, pin, credential, or filesystem path is ever echoed.
///   The host is echoed only in hostname-safe ASCII (the client's own
///   parsed authority, lowercased); anything else is omitted.
/// - A proposal id is attached only to `denied-policy` and only when it is
///   a well-formed approval id; anything else is dropped.
struct EgressDenialResponse: Sendable, Equatable {
    static let schema = "rv.egress.denied.v1"
    /// Hard ceiling on the JSON body. The largest real body (253-byte host
    /// plus a proposal) is well under it; a body that would exceed it falls
    /// back to the host-less form.
    static let maximumBodyBytes = 1024

    /// Reason as it goes on the wire, after the oracle collapse above.
    let reason: EgressDenialReason
    let host: String?
    let port: Int?
    let proposalID: String?

    init(reason recorded: EgressDenialReason, host: String, port: Int, proposalID: String? = nil) {
        let reason = Self.wireReason(for: recorded)
        self.reason = reason
        self.host = Self.echoableHost(host)
        self.port = (1...65535).contains(port) ? port : nil
        // Gate on the recorded reason: a binary denial wears the
        // denied-policy wire reason but must never carry a proposal.
        self.proposalID = recorded == .deniedPolicy ? proposalID.flatMap(Self.validProposalID) : nil
    }

    /// Recorded reason to wire reason. Exhaustive so a new case must choose.
    static func wireReason(for recorded: EgressDenialReason) -> EgressDenialReason {
        switch recorded {
        case .deniedPolicy, .binaryMismatch, .unattributedPeer, .sniMismatch:
            return .deniedPolicy
        case .dnsFailed, .addressFiltered, .dialFailed:
            return .dialFailed
        case .headerTooLarge:
            return .headerTooLarge
        case .malformed:
            return .malformed
        case .deniedCredential:
            return .deniedCredential
        }
    }

    /// The parsed host, lowercased, when it is 1...253 bytes of
    /// `[A-Za-z0-9._-]`; nil otherwise. Nothing that needs escaping (or
    /// could steer a terminal) is reflected.
    static func echoableHost(_ host: String) -> String? {
        let bytes = Array(host.utf8)
        guard bytes.isEmpty == false, bytes.count <= 253 else { return nil }
        guard bytes.allSatisfy(isHostByte) else { return nil }
        return host.lowercased()
    }

    /// Approval ids are `UUID().uuidString`; accept that alphabet only.
    static func validProposalID(_ id: String) -> String? {
        let bytes = Array(id.utf8)
        guard bytes.isEmpty == false, bytes.count <= 64 else { return nil }
        guard bytes.allSatisfy({ isAlphanumeric($0) || $0 == UInt8(ascii: "-") }) else { return nil }
        return id
    }

    var statusLine: String {
        reason == .deniedCredential
            ? "HTTP/1.1 407 Proxy Authentication Required"
            : "HTTP/1.1 403 Forbidden"
    }

    /// One sentence for the agent to relay. Constant per wire reason.
    var message: String {
        switch reason {
        case .deniedPolicy where proposalID != nil:
            return "rv blocked this connection under the egress policy and filed a review proposal the user can approve."
        case .deniedPolicy:
            return "rv blocked this connection under the egress policy for this runtime."
        case .dialFailed:
            return "rv's egress proxy could not reach the destination."
        case .headerTooLarge:
            return "rv's egress proxy refused the request because its headers exceed 64 KiB."
        case .malformed:
            return "rv's egress proxy accepts only CONNECT host:port or an absolute http:// request."
        case .deniedCredential:
            return "rv's egress proxy requires this runtime's proxy credential; use the proxy URL rv provided unchanged."
        default:
            return "rv blocked this connection under the egress policy for this runtime."
        }
    }

    /// The exact command the user runs on the host, if any.
    var nextStep: String? {
        if let proposalID {
            return "rv egress approve \(proposalID)"
        }
        switch reason {
        case .deniedPolicy, .dialFailed, .deniedCredential:
            return "rv egress denials"
        default:
            return nil
        }
    }

    /// RFC 9209 error type for the wire reason.
    var proxyStatusError: String {
        switch reason {
        case .dialFailed: return "destination_unavailable"
        case .headerTooLarge, .malformed: return "http_request_error"
        default: return "http_request_denied"
        }
    }

    /// `Proxy-Status` value. `details` is an sf-string of printable ASCII
    /// built only from constants and validated ids, so it needs no escapes.
    var proxyStatus: String {
        var details = reason.rawValue
        if let nextStep {
            details += "; run: " + nextStep
        }
        return "rv-egress; error=\(proxyStatusError); details=\"\(details)\""
    }

    /// The JSON body: keys in a fixed order so equal inputs are equal bytes.
    var body: [UInt8] {
        let full = Self.encode(fields(includingHost: true))
        guard full.count > Self.maximumBodyBytes else { return full }
        return Self.encode(fields(includingHost: false))
    }

    /// The whole response, ready for one `writeAll`.
    var bytes: [UInt8] {
        let body = body
        var head = statusLine + "\r\n"
        if reason == .deniedCredential {
            head += "Proxy-Authenticate: Bearer\r\n"
        }
        head += "Proxy-Status: \(proxyStatus)\r\n"
        head += "Content-Type: application/json\r\n"
        head += "Content-Length: \(body.count)\r\n"
        head += "Connection: close\r\n\r\n"
        return Array(head.utf8) + body
    }

    private enum Value {
        case string(String)
        case int(Int)
    }

    private func fields(includingHost: Bool) -> [(String, Value)] {
        var fields: [(String, Value)] = [
            ("schema", .string(Self.schema)),
            ("reason", .string(reason.rawValue)),
        ]
        if includingHost, let host {
            fields.append(("host", .string(host)))
        }
        if let port {
            fields.append(("port", .int(port)))
        }
        fields.append(("message", .string(message)))
        if let proposalID {
            fields.append(("proposal_id", .string(proposalID)))
        }
        if let nextStep {
            fields.append(("next_step", .string(nextStep)))
        }
        return fields
    }

    private static func encode(_ fields: [(String, Value)]) -> [UInt8] {
        let members = fields.map { key, value -> String in
            switch value {
            case .string(let text): return jsonString(key) + ":" + jsonString(text)
            case .int(let number): return jsonString(key) + ":" + String(number)
            }
        }
        return Array(("{" + members.joined(separator: ",") + "}").utf8)
    }

    /// JSON string literal. Every input is already restricted ASCII; this
    /// still escapes quote, backslash, controls, and non-ASCII so a future
    /// field cannot break the document.
    static func jsonString(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case _ where scalar.value < 0x20 || scalar.value > 0x7E:
                if scalar.value > 0xFFFF {
                    for unit in String(scalar).utf16 {
                        out += String(format: "\\u%04x", unit)
                    }
                } else {
                    out += String(format: "\\u%04x", scalar.value)
                }
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    private static func isAlphanumeric(_ byte: UInt8) -> Bool {
        (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "z"))
            || (byte >= UInt8(ascii: "A") && byte <= UInt8(ascii: "Z"))
            || (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
    }

    private static func isHostByte(_ byte: UInt8) -> Bool {
        isAlphanumeric(byte) || byte == UInt8(ascii: ".") || byte == UInt8(ascii: "-")
            || byte == UInt8(ascii: "_")
    }
}
