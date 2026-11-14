#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import RVMCP

/// What a caged server can do to reach a credential through a directory
/// clone, a rename, or a symlinked credential, under `MCPSandbox.profile()`'s
/// own text run by `sandbox-exec`. Fake homes only: under `/Users/Shared` or
/// the resolved temp directory, never the real home.
@Suite("MCP cage credentials (live sandbox-exec)")
struct MCPCageCredentialLiveTests {
    /// `clonefile(2)` from Python, so a directory is cloned whole, as the
    /// kernel does it, not file by file as `cp -c -R` does.
    static let cloneFunction = """
        clone() { /usr/bin/python3 -I -c 'import ctypes,sys; l=ctypes.CDLL(None,use_errno=True); \
        sys.exit(0 if l.clonefile(sys.argv[1].encode(),sys.argv[2].encode(),0)==0 else 1)' "$1" "$2"; }
        """

    /// Runs `script` under `profile`, polled, never blocked in `waitid`;
    /// killed after 20 s. Nil when it did not finish.
    private func caged(_ profile: String, _ script: String, _ arguments: [String], in directory: String) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: MCPSandbox.sandboxExec)
        process.arguments = ["-p", profile, "/bin/sh", "-c", Self.cloneFunction + "\n" + script, "sh"] + arguments
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning, Date() < deadline { usleep(20_000) }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            return nil
        }
        return String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
    }

    /// A credential under an ancestor outside every write root: cloning the
    /// ancestor directory (`~/.config` for `~/.config/gh`), or the home,
    /// into the scratch is refused, so the copy that would hold the secret
    /// never exists. A directory inside the scratch still clones. The fake
    /// home is a fresh 0700 directory under `/Users/Shared`: under the temp
    /// directory every ancestor is inside a write root, which the next test
    /// covers.
    @Test(
        .timeLimit(.minutes(1)),
        .enabled(if: access("/Users/Shared", W_OK) == 0, "needs a writable /Users/Shared outside the cage's write roots"))
    func cloningACredentialsAncestorOutsideTheWriteRootsIsRefused() throws {
        let root = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
            .appendingPathComponent("rv-cage-test-\(UUID().uuidString)", isDirectory: true)
        try #require(mkdir(root.path, 0o700) == 0, "could not create \(root.path): errno \(errno)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let gh = home.appendingPathComponent(".config/gh")
        try FileManager.default.createDirectory(at: gh, withIntermediateDirectories: true)
        let marker = "RV-CAGE-SECRET-\(UUID().uuidString)"
        try Data(marker.utf8).write(to: gh.appendingPathComponent("hosts.yml"))
        let temporary = try #require(MCPSandbox.resolveExisting(FileManager.default.temporaryDirectory.path))
        let tmp = URL(fileURLWithPath: temporary).appendingPathComponent("rv-cage-clone-tmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let scratch = home.appendingPathComponent("Library/Caches/rv-mcp/cloner", isDirectory: true)
        #expect(MCPSandbox.createCheckedDirectory(scratch.path))
        let profile = try MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false), scratch: scratch.path, home: home.path,
            configDirectory: home.appendingPathComponent(".config/rv").path, temporaryDirectory: tmp.path).get()
        let script = """
            home="$1"; s="$2"
            clone "$home/.config" "$s/config-clone" && echo CLONE_ANCESTOR_OK
            clone "$home/.config/" "$s/config-clone-slash" && echo CLONE_ANCESTOR_OK
            clone "$home" "$s/home-clone" && echo CLONE_HOME_OK
            /bin/cat "$s/config-clone/gh/hosts.yml" "$s/config-clone-slash/gh/hosts.yml" "$s/home-clone/.config/gh/hosts.yml"
            /bin/cat "$home/.config/gh/hosts.yml"
            /bin/mkdir -p "$s/in/sub" && printf x > "$s/in/sub/f"
            clone "$s/in" "$s/in-clone" && echo CLONE_INSIDE_OK
            echo DONE
            """
        let output = try #require(try caged(profile, script, [home.path, scratch.path], in: scratch.path))
        #expect(output.contains("DONE"), "\(output)")
        #expect(output.contains(marker) == false, "\(output)")
        #expect(output.contains("CLONE_ANCESTOR_OK") == false, "\(output)")
        #expect(output.contains("CLONE_HOME_OK") == false, "\(output)")
        #expect(output.contains("CLONE_INSIDE_OK"), "\(output)")
        #expect(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("config-clone").path) == false)
    }

    /// `~/.aws` a symlink to a directory under the temp directory, itself a
    /// write root, so the profile's symlinked-credential branch is the one
    /// built. The server starts (system binaries are readable), cannot read
    /// the secret through the link or at its target, and cannot clone or
    /// rename the target's ancestor, which lies inside a write root, to read
    /// the secret under a path the deny does not name. Writes in the scratch
    /// still work.
    @Test(.timeLimit(.minutes(1)))
    func aSymlinkedCredentialStaysDeniedAndTheServerStillStarts() throws {
        let temporary = try #require(MCPSandbox.resolveExisting(FileManager.default.temporaryDirectory.path))
        let root = URL(fileURLWithPath: temporary, isDirectory: true)
            .appendingPathComponent("rv-cage-symlink-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let elsewhere = root.appendingPathComponent("elsewhere")
        let keys = elsewhere.appendingPathComponent("aws")
        try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
        let marker = "RV-CAGE-SECRET-\(UUID().uuidString)"
        try Data(marker.utf8).write(to: keys.appendingPathComponent("credentials"))
        try #require(symlink(keys.path, home.appendingPathComponent(".aws").path) == 0)
        let tmp = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let scratch = home.appendingPathComponent("Library/Caches/rv-mcp/linked", isDirectory: true)
        #expect(MCPSandbox.createCheckedDirectory(scratch.path))
        let profile = try MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false), scratch: scratch.path, home: home.path,
            configDirectory: home.appendingPathComponent(".config/rv").path, temporaryDirectory: tmp.path).get()
        let script = """
            home="$1"; s="$2"; elsewhere="$3"
            /bin/echo STARTED
            /bin/cat "$home/.aws/credentials"
            /bin/cat "$elsewhere/aws/credentials"
            clone "$elsewhere" "$s/elsewhere-clone" && echo CLONE_ANCESTOR_OK
            /bin/cat "$s/elsewhere-clone/aws/credentials"
            /bin/mv "$elsewhere" "$s/moved" && echo RENAME_ANCESTOR_OK
            /bin/cat "$s/moved/aws/credentials"
            clone "$home" "$s/home-clone" && echo CLONE_HOME_OK
            printf ok > "$s/written" && /bin/cat "$s/written" > /dev/null && echo SCRATCH_OK
            echo DONE
            """
        let output = try #require(try caged(profile, script, [home.path, scratch.path, elsewhere.path], in: scratch.path))
        #expect(output.contains("STARTED"), "\(output)")
        #expect(output.contains("DONE"), "\(output)")
        #expect(output.contains(marker) == false, "\(output)")
        #expect(output.contains("CLONE_ANCESTOR_OK") == false, "\(output)")
        #expect(output.contains("RENAME_ANCESTOR_OK") == false, "\(output)")
        #expect(output.contains("CLONE_HOME_OK") == false, "\(output)")
        #expect(output.contains("SCRATCH_OK"), "\(output)")
        #expect(FileManager.default.fileExists(atPath: keys.appendingPathComponent("credentials").path))
    }
}
#endif
