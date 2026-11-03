import RVIsolation

extension SecretDefinition {
    /// Applies a `--refresh` edit. A refusal carries the `secrets.json is invalid:`
    /// text, and the caller returns it before any Keychain write.
    mutating func applyRefresh(_ interval: SecretRefreshInterval?) -> CommandFailure? {
        do {
            try setRefresh(interval)
            return nil
        } catch {
            return CommandFailure(SecretsConfigurationError.invalid(error.reason).message)
        }
    }
}
