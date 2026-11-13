import Foundation

/// Curated gateway defaults for well-known secret names, so
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

    /// Gateway defaults for `name`, or nil when rv knows nothing about it.
    /// Names match exactly; the caller already validated the variable grammar.
    public static func gateway(for name: String) -> Gateway? {
        switch name {
        case "OPENAI_API_KEY":
            Gateway(
                upstream: "https://api.openai.com/v1", baseURLEnv: "OPENAI_BASE_URL",
                placeholderPrefix: "sk-", allow: modelAPI)
        case "ANTHROPIC_API_KEY":
            Gateway(
                upstream: "https://api.anthropic.com", baseURLEnv: "ANTHROPIC_BASE_URL",
                placeholderPrefix: "sk-ant-", allow: modelAPI)
        case "STRIPE_SECRET_KEY":
            // A secret key can move money; reads only unless widened.
            Gateway(
                upstream: "https://api.stripe.com", baseURLEnv: "STRIPE_API_BASE",
                placeholderPrefix: "sk-", allow: [.preset(.readOnly)])
        case "GITHUB_TOKEN":
            Gateway(
                upstream: "https://api.github.com", baseURLEnv: "GITHUB_API_URL",
                placeholderPrefix: "", allow: [.preset(.githubRead)])
        case "GH_TOKEN":
            Gateway(
                upstream: "https://api.github.com", baseURLEnv: "GH_API_URL",
                placeholderPrefix: "", allow: [.preset(.githubRead)])
        case "VERCEL_TOKEN":
            // Deploys and deletes need an explicit widening.
            Gateway(
                upstream: "https://api.vercel.com", baseURLEnv: "VERCEL_BASE_URL",
                placeholderPrefix: "", allow: [.preset(.readOnly)])
        default:
            nil
        }
    }
}
