import Foundation
import RVDomain

/// The operator HOME newtype: root of `~/.config/rv`.
/// Same identity as Domain `HomePath`. Absence is `HomeDirectory?`.
public typealias HomeDirectory = HomePath

extension HomeDirectory {
    /// The single sanctioned environment read. nil when HOME is unset or empty.
    /// Any other non-empty value passes unchanged (`HomePath` is a wire type);
    /// callers that build filesystem paths use `processValidatedHome()` or
    /// `processConfigDirectory()`, which also require an absolute, NUL-free HOME.
    public static func process() -> HomeDirectory? {
        HomeDirectory(validating: ProcessInfo.processInfo.environment["HOME"] ?? "")
    }

    /// `process()` narrowed to an absolute, NUL-free path, as a raw string for
    /// APIs that take one (e.g. `SecretResolver.live(home:)`). nil otherwise.
    public static func processValidatedHome() -> String? {
        guard let home = process()?.rawValue, isUsableHome(home) else { return nil }
        return home
    }

    /// `<home>/.config/rv` for an absolute, NUL-free `home`; nil otherwise.
    /// Pure: never reads the environment.
    public static func configRoot(for home: String) -> URL? {
        guard isUsableHome(home), let validated = HomeDirectory(validating: home) else { return nil }
        return RVPolicyPaths.configDirectory(home: validated)
    }

    /// `~/.config/rv` from `processValidatedHome()`; nil when HOME is unusable.
    public static func processConfigDirectory() -> URL? {
        processValidatedHome().flatMap(configRoot(for:))
    }

    private static func isUsableHome(_ home: String) -> Bool {
        home.hasPrefix("/") && !home.contains("\0")
    }
}
