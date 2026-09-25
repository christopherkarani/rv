/// CONNECT policy for the filtering egress proxy.
///
/// Contained processes reach only loopback sockets (seatbelt `localhost`
/// rule). Agent runtimes talk to a loopback proxy that dials only
/// allowlisted HTTPS destinations and resolves names itself; clients never
/// supply IPs. Matching is exact hostname only in v1: no subdomain
/// wildcards, no IP literals, no userinfo, port 443 only. Everything else
/// fails closed. Loopback targets are not egress and are admitted
/// separately so local gateways and loopback MCP servers keep working.
public struct EgressHostPolicy: Sendable, Equatable {
    public static let httpsPort = 443

    /// Agent API defaults, each observed from a real agent run: claude and
    /// codex via api.anthropic.com / api.openai.com, ChatGPT-plan codex via
    /// chatgpt.com (backend) and auth.openai.com (OAuth refresh), muse via
    /// api.meta.ai with OAuth at auth.meta.com, opencode via opencode.ai
    /// with its model catalog at models.opencode.ai. Other providers arrive
    /// with user-configured lists later.
    public static let agentAPIs = EgressHostPolicy(
        allowedHosts: [
            "api.anthropic.com", "api.openai.com", "chatgpt.com",
            "auth.openai.com", "api.meta.ai", "auth.meta.com",
            "opencode.ai", "models.opencode.ai",
        ]
    )

    public var allowedHosts: Set<String>
    public var allowedPort: Int

    public init(allowedHosts: Set<String>, allowedPort: Int = httpsPort) {
        self.allowedHosts = allowedHosts
        self.allowedPort = allowedPort
    }

    public func allows(host: String, port: Int) -> Bool {
        guard port == allowedPort else { return false }
        guard let name = canonicalEgressDNSName(host) else { return false }
        return allowedHosts.contains(name)
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
