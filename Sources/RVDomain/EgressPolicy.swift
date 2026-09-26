/// CONNECT policy for the filtering egress proxy.
///
/// Contained processes reach only loopback sockets (seatbelt `localhost`
/// rule). Runtimes talk to a loopback proxy that dials external
/// destinations and resolves names itself; clients never supply IPs.
/// External names must be valid multi-label DNS names (no IP literals, no
/// userinfo), and the proxy dials only addresses that pass the
/// public-unicast filter — loopback, private, link-local (including the
/// cloud metadata endpoint), multicast, and reserved ranges never relay,
/// so DNS rebinding buys no lateral capability. Loopback targets are not
/// egress and are admitted separately so local gateways and loopback
/// servers keep working.
public struct EgressHostPolicy: Sendable, Equatable {
    public static let httpsPort = 443
    public static let httpPort = 80

    /// How external (non-loopback) destinations are admitted.
    public enum ExternalMode: Sendable, Equatable {
        /// Exact-host allowlist on one port. Legacy narrow mode.
        case allowlist
        /// Ordinary public development traffic: any valid public DNS name
        /// on the web ports, subject to the proxy's public-unicast dial
        /// filter. No per-host RV patch when a registry, forge, or agent
        /// provider uses another hostname.
        case publicHTTPS
    }

    /// Agent API defaults, each observed from a real agent run: claude and
    /// codex via api.anthropic.com / api.openai.com, ChatGPT-plan codex via
    /// chatgpt.com (backend) and auth.openai.com (OAuth refresh), muse via
    /// api.meta.ai with OAuth at auth.meta.com, opencode via opencode.ai
    /// with its model catalog at models.opencode.ai. Narrow legacy mode;
    /// Standard workspaces use `publicHTTPS`.
    public static let agentAPIs = EgressHostPolicy(
        allowedHosts: [
            "api.anthropic.com", "api.openai.com", "chatgpt.com",
            "auth.openai.com", "api.meta.ai", "auth.meta.com",
            "opencode.ai", "models.opencode.ai",
        ]
    )

    /// Standard-workspace default: generic public web egress.
    public static let publicHTTPS = EgressHostPolicy(
        allowedHosts: [],
        mode: .publicHTTPS
    )

    public var allowedHosts: Set<String>
    public var allowedPort: Int
    public var mode: ExternalMode

    public init(
        allowedHosts: Set<String>,
        allowedPort: Int = httpsPort,
        mode: ExternalMode = .allowlist
    ) {
        self.allowedHosts = allowedHosts
        self.allowedPort = allowedPort
        self.mode = mode
    }

    public func allows(host: String, port: Int) -> Bool {
        switch mode {
        case .allowlist:
            guard port == allowedPort else { return false }
            guard let name = canonicalEgressDNSName(host) else { return false }
            return allowedHosts.contains(name)
        case .publicHTTPS:
            guard port == Self.httpsPort || port == Self.httpPort else { return false }
            return canonicalEgressDNSName(host) != nil
        }
    }

    /// Loopback CONNECT targets on any port. The cage reaches loopback
    /// directly, so proxying there grants no new capability; it only keeps
    /// proxied clients (agents with HTTPS_PROXY set and no NO_PROXY) able
    /// to use local gateways and loopback MCP servers.
    public func allowsLoopbackTarget(host: String, port: Int) -> Bool {
        guard (1...65535).contains(port) else { return false }
        guard let name = canonicalEgressLoopbackName(host) else { return false }
        return name == "localhost" || isEgressLoopbackIPv4(name)
    }
}

/// `localhost` (any case, optional trailing dot) or a dotted quad in
/// 127.0.0.0/8. Bracketed IPv6 is rejected: proxied clients use IPv4
/// loopback, and the seatbelt rule admits the same.
private func canonicalEgressLoopbackName(_ raw: String) -> String? {
    var name = raw
    if name.hasSuffix(".") {
        name.removeLast()
    }
    guard name.isEmpty == false, name.utf8.count <= 253 else { return nil }
    guard name.allSatisfy({ $0.asciiValue != nil }) else { return nil }
    name = name.lowercased()
    if name == "localhost" {
        return name
    }
    let labels = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard labels.count == 4, labels.allSatisfy({ $0.isEmpty == false }) else { return nil }
    for label in labels {
        guard label.count <= 3, label.allSatisfy(isEgressASCIIDigit) else { return nil }
        guard let value = Int(label), value <= 255 else { return nil }
    }
    return name
}

private func isEgressLoopbackIPv4(_ name: String) -> Bool {
    name.split(separator: ".").first == "127"
}

private func canonicalEgressDNSName(_ raw: String) -> String? {
    var name = raw
    if name.hasSuffix(".") {
        name.removeLast()
    }
    guard name.isEmpty == false,
          name.hasPrefix(".") == false,
          name.hasSuffix(".") == false,
          name.contains("..") == false,
          name.utf8.count <= 253
    else { return nil }
    guard name.allSatisfy({ $0.asciiValue != nil }) else { return nil }
    name = name.lowercased()
    let labels = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
    guard labels.count > 1, labels.allSatisfy({ $0.isEmpty == false }) else { return nil }
    for label in labels {
        guard label.count <= 63 else { return nil }
        guard label.first != "-", label.last != "-" else { return nil }
        guard label.allSatisfy(isEgressLDH) else { return nil }
        if label.hasPrefix("0x") { return nil }
        if label.count > 1, label.first == "0", label.allSatisfy(isEgressASCIIDigit) {
            return nil
        }
    }
    if labels.allSatisfy({ $0.allSatisfy(isEgressASCIIDigit) }) { return nil }
    return name
}

private func isEgressLDH(_ character: Character) -> Bool {
    guard let ascii = character.asciiValue else { return false }
    return isEgressASCIIDigit(character) || (ascii >= 97 && ascii <= 122) || ascii == 45
}

private func isEgressASCIIDigit(_ character: Character) -> Bool {
    guard let ascii = character.asciiValue else { return false }
    return ascii >= 48 && ascii <= 57
}
