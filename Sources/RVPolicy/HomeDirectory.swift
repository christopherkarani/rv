import Foundation
import RVDomain

/// The operator HOME newtype: root of `~/.config/rv`.
/// Same identity as Domain `HomePath`. Absence is `HomeDirectory?`.
public typealias HomeDirectory = HomePath

extension HomeDirectory {
    /// The single sanctioned environment read. nil when HOME is unset or empty.
    public static func process() -> HomeDirectory? {
        HomeDirectory(validating: ProcessInfo.processInfo.environment["HOME"] ?? "")
    }

    /// The process HOME when absolute and NUL-free, else nil.
    public static func processValidatedHome() -> String? {
        guard let home = ProcessInfo.processInfo.environment["HOME"],
              home.hasPrefix("/"), !home.contains("\0") else { return nil }
        return home
    }

    /// `<home>/.config/rv` for an absolute, NUL-free `home`; nil otherwise.
    public static func configRoot(for home: String) -> URL? {
        guard home.hasPrefix("/"), !home.contains("\0") else { return nil }
        return URL(fileURLWithPath: home, isDirectory: true)
            .appendingPathComponent(".config", isDirectory: true)
            .appendingPathComponent("rv", isDirectory: true)
    }

    /// `~/.config/rv` from the process HOME; nil when HOME is unusable.
    public static func processConfigDirectory() -> URL? {
        processValidatedHome().flatMap(configRoot(for:))
    }
}
