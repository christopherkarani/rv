import Foundation

enum CompanionPresence: Equatable, Sendable {
    case installed
    case absent

    var keepAlive: Bool {
        switch self {
        case .installed: true
        case .absent: false
        }
    }
}

protocol CompanionPresenceDetecting: Sendable {
    func presence() -> CompanionPresence
}

struct FixedCompanionPresence: CompanionPresenceDetecting {
    var value: CompanionPresence

    func presence() -> CompanionPresence { value }
}

/// Looks for `rv.app` under `/Applications` and `$HOME/Applications`.
/// Bundle id must be `dev.rv.*` and must not be the Mach service `dev.rv.evaluate`.
/// CLI paths such as `~/.local/bin/rv` and `/Applications/rv/bin/rv` are not the app.
struct FilesystemCompanionPresence: CompanionPresenceDetecting {
    var searchRoots: [URL]
    var fileManager: FileManager

    init(searchRoots: [URL], fileManager: FileManager = .default) {
        self.searchRoots = searchRoots
        self.fileManager = fileManager
    }

    init(home: String, fileManager: FileManager = .default) {
        self.init(searchRoots: Self.defaultSearchRoots(home: home), fileManager: fileManager)
    }

    static func defaultSearchRoots(home: String) -> [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: home, isDirectory: true)
                .appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    func presence() -> CompanionPresence {
        for root in searchRoots {
            let app = root.appendingPathComponent("rv.app", isDirectory: true)
            if isCompanionApp(at: app) {
                return .installed
            }
        }
        return .absent
    }

    private func isCompanionApp(at url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              isDirectory.boolValue
        else {
            return false
        }
        // Best-effort symlink handling: fileExists follows symlinks. A symlink to a
        // valid app bundle is treated as installed; canonicalization is not performed
        // because /Applications is not attacker-controlled in the v1 threat model.
        let info = url.appendingPathComponent("Contents/Info.plist")
        guard let data = fileManager.contents(atPath: info.path),
              let object = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let plist = object as? [String: Any],
              let bundleId = plist["CFBundleIdentifier"] as? String
        else {
            return false
        }
        return Self.isCompanionBundleId(bundleId)
    }

    /// `dev.rv.*` family, excluding the LaunchAgent Mach name.
    /// P2-3: also exclude `dev.rv.evaluate.*` prefixes (e.g. `dev.rv.evaluate.foo`)
    /// so a suffixed service name cannot masquerade as the companion.
    static func isCompanionBundleId(_ bundleId: String) -> Bool {
        guard bundleId.hasPrefix("dev.rv.") else { return false }
        guard bundleId != "dev.rv." else { return false }
        guard bundleId != "dev.rv.evaluate" else { return false }
        guard bundleId.hasPrefix("dev.rv.evaluate.") == false else { return false }
        return true
    }
}

// FileManager is not Sendable, but FilesystemCompanionPresence is used
// synchronously during setup (single-threaded, no concurrent mutation).
// Mark @unchecked Sendable to satisfy CompanionPresenceDetecting: Sendable.
extension FilesystemCompanionPresence: @unchecked Sendable {}
