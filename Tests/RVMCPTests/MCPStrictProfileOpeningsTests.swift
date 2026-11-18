#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import RVMCP

/// The openings a missing credential name adds (every ancestor of where a
/// link could send it) are denied only where the cage could create that
/// name: some entry on the credential's path lies inside a write root.
/// Outside every write root, `(deny file-write*)` already refuses the create.
extension MCPStrictProfileTests {
    /// A fresh 0700 directory under `/Users/Shared`, outside every write root.
    private static func sharedRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
            .appendingPathComponent("rv-cage-test-\(UUID().uuidString)", isDirectory: true)
        try #require(mkdir(root.path, 0o700) == 0, "could not create \(root.path): errno \(errno)")
        return root
    }

    /// The credential deny line of `home`'s profile.
    private static func credentialDeny(
        home: String, temporary: String, writable: [String] = []
    ) throws -> String {
        let scratch = home + "/Library/Caches/rv-mcp/opener"
        try FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        let text = try MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false, writable: writable), scratch: scratch, home: home,
            configDirectory: home + "/.config/rv", temporaryDirectory: temporary).get()
        let line = try #require(text.split(separator: "\n").first { $0.hasPrefix("(deny file-read* file-write* ") })
        return String(line)
    }

    /// `~/.config` linked into a dotfiles directory with `gcloud` and
    /// `opencode` missing, and `~/.ssh` linked to an unmounted volume: the
    /// credentials are denied where they would be, and nothing above them
    /// (`/Users`, the home, the dotfiles directory, `/Volumes`) is.
    @Test(
        .timeLimit(.minutes(1)),
        .enabled(if: access("/Users/Shared", W_OK) == 0, "needs a writable /Users/Shared outside the cage's write roots"))
    func aDotfilesLinkedConfigDeniesTheCredentialsAndNothingAboveThem() throws {
        let root = try Self.sharedRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.path + "/home"
        let config = home + "/dotfiles/config"
        try FileManager.default.createDirectory(atPath: config + "/gh", withIntermediateDirectories: true)
        try #require(symlink(config, home + "/.config") == 0)
        let volume = "/Volumes/rv-no-such-\(UUID().uuidString)"
        try #require(symlink(volume + "/ssh", home + "/.ssh") == 0)
        let temporary = try Self.resolvedTemporaryRoot("rv-openings-tmp")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let deny = try Self.credentialDeny(home: home, temporary: temporary.path)
        for denied in [config + "/gh", config + "/gcloud", config + "/opencode", home + "/.config/gh", volume + "/ssh"] {
            #expect(deny.contains("(subpath \"\(denied)\")"), "\(denied)")
        }
        for open in ["/Users", "/Users/Shared", root.path, home, home + "/dotfiles", config, "/gcloud", "/opencode",
                     "/Volumes", volume, "/ssh"] {
            #expect(deny.contains("(subpath \"\(open)\")") == false, "\(open)")
        }
    }

    /// Where an entry on the credential's path is inside a write root, the
    /// cage could create the missing name there, and every opening is still
    /// denied: the dotfiles shape with `sandbox.writable: ["~/"]`, the same
    /// home under the temp directory, `~/.config` through a link `x` inside
    /// a `sandbox.writable` directory, and a dangling `~/.ssh` into the temp
    /// directory.
    @Test(
        .timeLimit(.minutes(1)),
        .enabled(if: access("/Users/Shared", W_OK) == 0, "needs a writable /Users/Shared outside the cage's write roots"))
    func openingsStayWhereTheCageCouldCreateTheMissingName() throws {
        let shared = try Self.sharedRoot()
        defer { try? FileManager.default.removeItem(at: shared) }
        let temporary = try Self.resolvedTemporaryRoot("rv-openings-kept")
        try FileManager.default.createDirectory(at: temporary.appendingPathComponent("tmp"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let tmp = temporary.path + "/tmp"
        func dotfilesHome(_ home: String) throws {
            try FileManager.default.createDirectory(atPath: home + "/dotfiles/config/gh", withIntermediateDirectories: true)
            try #require(symlink(home + "/dotfiles/config", home + "/.config") == 0)
        }
        var cases: [(name: String, home: String, writable: [String], credential: String)] = []
        let widened = shared.path + "/widened"
        try dotfilesHome(widened)
        cases.append(("writable ~/", widened, ["~/"], widened + "/.config/gcloud"))
        let underTemp = temporary.path + "/home"
        try dotfilesHome(underTemp)
        cases.append(("home under temp", underTemp, [], underTemp + "/.config/gcloud"))
        let linked = shared.path + "/linked"
        let w = shared.path + "/w"
        try FileManager.default.createDirectory(atPath: w + "/y/config/gh", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: linked, withIntermediateDirectories: true)
        try #require(symlink(w + "/y", w + "/x") == 0)
        try #require(symlink(w + "/x/config", linked + "/.config") == 0)
        cases.append(("link inside sandbox.writable", linked, [w], linked + "/.config/gcloud"))
        let dangling = shared.path + "/dangling"
        try FileManager.default.createDirectory(atPath: dangling, withIntermediateDirectories: true)
        try #require(symlink(temporary.path + "/no-such/keys", dangling + "/.ssh") == 0)
        cases.append(("dangling into temp", dangling, [], dangling + "/.ssh"))
        for shape in cases {
            let openings = MCPSandbox.missingSymlinkOpenings(shape.credential)
            try #require(openings.isEmpty == false, "\(shape.name): the shape has no openings")
            let deny = try Self.credentialDeny(home: shape.home, temporary: tmp, writable: shape.writable)
            for opening in openings {
                #expect(deny.contains("(subpath \"\(opening)\")"), "\(shape.name): \(opening)")
            }
        }
    }
}
#endif
