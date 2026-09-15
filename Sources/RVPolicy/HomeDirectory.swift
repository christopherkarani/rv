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
}
