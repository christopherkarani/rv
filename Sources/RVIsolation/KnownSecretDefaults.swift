import Foundation

/// Curated gateway defaults for well-known secret names, so
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
    public static func gateway(for name: String) -> Gateway? {
        switch name {
        case "OPENAI_API_KEY":
            Gateway(
                upstream: "https://api.openai.com/v1", baseURLEnv: "OPENAI_BASE_URL",
                placeholderPrefix: "sk-")
        case "ANTHROPIC_API_KEY":
            Gateway(
                upstream: "https://api.anthropic.com", baseURLEnv: "ANTHROPIC_BASE_URL",
                placeholderPrefix: "sk-ant-")
        case "STRIPE_SECRET_KEY":
            Gateway(
                upstream: "https://api.stripe.com", baseURLEnv: "STRIPE_API_BASE",
                placeholderPrefix: "sk-")
        case "GITHUB_TOKEN":
            Gateway(
                upstream: "https://api.github.com", baseURLEnv: "GITHUB_API_URL",
                placeholderPrefix: "")
        case "GH_TOKEN":
            Gateway(
                upstream: "https://api.github.com", baseURLEnv: "GH_API_URL",
                placeholderPrefix: "")
        case "VERCEL_TOKEN":
            Gateway(
                upstream: "https://api.vercel.com", baseURLEnv: "VERCEL_BASE_URL",
                placeholderPrefix: "")
        default:
            nil
        }
    }
}
