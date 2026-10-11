/// Analytics payload value mirror for the RVDomain-side safety gate.
public enum AnalyticsGateValue: Sendable, Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case strings([String])
}

/// Four-seam secrets redaction: URL, header, analytics, and log rules.
extension ReviewSanitizer {
    /// Strips query values, the fragment, and userinfo, keeping names, scheme, host, and path.
    public static func redactURL(_ raw: String) -> String {
        if raw.isEmpty { return raw }
        let cap = HTTPEgressLimits.maxURLUTF8Bytes
        guard raw.utf8.prefix(cap + 1).count <= cap else { return redactedPlaceholder }
        let withoutFragment: String
        if let hash = raw.firstIndex(of: "#") {
            withoutFragment = String(raw[..<hash])
        } else {
            withoutFragment = raw
        }
        guard let schemeEnd = withoutFragment.range(of: "://") else {
            return redactCredentials(in: raw)
        }
        let scheme = String(withoutFragment[..<schemeEnd.lowerBound])
        guard scheme.isEmpty == false else { return redactCredentials(in: raw) }
        let afterScheme = withoutFragment[schemeEnd.upperBound...]
        let authorityEnd = afterScheme.firstIndex(where: { $0 == "/" || $0 == "?" }) ?? afterScheme.endIndex
        var authority = String(afterScheme[..<authorityEnd])
        guard authority.isEmpty == false else { return redactCredentials(in: raw) }
        guard containsControlScalar(scheme) == false, containsControlScalar(authority) == false else {
            return redactedPlaceholder
        }
        let tail = String(afterScheme[authorityEnd...])
        if let split = authority.lastIndex(of: "@") {
            authority = String(authority[authority.index(after: split)...])
            guard authority.isEmpty == false else { return redactCredentials(in: raw) }
        } else if tail.isEmpty,
            let hash = raw.firstIndex(of: "#"),
            raw[hash...].prefix(while: { $0 != "/" && $0 != "?" }).contains("@")
        {
            // '#' cut userinfo before its '@'; the kept text is credentials, not a host.
            return redactedPlaceholder
        }
        if let mark = tail.firstIndex(of: "?") {
            let path = String(tail[..<mark])
            guard containsControlScalar(path) == false else { return redactedPlaceholder }
            let query = redactQueryNames(String(tail[tail.index(after: mark)...]))
            return "\(scheme)://\(authority)\(path)?\(query)"
        }
        guard containsControlScalar(tail) == false else { return redactedPlaceholder }
        return "\(scheme)://\(authority)\(tail)"
    }

    /// True when the text holds an ASCII control or C1 control scalar.
    private static func containsControlScalar(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.value < 0x20 || (0x7F...0x9F).contains($0.value) }
    }

    /// Redacts every header value outside a small safe set; auth headers are always redacted.
    public static func redactHeaders(_ headers: [String: String]) -> [String: String] {
        Dictionary(
            uniqueKeysWithValues: headers.map { header in
                (header.key, allowedHeaders.contains(header.key.lowercased()) ? header.value : redactedPlaceholder)
            }
        )
    }

    /// Reports whether an analytics value holds only a boolean or a count.
    public static func isAnalyticsSafe(_ value: AnalyticsGateValue) -> Bool {
        switch value {
        case .bool, .int:
            return true
        case .string, .strings:
            return false
        }
    }

    /// Reports whether every analytics property holds only a boolean or a count.
    public static func isAnalyticsSafe(properties: [String: AnalyticsGateValue]) -> Bool {
        properties.values.allSatisfy { isAnalyticsSafe($0) }
    }

    /// Scrubs secret-shaped values from a free-text log line, keeping labels.
    public static func redactLog(_ message: String) -> String {
        redactCredentials(in: message)
    }

    /// Header names whose values are protocol tokens that never carry secrets.
    private static let allowedHeaders: Set<String> = [
        "content-type",
        "content-length",
        "accept",
        "accept-encoding",
    ]

    /// Keeps query parameter names while replacing every value with the placeholder.
    /// Valueless pairs run the credential rulebook so a bare pasted token
    /// (`?ghp_…`) does not survive while plain flags (`?debug`) do.
    private static func redactQueryNames(_ query: String) -> String {
        query
            .split(separator: "&", omittingEmptySubsequences: false)
            .map { pair in
                guard let equals = pair.firstIndex(of: "=") else {
                    return redactCredentials(in: String(pair))
                }
                return "\(pair[..<equals])=\(redactedPlaceholder)"
            }
            .joined(separator: "&")
    }
}
