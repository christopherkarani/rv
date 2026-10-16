import Foundation

/// What a CONNECT should do once the existing egress policy has already
/// allowed it. Termination is only for the exact host a secret's gateway
/// upstream names. Every other host stays a blind tunnel. This does not
/// listen, mint a certificate, or change `EgressProxy`; that integration
/// waits until the proxy can host it without a second, weaker filter.
enum TransparentConnect: Sendable, Equatable {
    case tunnel
    case terminate
}

enum TransparentHTTPS {
    static func decision(host: String, secretUpstreams: [String]) -> TransparentConnect {
        guard let name = canonical(host) else { return .tunnel }
        return secretUpstreams.contains { canonical($0) == name } ? .terminate : .tunnel
    }

    /// A DNS name with at least two labels. Addresses and a single label
    /// (including `localhost`) never terminate.
    static func canonical(_ raw: String) -> String? {
        var name = raw.trimmingCharacters(in: .whitespaces).lowercased()
        if name.hasSuffix(".") { name.removeLast() }
        guard name.isEmpty == false, name.contains("..") == false, name.utf8.count <= 253 else { return nil }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard labels.count >= 2, labels.allSatisfy(label) else { return nil }
        guard labels.contains(where: { $0.allSatisfy(\.isNumber) == false }) else { return nil }
        return labels.joined(separator: ".")
    }

    private static func label(_ text: String) -> Bool {
        (1...63).contains(text.count) && text.first != "-" && text.last != "-"
            && text.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
    }
}
