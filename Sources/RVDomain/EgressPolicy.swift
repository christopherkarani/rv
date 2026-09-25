/// CONNECT policy for the filtering egress proxy.
///
/// Contained processes get no sockets. Agent runtimes will reach a
/// localhost proxy that dials only allowlisted HTTPS destinations and
/// resolves names itself; clients never supply IPs. Matching is exact
/// hostname only in v1: no subdomain wildcards, no IP literals, no
/// userinfo, port 443 only. Everything else fails closed.
public struct EgressHostPolicy: Sendable, Equatable {
    public static let httpsPort = 443

    /// Agent API defaults. Claude and opencode (default providers) need only
    /// these; other providers arrive with user-configured lists later.
    public static let agentAPIs = EgressHostPolicy(
        allowedHosts: ["api.anthropic.com", "api.openai.com"]
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
