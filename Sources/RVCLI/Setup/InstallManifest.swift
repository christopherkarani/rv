import Foundation

/// Every file install.sh places outside rv's config directory, by name, so
/// `rv uninstall` removes exactly what rv owns. `InstallManifestDriftTests`
/// parses install.sh and fails when it installs a name missing here.
enum InstallManifest {
    /// Regular files install.sh writes into the bin dir (`~/.local/bin`).
    /// `rv-judge` and `rv-mcp-custodian` are not installed there today
    /// (the custodian ships inside RVApprovals.app) but carry rv's name and
    /// were staged there by earlier dev installs; nothing else uses them.
    static let binFiles: [String] = [
        "rv", "rv-cli", "rvd", "rv-workspace-host",
        "rv-pty-claim", "rv-microvm", "rv-guest-relay", "rv-macvm", "rv-macvm-agent",
        "rv-isolation-exec", "libswiftCompatibilitySpan.dylib",
        "rv-judge", "rv-mcp-custodian",
    ]

    /// Resource bundles install.sh copies into the bin dir (`*_RVPacks.*`
    /// for this package, named `rv`).
    static let binDirectories: [String] = ["rv_RVPacks.bundle", "rv_RVPacks.resources"]

    /// Linux: install.sh records the Swift runtime `.so` names it copied
    /// beside the binaries here, one per line. Those names are generic
    /// (`libFoundation.so`), so only a recorded name is ever removed.
    static let swiftLibsListName = ".rv-swiftlibs"

    /// Staging names install.sh uses while swapping a file into place
    /// (`.<name>.installing`); an interrupted install can leave them behind.
    static func stagingName(_ name: String) -> String { ".\(name).installing" }

    /// Absolute paths in `binDirectory` that rv owns, given the recorded
    /// Swift library names.
    static func ownedBinPaths(binDirectory: String, recordedLibraries: [String]) -> [String] {
        let names = binFiles + binDirectories + recordedLibraries.filter(isLibraryName) + [swiftLibsListName]
        return names.flatMap { [binDirectory + "/" + $0, binDirectory + "/" + stagingName($0)] }
    }

    /// The recorded list, or nothing when it is absent or unreadable.
    static func recordedLibraries(binDirectory: String, fileManager: FileManager) -> [String] {
        guard let data = fileManager.contents(atPath: binDirectory + "/" + swiftLibsListName),
              let text = String(data: data, encoding: .utf8)
        else { return [] }
        return text.split(whereSeparator: \.isNewline).map(String.init).filter(isLibraryName)
    }

    /// A bare shared-library file name (`libX.so`, `libX.so.5`): never a
    /// path, so a tampered list cannot name a file outside the bin dir.
    static func isLibraryName(_ name: String) -> Bool {
        guard name.hasPrefix("lib"), name.contains(".so"), name.contains("/") == false,
              name != ".", name != ".."
        else { return false }
        return name.allSatisfy { $0.isLetter || $0.isNumber || "._+-".contains($0) }
    }
}
