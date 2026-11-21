import Foundation

/// Writes `secret.allow_paths` / `secret.bless_paths` into `config.json`
/// as the owner would by hand: rv has no writer for either key.
enum SecretConfigFixture {
    static func write(allowPaths: [String]? = nil, blessPaths: [String]? = nil, to file: URL) throws {
        var secret: [String: Any] = [:]
        if let allowPaths { secret["allow_paths"] = allowPaths }
        if let blessPaths { secret["bless_paths"] = blessPaths }
        try JSONSerialization.data(withJSONObject: ["secret": secret], options: [.sortedKeys]).write(to: file)
    }
}
