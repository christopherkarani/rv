import Foundation

/// Curated gateway defaults for well-known secret names, from the provider
/// catalog (`ProviderCatalog.shipped`), so
/// `rv secrets set OPENAI_API_KEY` needs no flags. Explicit `--gateway`,
/// `--base-url-env`, `--placeholder-prefix`, and `--environment` always win;
/// this table only fills in what the flags leave out. Upstreams are fixed
/// origins the value may be sent to; nothing here grants network access.
public enum KnownSecretDefaults {
    public struct Gateway: Sendable, Equatable {
        public var upstream: String
        public var baseURLEnv: String
        public var placeholderPrefix: String

        public init(upstream: String, baseURLEnv: String, placeholderPrefix: String) {
            self.upstream = upstream
            self.baseURLEnv = baseURLEnv
            self.placeholderPrefix = placeholderPrefix
        }
    }

    /// Gateway defaults for `name`, or nil when rv knows nothing about it.
    /// Names match exactly; the caller already validated the variable grammar.
    /// Read from the provider catalog's credentials: only the upstream and
    /// variable names, never the profile's allow rules, so a bare
    /// `rv secrets set GITHUB_TOKEN` keeps allowing any method and path.
    /// An invalid catalog answers nil for every name, so nothing is inferred.
    public static func gateway(
        for name: String, catalog: Result<ProviderCatalog, ProviderCatalogError> = ProviderCatalog.shipped
    ) -> Gateway? {
        guard case .success(let catalog) = catalog, let found = catalog.credential(for: name) else { return nil }
        return Gateway(
            upstream: found.endpoint.upstream.absoluteString, baseURLEnv: found.credential.baseURLEnv,
            placeholderPrefix: found.credential.placeholderPrefix)
    }
}
