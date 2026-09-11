import Foundation
import RVDomain

public struct EvaluateParams: Sendable, Equatable, Codable {
    public var request: EvaluationRequest
    public var cwd: WorkingDirectory?
    /// Additive `rv.ipc.v1` field. Old clients omit it and Hello first.
    public var clientSemver: String?

    public init(request: EvaluationRequest, cwd: WorkingDirectory? = nil, clientSemver: String? = nil) {
        self.request = request
        self.cwd = cwd
        self.clientSemver = clientSemver
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        request = try container.decode(EvaluationRequest.self, forKey: .request)
        cwd = RequestCwdCoding.nonempty(try container.decodeIfPresent(String.self, forKey: .cwd))
        clientSemver = try container.decodeIfPresent(String.self, forKey: .clientSemver)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(request, forKey: .request)
        try container.encodeIfPresent(cwd, forKey: .cwd)
        try container.encodeIfPresent(clientSemver, forKey: .clientSemver)
    }

    private enum CodingKeys: String, CodingKey {
        case request
        case cwd
        case clientSemver
    }
}

/// Evaluation route: trusted service reply (`xpc`) or client in-process fallback (`inProcess`).
///
/// On `EvaluateReply`, only `.xpc` decodes. `.inProcess` is reserved for client-side
/// routing and is rejected on the wire.
public enum EvaluationPath: String, Sendable, Equatable, Codable {
    case xpc
    case inProcess
}

public struct EvaluateReply: Sendable, Equatable, Codable {
    public var result: EvaluationResult
    public let via: EvaluationPath
    /// Additive `rv.ipc.v1` field. Replies without it cannot prove major
    /// compatibility, so clients reject them and fall back in-process.
    public var serviceSemver: String?

    public init(result: EvaluationResult, serviceSemver: String? = ProtocolVersion.serviceSemver) {
        self.result = result
        self.via = .xpc
        self.serviceSemver = serviceSemver
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        result = try container.decode(EvaluationResult.self, forKey: .result)
        let decodedVia = try container.decode(EvaluationPath.self, forKey: .via)
        guard decodedVia == .xpc else {
            throw DecodingError.dataCorruptedError(
                forKey: .via,
                in: container,
                debugDescription: "EvaluateReply.via must be \"xpc\""
            )
        }
        via = decodedVia
        serviceSemver = try container.decodeIfPresent(String.self, forKey: .serviceSemver)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(result, forKey: .result)
        try container.encode(via, forKey: .via)
        try container.encodeIfPresent(serviceSemver, forKey: .serviceSemver)
    }

    private enum CodingKeys: String, CodingKey {
        case result
        case via
        case serviceSemver
    }
}
