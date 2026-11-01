import Foundation

/// Where in a request the gateway may swap a placeholder for its value.
/// The body is not a surface; it always passes through untouched.
public enum GatewaySurface: String, Sendable, Hashable, CaseIterable {
    case header
    case query
    case path

    /// Most APIs take credentials in `Authorization` or a custom header.
    /// Query strings and paths land in upstream access logs, so they are opt-in.
    public static let defaults: Set<GatewaySurface> = [.header]

    /// `surfaces` in `allCases` order, for stable config and CLI output.
    public static func ordered(_ surfaces: Set<GatewaySurface>) -> [GatewaySurface] {
        allCases.filter(surfaces.contains)
    }
}

/// One allow rule for a gateway secret: these methods on paths matching
/// `path`. `*` matches within one path segment, `**` any number of segments.
public struct GatewayAccessRule: Sendable, Hashable {
    public static let maximumPathBytes = 256
    public static let maximumMethods = 16
    /// More `**` segments make matching cost grow with the path length.
    static let maximumDeepWildcards = 2

    /// Upper-case methods. Nil allows any method.
    public let methods: Set<String>?
    public let path: String
    /// Query parameters that must be present, each only with this value.
    /// Presets use it (`service=git-upload-pack`); config rules cannot.
    let query: [String: String]

    public init?(methods: Set<String>?, path: String) {
        guard methods.map({ $0.isEmpty == false && $0.count <= Self.maximumMethods && $0.allSatisfy(Self.isMethod) })
            ?? true,
            Self.isGlob(path)
        else { return nil }
        self.init(methods: methods, path: path, query: [:])
    }

    init(methods: Set<String>?, path: String, query: [String: String]) {
        self.methods = methods
        self.path = path
        self.query = query
    }

    public static func isMethod(_ text: String) -> Bool {
        (1...20).contains(text.utf8.count) && text.utf8.allSatisfy { $0 >= 65 && $0 <= 90 }
    }

    /// `/`-rooted, printable ASCII, no `%`, `?`, `#`, `\`, `;`, no `.` or
    /// `..` segments, an empty segment only at the end, and `**` only as a
    /// whole segment.
    static func isGlob(_ text: String) -> Bool {
        guard text.hasPrefix("/"), text.utf8.count <= maximumPathBytes,
            text.utf8.allSatisfy({ $0 > 32 && $0 < 127 && "%?#\\;".utf8.contains($0) == false })
        else { return false }
        let segments = text.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        for (index, segment) in segments.enumerated() {
            if segment.isEmpty, index != segments.count - 1 { return false }
            if segment == "." || segment == ".." { return false }
            if segment.contains("**"), segment != "**" { return false }
        }
        return segments.filter { $0 == "**" }.count <= maximumDeepWildcards
    }

    func permits(method: String, path: String, query raw: String) -> Bool {
        if let methods, methods.contains(method) == false { return false }
        guard GatewayAccess.glob(self.path, matches: path) else { return false }
        guard query.isEmpty == false else { return true }
        let pairs = GatewayAccess.queryPairs(raw)
        return query.allSatisfy { name, value in
            let values = pairs.filter { $0.name == name }.map(\.value)
            return values.isEmpty == false && values.allSatisfy { $0 == value }
        }
    }
}

/// Named rule sets, so common scopes need no hand-written globs.
public enum GatewayAccessPreset: String, Sendable, Hashable, CaseIterable {
    /// GET, HEAD, OPTIONS anywhere (OpenShell's `read-only`).
    case readOnly = "read-only"
    /// Git smart-HTTP fetch and clone on github.com; push (receive-pack) is refused.
    case githubClone = "github-clone"
    /// GET and HEAD on api.github.com; no writes and no GraphQL.
    case githubRead = "github-read"

    public var rules: [GatewayAccessRule] {
        switch self {
        case .readOnly:
            [GatewayAccessRule(methods: ["GET", "HEAD", "OPTIONS"], path: "/**", query: [:])]
        case .githubClone:
            [
                GatewayAccessRule(methods: ["GET"], path: "/**/info/refs", query: ["service": "git-upload-pack"]),
                GatewayAccessRule(methods: ["POST"], path: "/**/git-upload-pack", query: [:]),
            ]
        case .githubRead:
            [GatewayAccessRule(methods: ["GET", "HEAD"], path: "/**", query: [:])]
        }
    }
}

/// One `allow` entry: a preset by name or an explicit rule.
public enum GatewayAllowance: Sendable, Hashable {
    case preset(GatewayAccessPreset)
    case rule(GatewayAccessRule)

    public static let maximumEntries = 32

    public var rules: [GatewayAccessRule] {
        switch self {
        case .preset(let preset): preset.rules
        case .rule(let rule): [rule]
        }
    }

    /// CLI form: a preset name, or `METHODS PATH` such as `GET,HEAD /repos/**`
    /// or `* /v1/**`.
    public init?(_ text: String) {
        if let preset = GatewayAccessPreset(rawValue: text) {
            self = .preset(preset)
            return
        }
        let parts = text.split(separator: " ", maxSplits: 1)
        guard parts.count == 2 else { return nil }
        let methods: Set<String>?
        if parts[0] == "*" {
            methods = nil
        } else {
            let list = parts[0].split(separator: ",", omittingEmptySubsequences: false).map(String.init)
            guard Set(list).count == list.count else { return nil }
            methods = Set(list)
        }
        guard let rule = GatewayAccessRule(methods: methods, path: String(parts[1])) else { return nil }
        self = .rule(rule)
    }
}

enum GatewayAccess {
    /// Why a request falls outside `rules`, or nil when it may proceed. No
    /// rules allow everything. Runs on the pre-substitution request, so the
    /// matched path never holds the secret.
    static func refusal(
        _ rules: [GatewayAccessRule], method: String, route: GatewayRoute, basePath: String
    ) -> GatewayRefusal? {
        guard rules.isEmpty == false else { return nil }
        let remainder = route.remainder
        let queryStart = remainder.firstIndex(of: "?") ?? remainder.endIndex
        let joined = basePath + remainder[..<queryStart]
        guard let path = normalizedPath(joined.isEmpty ? "/" : joined) else { return .ambiguousPath }
        let query = remainder[queryStart...].dropFirst()
        let allowed = rules.contains { $0.permits(method: method, path: path, query: String(query)) }
        return allowed ? nil : .outsideAllowRules
    }

    /// The path decoded once, or nil when an upstream could read it in a
    /// way the matcher did not: an encoded `/` or `\`, a `.` or `..`
    /// segment (raw or encoded), `;` parameters, an empty segment before the
    /// end, control bytes, or a `%` left after decoding (double encoding).
    static func normalizedPath(_ raw: String) -> String? {
        guard raw.hasPrefix("/") else { return nil }
        let segments = raw.dropFirst().split(separator: "/", omittingEmptySubsequences: false)
        var decoded: [String] = []
        for (index, segment) in segments.enumerated() {
            if segment.isEmpty {
                guard index == segments.count - 1 else { return nil }
                decoded.append("")
                continue
            }
            let bytes = GatewaySubstitution.percentDecoded(Array(segment.utf8))
            guard bytes.allSatisfy({ $0 >= 32 && $0 != 127 && "/\\;%".utf8.contains($0) == false }),
                let text = String(validating: bytes, as: UTF8.self), text != ".", text != ".."
            else { return nil }
            decoded.append(text)
        }
        return "/" + decoded.joined(separator: "/")
    }

    static func glob(_ pattern: String, matches path: String) -> Bool {
        segments(Array(pattern.dropFirst().split(separator: "/", omittingEmptySubsequences: false))[...],
            match: Array(path.dropFirst().split(separator: "/", omittingEmptySubsequences: false))[...])
    }

    private static func segments(_ pattern: ArraySlice<Substring>, match path: ArraySlice<Substring>) -> Bool {
        guard let first = pattern.first else { return path.isEmpty }
        if first == "**" {
            let rest = pattern.dropFirst()
            return (0...path.count).contains { segments(rest, match: path.dropFirst($0)) }
        }
        guard let segment = path.first, wildcard(Array(first.utf8), matches: Array(segment.utf8)) else { return false }
        return segments(pattern.dropFirst(), match: path.dropFirst())
    }

    /// `*` matches any run of bytes inside one segment.
    private static func wildcard(_ pattern: [UInt8], matches text: [UInt8]) -> Bool {
        var p = 0, t = 0
        var star: Int?
        var resume = 0
        while t < text.count {
            if p < pattern.count, pattern[p] == UInt8(ascii: "*") {
                star = p
                resume = t
                p += 1
            } else if p < pattern.count, pattern[p] == text[t] {
                p += 1
                t += 1
            } else if let star {
                p = star + 1
                resume += 1
                t = resume
            } else {
                return false
            }
        }
        while p < pattern.count, pattern[p] == UInt8(ascii: "*") { p += 1 }
        return p == pattern.count
    }

    /// `name=value` pairs, each half percent-decoded once.
    static func queryPairs(_ raw: String) -> [(name: String, value: String)] {
        raw.split(separator: "&").map { pair in
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            func decode(_ text: Substring) -> String {
                String(decoding: GatewaySubstitution.percentDecoded(Array(text.utf8)), as: UTF8.self)
            }
            return (decode(parts[0]), parts.count > 1 ? decode(parts[1]) : "")
        }
    }
}
