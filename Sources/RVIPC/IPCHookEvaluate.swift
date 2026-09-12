import Foundation
import RVDomain

public struct HookEvaluateParams: Sendable, Equatable, Codable {
    /// Closed host family. Unknown strings fail `init(from:)` with `dataCorrupted`.
    public var host: HookHost
    public var stdin: String
    /// Additive `rv.ipc.v1` field. Same implicit-hello rule as `EvaluateParams`.
    public var clientSemver: String?

    public init(host: HookHost, stdin: String, clientSemver: String? = nil) {
        self.host = host
        self.stdin = stdin
        self.clientSemver = clientSemver
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        host = try container.decode(HookHost.self, forKey: .host)
        stdin = try container.decodeIfPresent(String.self, forKey: .stdin) ?? ""
        clientSemver = try container.decodeIfPresent(String.self, forKey: .clientSemver)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(host, forKey: .host)
        try container.encode(stdin, forKey: .stdin)
        try container.encodeIfPresent(clientSemver, forKey: .clientSemver)
    }

    private enum CodingKeys: String, CodingKey {
        case host
        case stdin
        case clientSemver
    }
}

public struct HookEvaluateReply: Sendable, Equatable, Codable {
    public var stdout: String
    public var exitCode: Int32
    /// Additive `rv.ipc.v1` field. Empty is omitted on encode so existing
    /// golden frames stay byte-identical.
    public var stderr: String
    public let via: EvaluationPath
    /// Additive `rv.ipc.v1` field. Replies without it cannot prove major
    /// compatibility; both the Swift CLI and the C hook replay through a
    /// real in-process evaluation instead of trusting them.
    public var serviceSemver: String?

    public init(
        stdout: String,
        exitCode: Int32,
        stderr: String = "",
        serviceSemver: String? = ProtocolVersion.serviceSemver
    ) {
        self.stdout = stdout
        self.exitCode = exitCode
        self.stderr = stderr
        self.via = .xpc
        self.serviceSemver = serviceSemver
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        stdout = try container.decode(String.self, forKey: .stdout)
        exitCode = try container.decode(Int32.self, forKey: .exitCode)
        let decodedVia = try container.decode(EvaluationPath.self, forKey: .via)
        guard decodedVia == .xpc else {
            throw DecodingError.dataCorruptedError(
                forKey: .via,
                in: container,
                debugDescription: "HookEvaluateReply.via must be \"xpc\""
            )
        }
        via = decodedVia
        serviceSemver = try container.decodeIfPresent(String.self, forKey: .serviceSemver)
        stderr = try container.decodeIfPresent(String.self, forKey: .stderr) ?? ""
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(stdout, forKey: .stdout)
        try container.encode(exitCode, forKey: .exitCode)
        try container.encodeIfPresent(stderr.isEmpty ? nil : stderr, forKey: .stderr)
        try container.encode(via, forKey: .via)
        try container.encodeIfPresent(serviceSemver, forKey: .serviceSemver)
    }

    private enum CodingKeys: String, CodingKey {
        case stdout
        case exitCode
        case stderr
        case via
        case serviceSemver
    }
}
