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

    /// `rename(2)` and `renamex_np(RENAME_SWAP)` from Python: `mv` onto a
    /// symlink to a directory moves into that directory instead.
    static let renameFunctions = """
        replace() { /usr/bin/python3 -I -c 'import os,sys; os.replace(sys.argv[1], sys.argv[2])' "$1" "$2" 2>/dev/null; }
        swap() { /usr/bin/python3 -I -c 'import ctypes,sys; l=ctypes.CDLL(None,use_errno=True); \
        sys.exit(0 if l.renamex_np(sys.argv[1].encode(),sys.argv[2].encode(),2)==0 else 1)' "$1" "$2"; }
        """

    /// Runs `script` under `profile`, polled, never blocked in `waitid`;
    /// killed after 20 s. Its output is read while it runs, so a full pipe
    /// cannot stall it, and without waiting for end of file: a child another
    /// test spawns meanwhile can inherit the pipe's write end and hold it
    /// open. Nil when it did not finish.
    private func caged(_ profile: String, _ script: String, _ arguments: [String], in directory: String) throws -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: MCPSandbox.sandboxExec)
        process.arguments = ["-p", profile, "/bin/sh", "-c",
            Self.cloneFunction + "\n" + Self.renameFunctions + "\n" + script, "sh"] + arguments
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        let reader = pipe.fileHandleForReading.fileDescriptor
        try #require(fcntl(reader, F_SETFL, fcntl(reader, F_GETFL) | O_NONBLOCK) == 0)
        try process.run()
        var output = Data()
        var buffer = [UInt8](repeating: 0, count: 65536)
        func drain() {
            while true {
                let count = read(reader, &buffer, buffer.count)
                guard count > 0 else { return }
                output.append(contentsOf: buffer[0..<count])
            }
        }
        let deadline = Date().addingTimeInterval(20)
        while process.isRunning, Date() < deadline {
            drain()
            usleep(20_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
            return nil
        }
        // The script ran its commands one after another, so everything it
        // wrote is in the pipe once it has exited.
        drain()
        return String(decoding: output, as: UTF8.self)
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

    /// `~/.aws` → `x/aws`, and `x` itself a symlink to `y`, all under the
    /// temp directory (a write root). The server starts and cannot read the
    /// secret; it cannot remove, rename, replace or swap the link `x`, which
    /// would point `~/.aws` at a directory it controls. The link is the
    /// same afterwards.
    @Test(.timeLimit(.minutes(1)))
    func aSymlinkedDirectoryAboveACredentialCannotBeSwapped() throws {
        let temporary = try #require(MCPSandbox.resolveExisting(FileManager.default.temporaryDirectory.path))
        let root = URL(fileURLWithPath: temporary, isDirectory: true)
            .appendingPathComponent("rv-cage-ancestor-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let keys = root.appendingPathComponent("y/aws")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
        let marker = "RV-CAGE-SECRET-\(UUID().uuidString)"
        try Data(marker.utf8).write(to: keys.appendingPathComponent("credentials"))
        let link = root.appendingPathComponent("x")
        try #require(symlink(root.appendingPathComponent("y").path, link.path) == 0)
        try #require(symlink(link.appendingPathComponent("aws").path, home.appendingPathComponent(".aws").path) == 0)
        let tmp = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let scratch = home.appendingPathComponent("Library/Caches/rv-mcp/swapper", isDirectory: true)
        #expect(MCPSandbox.createCheckedDirectory(scratch.path))
        let profile = try MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false), scratch: scratch.path, home: home.path,
            configDirectory: home.appendingPathComponent(".config/rv").path, temporaryDirectory: tmp.path).get()
        let script = """
            home="$1"; s="$2"; x="$3"
            /bin/echo STARTED
            /bin/cat "$home/.aws/credentials" 2>/dev/null
            /bin/mkdir -p "$s/mine/aws" && /bin/ln -s "$s/mine" "$s/evil"
            /bin/rm "$x" 2>/dev/null && echo UNLINK_OK
            /bin/mv "$x" "$s/moved" 2>/dev/null && echo RENAME_OK
            replace "$s/evil" "$x" && echo REPLACE_OK
            swap "$s/evil" "$x" && echo SWAP_OK
            printf planted > "$home/.aws/planted" 2>/dev/null && echo PLANTED
            echo DONE
            """
        let output = try #require(try caged(profile, script, [home.path, scratch.path, link.path], in: scratch.path))
        #expect(output.contains("STARTED"), "\(output)")
        #expect(output.contains("DONE"), "\(output)")
        #expect(output.contains(marker) == false, "\(output)")
        for refused in ["UNLINK_OK", "RENAME_OK", "REPLACE_OK", "SWAP_OK", "PLANTED"] {
            #expect(output.contains(refused) == false, "\(refused): \(output)")
        }
        #expect(MCPSandbox.readLink(link.path) == root.appendingPathComponent("y").path)
        #expect(FileManager.default.fileExists(atPath: keys.appendingPathComponent("credentials").path))
    }

    /// Two servers, each in its own `sandbox-exec` of the same profile, as
    /// serve starts them: the second cannot read the first's arguments and
    /// environment (`KERN_PROCARGS2`, where rv puts a server's `secrets`),
    /// though this process can. It still reads its own, and a child it
    /// started.
    @Test(.timeLimit(.minutes(1)))
    func aCagedServerCannotReadASiblingServersEnvironment() throws {
        let probe = try mcpProbe()
        let temporary = try #require(MCPSandbox.resolveExisting(FileManager.default.temporaryDirectory.path))
        let root = URL(fileURLWithPath: temporary, isDirectory: true)
            .appendingPathComponent("rv-cage-procargs-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let tmp = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let scratch = home.appendingPathComponent("Library/Caches/rv-mcp/reader", isDirectory: true)
        #expect(MCPSandbox.createCheckedDirectory(scratch.path))
        let profile = try MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false), scratch: scratch.path, home: home.path,
            configDirectory: home.appendingPathComponent(".config/rv").path, temporaryDirectory: tmp.path).get()

        // The first server waits on its stdin until the test ends.
        let sibling = Process()
        sibling.executableURL = URL(fileURLWithPath: MCPSandbox.sandboxExec)
        sibling.arguments = ["-p", profile, probe.path, "stderr", "1", "closed"]
        sibling.environment = ["HOME": "/rv-procargs-sibling", "PATH": "/usr/bin:/bin"]
        let input = Pipe()
        sibling.standardInput = input
        sibling.standardOutput = FileHandle.nullDevice
        sibling.standardError = FileHandle.nullDevice
        try sibling.run()
        defer {
            try? input.fileHandleForWriting.close()
            if sibling.isRunning { kill(sibling.processIdentifier, SIGKILL) }
            sibling.waitUntilExit()
        }
        // sandbox-exec execs the probe in place: wait until it has.
        let pid = sibling.processIdentifier
        let deadline = Date().addingTimeInterval(10)
        var fromHere = ""
        while Date() < deadline {
            fromHere = MCPPlaceholderLiveTests.procargsFromHere(probe, pid, in: root)
            if fromHere.hasSuffix(" home=yes") { break }
            usleep(50_000)
        }
        try #require(fromHere.hasSuffix(" home=yes"), "the sibling never showed its environment here: \(fromHere)")

        let script = """
            p="$1"; sibling="$2"
            echo "sibling: $("$p" procargs "$sibling")"
            echo "self: $("$p" procargs self)"
            /usr/bin/mkfifo "$PWD/hold"
            HOME=/rv-procargs-child "$p" stderr 1 closed < "$PWD/hold" > /dev/null 2>&1 &
            child=$!
            exec 3> "$PWD/hold"
            /bin/sleep 0.5
            echo "child: $("$p" procargs $child)"
            exec 3>&-
            wait $child
            echo DONE
            """
        let output = try #require(try caged(profile, script, [probe.path, String(pid)], in: scratch.path))
        #expect(output.contains("DONE"), "\(output)")
        #expect(output.contains("sibling: failed errno=\(EPERM)"), "\(output)")
        #expect(output.contains("self: ok argc="), "\(output)")
        #expect(output.contains("child: ok argc="), "\(output)")
    }
}
#endif
