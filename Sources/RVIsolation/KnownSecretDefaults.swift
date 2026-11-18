import Foundation

/// Curated gateway defaults for well-known secret names, from the provider
/// catalog (`ProviderCatalog.shipped`), so
/// `rv secrets set OPENAI_API_KEY` needs no flags. Explicit `--gateway`,
/// `--base-url-env`, `--placeholder-prefix`, and `--environment` always win;
/// this table only fills in what the flags leave out. Upstreams are fixed
/// origins the value may be sent to; nothing here grants network access.
/// Allow rules are least privilege: the narrowest scope the everyday client
/// needs, never every method and path. An explicit `--allow` replaces them.
public enum KnownSecretDefaults {
    public struct Gateway: Sendable, Equatable {
        public var upstream: String
        public var baseURLEnv: String
        public var placeholderPrefix: String
        /// Methods and paths the placeholder may be spent on. Never empty.
        public var allow: [GatewayAllowance]

        public init(upstream: String, baseURLEnv: String, placeholderPrefix: String, allow: [GatewayAllowance]) {
            self.upstream = upstream
            self.baseURLEnv = baseURLEnv
            self.placeholderPrefix = placeholderPrefix
            self.allow = allow
        }
    }

    /// GET and POST under `/v1`: model calls and listings, no deletes.
    static let modelAPI: [GatewayAllowance] = [
        .rule(GatewayAccessRule(methods: ["GET", "POST"], path: "/v1/**", query: [:])),
    ]

    /// The only names a bare `rv secrets set` infers a gateway for. Other
    /// catalog credentials (NPM_TOKEN, TWINE_PASSWORD, ...) exist to be
    /// scoped by `--provider`; inferring a binding for them would grant
    /// what their profile refuses, so they get no default.
    public static let names: Set<String> = [
        "OPENAI_API_KEY", "ANTHROPIC_API_KEY", "STRIPE_SECRET_KEY", "GITHUB_TOKEN", "GH_TOKEN", "VERCEL_TOKEN",
    ]

    /// What a bare `rv secrets set` of a well-known name may be spent on.
    /// Nil for a name outside `names`: no rule is never "every request".
    static func allowance(for name: String) -> [GatewayAllowance]? {
        switch name {
        case "OPENAI_API_KEY", "ANTHROPIC_API_KEY":
            modelAPI
        case "STRIPE_SECRET_KEY":
            // A secret key can move money; reads only unless widened.
            [.preset(.readOnly)]
        case "GITHUB_TOKEN", "GH_TOKEN":
            [.preset(.githubRead)]
        case "VERCEL_TOKEN":
            // Deploys and deletes need an explicit widening.
            [.preset(.readOnly)]
        default:
            nil
        }
    }

    /// Gateway defaults for `name`, or nil when rv knows nothing about it.
    /// Names match exactly; the caller already validated the variable grammar.
    /// Only `names` are answered. The upstream and variable names are read
    /// from the provider catalog's credentials; the allow rules are the
    /// least-privilege ones above, not the profile's (those are what
    /// `--provider` applies). An invalid catalog answers nil for every name.
    public static func gateway(
        for name: String, catalog: Result<ProviderCatalog, ProviderCatalogError> = ProviderCatalog.shipped
    ) -> Gateway? {
        guard names.contains(name), let allow = allowance(for: name), case .success(let catalog) = catalog,
            let found = catalog.credential(for: name)
        else { return nil }
        return Gateway(
            upstream: found.endpoint.upstream.absoluteString, baseURLEnv: found.credential.baseURLEnv,
            placeholderPrefix: found.credential.placeholderPrefix, allow: allow)
    }

    /// Why a bare `rv secrets set` of a well-known name got no default: the
    /// catalog it reads is invalid. Nil when the name is not well-known or
    /// the catalog loads.
    public static func catalogFailure(
        for name: String, catalog: Result<ProviderCatalog, ProviderCatalogError> = ProviderCatalog.shipped
    ) -> String? {
        guard names.contains(name), case .failure(let error) = catalog else { return nil }
        return error.message
    }
}
