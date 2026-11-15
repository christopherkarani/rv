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

    /// `~/.ssh` → `W/l/../keys`, `l` a symlink to `W/z/q`, all in a write
    /// root: the key directory is `W/z/keys`, reached through `l`, which the
    /// `..` drops from the spelling. Replacing `l` with a link to the scratch
    /// would move `~/.ssh` to `scratch/keys`; `l` cannot be removed,
    /// renamed, replaced or swapped, and the key stays unread.
    @Test(.timeLimit(.minutes(1)))
    func aLinkADotDotDropsFromACredentialTargetCannotBeSwapped() throws {
        let temporary = try #require(MCPSandbox.resolveExisting(FileManager.default.temporaryDirectory.path))
        let root = URL(fileURLWithPath: temporary, isDirectory: true)
            .appendingPathComponent("rv-cage-dotdot-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let keys = root.appendingPathComponent("z/keys")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("z/q"), withIntermediateDirectories: true)
        let marker = "RV-CAGE-SECRET-\(UUID().uuidString)"
        try Data(marker.utf8).write(to: keys.appendingPathComponent("id_rsa"))
        let link = root.appendingPathComponent("l")
        try #require(symlink(root.appendingPathComponent("z/q").path, link.path) == 0)
        try #require(symlink(link.path + "/../keys", home.appendingPathComponent(".ssh").path) == 0)
        let tmp = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let scratch = home.appendingPathComponent("Library/Caches/rv-mcp/dotdot", isDirectory: true)
        #expect(MCPSandbox.createCheckedDirectory(scratch.path))
        let profile = try MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false), scratch: scratch.path, home: home.path,
            configDirectory: home.appendingPathComponent(".config/rv").path, temporaryDirectory: tmp.path).get()
        let script = """
            home="$1"; s="$2"; l="$3"
            /bin/echo STARTED
            /bin/cat "$home/.ssh/id_rsa" 2>/dev/null
            /bin/mkdir -p "$s/mine/q" "$s/keys" && /bin/ln -s "$s/mine/q" "$s/newl"
            /bin/rm "$l" 2>/dev/null && echo UNLINK_OK
            /bin/mv "$l" "$s/moved" 2>/dev/null && echo RENAME_OK
            replace "$s/newl" "$l" && echo REPLACE_OK
            swap "$s/newl" "$l" && echo SWAP_OK
            echo DONE
            """
        let output = try #require(try caged(profile, script, [home.path, scratch.path, link.path], in: scratch.path))
        #expect(output.contains("STARTED"), "\(output)")
        #expect(output.contains("DONE"), "\(output)")
        #expect(output.contains(marker) == false, "\(output)")
        for refused in ["UNLINK_OK", "RENAME_OK", "REPLACE_OK", "SWAP_OK"] {
            #expect(output.contains(refused) == false, "\(refused): \(output)")
        }
        #expect(MCPSandbox.readLink(link.path) == root.appendingPathComponent("z/q").path)
    }

    /// `~/.ssh -> W/b/keys`, `W/b -> Z/q`, `Z/q -> Y/r`, `Y/r/keys` real,
    /// all in a write root: the inner link `Z/q`, reached only through the
    /// outer link `W/b`, is named, so it cannot be removed, renamed or
    /// replaced to point `~/.ssh` at a directory the cage controls. The key
    /// stays unread and `Z/q` is unchanged.
    @Test(.timeLimit(.minutes(1)))
    func aDirectoryLinkReachedThroughAnotherLinkCannotBeSwapped() throws {
        let temporary = try #require(MCPSandbox.resolveExisting(FileManager.default.temporaryDirectory.path))
        let root = URL(fileURLWithPath: temporary, isDirectory: true)
            .appendingPathComponent("rv-cage-link-to-link-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let keys = root.appendingPathComponent("Y/r/keys")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: keys, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Z"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("W"), withIntermediateDirectories: true)
        let marker = "RV-CAGE-SECRET-\(UUID().uuidString)"
        try Data(marker.utf8).write(to: keys.appendingPathComponent("id_rsa"))
        let zq = root.appendingPathComponent("Z/q")
        try #require(symlink(root.appendingPathComponent("Y/r").path, zq.path) == 0)
        try #require(symlink(zq.path, root.appendingPathComponent("W/b").path) == 0)
        try #require(symlink(root.appendingPathComponent("W/b/keys").path, home.appendingPathComponent(".ssh").path) == 0)
        let tmp = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let scratch = home.appendingPathComponent("Library/Caches/rv-mcp/l2l", isDirectory: true)
        #expect(MCPSandbox.createCheckedDirectory(scratch.path))
        let profile = try MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false), scratch: scratch.path, home: home.path,
            configDirectory: home.appendingPathComponent(".config/rv").path, temporaryDirectory: tmp.path).get()
        let script = """
            home="$1"; s="$2"; zq="$3"
            /bin/echo STARTED
            /bin/cat "$home/.ssh/id_rsa" 2>/dev/null
            /bin/mkdir -p "$s/mine/r/keys" && /bin/ln -s "$s/mine/r" "$s/newl"
            /bin/rm "$zq" 2>/dev/null && echo UNLINK_OK
            /bin/mv "$zq" "$s/moved" 2>/dev/null && echo RENAME_OK
            replace "$s/newl" "$zq" && echo REPLACE_OK
            swap "$s/newl" "$zq" && echo SWAP_OK
            echo DONE
            """
        let output = try #require(try caged(profile, script, [home.path, scratch.path, zq.path], in: scratch.path))
        #expect(output.contains("STARTED"), "\(output)")
        #expect(output.contains("DONE"), "\(output)")
        #expect(output.contains(marker) == false, "\(output)")
        for refused in ["UNLINK_OK", "RENAME_OK", "REPLACE_OK", "SWAP_OK"] {
            #expect(output.contains(refused) == false, "\(refused): \(output)")
        }
        #expect(MCPSandbox.readLink(zq.path) == root.appendingPathComponent("Y/r").path)
    }

    /// A missing directory above a credential, inside a write root (here
    /// `~/Library/Application Support/Google` above Chrome's, the home under
    /// the temp directory). Whatever the cage put there would hold the
    /// credential once its owner writes it: a symlink to the scratch, a
    /// link renamed onto the path, or a directory of its own renamed there
    /// with a link inside (`Chrome` → the scratch). All are refused. So is a
    /// plain `mkdir`: Seatbelt checks it as the same create as a directory
    /// renamed in. Creating a directory that is no credential ancestor still
    /// works, and making an ancestor that exists still says it exists.
    @Test(.timeLimit(.minutes(1)))
    func aMissingCredentialAncestorCannotBeCreatedByTheCage() throws {
        let temporary = try #require(MCPSandbox.resolveExisting(FileManager.default.temporaryDirectory.path))
        let root = URL(fileURLWithPath: temporary, isDirectory: true)
            .appendingPathComponent("rv-cage-missing-ancestor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let support = home.appendingPathComponent("Library/Application Support")
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        let tmp = root.appendingPathComponent("tmp")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        let scratch = home.appendingPathComponent("Library/Caches/rv-mcp/planter", isDirectory: true)
        #expect(MCPSandbox.createCheckedDirectory(scratch.path))
        let profile = try MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false), scratch: scratch.path, home: home.path,
            configDirectory: home.appendingPathComponent(".config/rv").path, temporaryDirectory: tmp.path).get()
        let google = support.appendingPathComponent("Google")
        let script = """
            g="$1"; s="$2"; support="$3"
            /bin/echo STARTED
            /bin/ln -s "$s/mine" "$g" 2>/dev/null && echo LINK_CREATED
            /bin/ln -s "$s/mine" "$s/evil" && replace "$s/evil" "$g" && echo LINK_RENAMED
            /bin/mkdir -p "$s/dir" && /bin/ln -s "$s/mine" "$s/dir/Chrome" && replace "$s/dir" "$g" && echo DIR_RENAMED
            printf f > "$s/file" && /bin/ln "$s/file" "$g" 2>/dev/null && echo HARDLINK_MADE
            /bin/mkdir "$g" 2>/dev/null && echo MKDIR_MADE
            /bin/mkdir "$support/Other" && echo OTHER_OK
            /bin/mkdir "$support" 2>&1 | /usr/bin/grep -q "File exists" && echo EXISTS_SAID
            echo DONE
            """
        let output = try #require(try caged(profile, script, [google.path, scratch.path, support.path], in: scratch.path))
        #expect(output.contains("STARTED"), "\(output)")
        #expect(output.contains("DONE"), "\(output)")
        for refused in ["LINK_CREATED", "LINK_RENAMED", "DIR_RENAMED", "HARDLINK_MADE", "MKDIR_MADE"] {
            #expect(output.contains(refused) == false, "\(refused): \(output)")
        }
        #expect(output.contains("OTHER_OK"), "\(output)")
        #expect(output.contains("EXISTS_SAID"), "\(output)")
        var info = stat()
        #expect(lstat(google.path, &info) != 0, "something was planted at \(google.path)")
    }

    /// `~/.config` a link into a dotfiles directory, with `gh` there and
    /// `gcloud` missing, the home outside every write root. The server
    /// starts in its scratch, `getcwd` works, it writes there and lists the
    /// home; `gh` stays unread and unwritten through either spelling, and
    /// `gcloud` cannot be planted (a symlink, a directory, a cloned link).
    @Test(
        .timeLimit(.minutes(1)),
        .enabled(if: access("/Users/Shared", W_OK) == 0, "needs a writable /Users/Shared outside the cage's write roots"))
    func aDotfilesLinkedConfigServerStartsAndItsCredentialsStayDenied() throws {
        let root = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
            .appendingPathComponent("rv-cage-test-\(UUID().uuidString)", isDirectory: true)
        try #require(mkdir(root.path, 0o700) == 0, "could not create \(root.path): errno \(errno)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let config = home.appendingPathComponent("dotfiles/config")
        try FileManager.default.createDirectory(at: config.appendingPathComponent("gh"), withIntermediateDirectories: true)
        let marker = "RV-CAGE-SECRET-\(UUID().uuidString)"
        try Data(marker.utf8).write(to: config.appendingPathComponent("gh/hosts.yml"))
        try #require(symlink(config.path, home.appendingPathComponent(".config").path) == 0)
        let temporary = try #require(MCPSandbox.resolveExisting(FileManager.default.temporaryDirectory.path))
        let tmp = URL(fileURLWithPath: temporary).appendingPathComponent("rv-cage-dotfiles-tmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let scratch = home.appendingPathComponent("Library/Caches/rv-mcp/dotfiles", isDirectory: true)
        #expect(MCPSandbox.createCheckedDirectory(scratch.path))
        let profile = try MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false), scratch: scratch.path, home: home.path,
            configDirectory: home.appendingPathComponent(".config/rv").path, temporaryDirectory: tmp.path).get()
        let script = """
            home="$1"; s="$2"; config="$3"
            /bin/echo STARTED
            [ "$(/bin/pwd -P 2>/dev/null)" = "$s" ] && echo GETCWD_OK
            printf ok > "$s/written" && /bin/cat "$s/written" > /dev/null && echo SCRATCH_OK
            /bin/ls "$home" > /dev/null 2>&1 && echo LIST_HOME_OK
            /bin/cat "$home/.config/gh/hosts.yml" "$config/gh/hosts.yml" 2>/dev/null
            printf x > "$home/.config/gh/planted" 2>/dev/null && echo GH_WRITTEN
            printf x > "$config/gh/planted" 2>/dev/null && echo GH_WRITTEN
            /bin/ln -s "$s" "$home/.config/gcloud" 2>/dev/null && echo GCLOUD_PLANTED
            /bin/mkdir "$config/gcloud" 2>/dev/null && echo GCLOUD_PLANTED
            /bin/ln -s "$s" "$s/link" && /usr/bin/python3 -I -c 'import ctypes,sys; l=ctypes.CDLL(None,use_errno=True); \
            sys.exit(0 if l.clonefile(sys.argv[1].encode(),sys.argv[2].encode(),1)==0 else 1)' "$s/link" "$config/gcloud" \
            && echo GCLOUD_PLANTED
            echo DONE
            """
        let output = try #require(try caged(profile, script, [home.path, scratch.path, config.path], in: scratch.path))
        for expected in ["STARTED", "GETCWD_OK", "SCRATCH_OK", "LIST_HOME_OK", "DONE"] {
            #expect(output.contains(expected), "\(expected): \(output)")
        }
        #expect(output.contains(marker) == false, "\(output)")
        #expect(output.contains("GH_WRITTEN") == false, "\(output)")
        #expect(output.contains("GCLOUD_PLANTED") == false, "\(output)")
        var info = stat()
        #expect(lstat(config.appendingPathComponent("gcloud").path, &info) != 0, "something was planted at gcloud")
        #expect(FileManager.default.fileExists(atPath: config.appendingPathComponent("gh/planted").path) == false)
    }

    /// The swap test above for `~/.config`: `~/.config` → `W/x/config`, `x`
    /// a link to `W/y`, `W` a `sandbox.writable` directory and `gcloud`
    /// missing. Neither `x` nor `~/.config` can be removed, renamed,
    /// replaced or swapped for a link to a directory the cage controls (in
    /// the temp directory), `gh` stays unread, and the links are the same
    /// afterwards.
    @Test(
        .timeLimit(.minutes(1)),
        .enabled(if: access("/Users/Shared", W_OK) == 0, "needs a writable /Users/Shared outside the cage's write roots"))
    func aSymlinkedConfigThroughALinkInAWriteRootCannotBeSwapped() throws {
        let root = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
            .appendingPathComponent("rv-cage-test-\(UUID().uuidString)", isDirectory: true)
        try #require(mkdir(root.path, 0o700) == 0, "could not create \(root.path): errno \(errno)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let w = root.appendingPathComponent("w")
        let gh = w.appendingPathComponent("y/config/gh")
        try FileManager.default.createDirectory(at: gh, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let marker = "RV-CAGE-SECRET-\(UUID().uuidString)"
        try Data(marker.utf8).write(to: gh.appendingPathComponent("hosts.yml"))
        let link = w.appendingPathComponent("x")
        try #require(symlink(w.appendingPathComponent("y").path, link.path) == 0)
        let dotConfig = home.appendingPathComponent(".config")
        try #require(symlink(link.appendingPathComponent("config").path, dotConfig.path) == 0)
        let temporary = try #require(MCPSandbox.resolveExisting(FileManager.default.temporaryDirectory.path))
        let tmp = URL(fileURLWithPath: temporary).appendingPathComponent("rv-cage-config-swap-tmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let scratch = home.appendingPathComponent("Library/Caches/rv-mcp/config-swapper", isDirectory: true)
        #expect(MCPSandbox.createCheckedDirectory(scratch.path))
        let profile = try MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false, writable: [w.path]), scratch: scratch.path, home: home.path,
            configDirectory: home.appendingPathComponent(".config/rv").path, temporaryDirectory: tmp.path).get()
        let script = """
            home="$1"; t="$2"; x="$3"
            /bin/echo STARTED
            /bin/cat "$home/.config/gh/hosts.yml" "$x/config/gh/hosts.yml" 2>/dev/null
            /bin/mkdir -p "$t/mine/config/gh" && /bin/ln -s "$t/mine" "$t/evil" && /bin/ln -s "$t/mine/config" "$t/evil-config" \
            && echo PREPARED
            for target in "$x" "$home/.config"; do
              /bin/rm "$target" 2>/dev/null && echo UNLINK_OK
              /bin/mv "$target" "$t/moved" 2>/dev/null && echo RENAME_OK
            done
            replace "$t/evil" "$x" && echo REPLACE_OK
            swap "$t/evil" "$x" && echo SWAP_OK
            replace "$t/evil-config" "$home/.config" && echo REPLACE_OK
            swap "$t/evil-config" "$home/.config" && echo SWAP_OK
            echo DONE
            """
        let output = try #require(try caged(profile, script, [home.path, tmp.path, link.path], in: tmp.path))
        for expected in ["STARTED", "PREPARED", "DONE"] {
            #expect(output.contains(expected), "\(expected): \(output)")
        }
        #expect(output.contains(marker) == false, "\(output)")
        for refused in ["UNLINK_OK", "RENAME_OK", "REPLACE_OK", "SWAP_OK"] {
            #expect(output.contains(refused) == false, "\(refused): \(output)")
        }
        #expect(MCPSandbox.readLink(link.path) == w.appendingPathComponent("y").path)
        #expect(MCPSandbox.readLink(dotConfig.path) == link.appendingPathComponent("config").path)
    }

    /// Asking another process to start something is refused: `open` of a
    /// file in the scratch (LaunchServices), a read-only Apple event to the
    /// Finder, and `launchctl submit` of `/usr/bin/true`, which leaves no
    /// job behind. Each prints its exit status; none may succeed.
    @Test(
        .timeLimit(.minutes(1)),
        .enabled(if: access("/Users/Shared", W_OK) == 0, "needs a writable /Users/Shared outside the cage's write roots"))
    func launchServicesAppleEventsAndLaunchdAreRefusedInTheCage() throws {
        let root = URL(fileURLWithPath: "/Users/Shared", isDirectory: true)
            .appendingPathComponent("rv-cage-test-\(UUID().uuidString)", isDirectory: true)
        try #require(mkdir(root.path, 0o700) == 0, "could not create \(root.path): errno \(errno)")
        defer { try? FileManager.default.removeItem(at: root) }
        let home = root.appendingPathComponent("home")
        let temporary = try #require(MCPSandbox.resolveExisting(FileManager.default.temporaryDirectory.path))
        let tmp = URL(fileURLWithPath: temporary).appendingPathComponent("rv-cage-lsopen-tmp-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let scratch = home.appendingPathComponent("Library/Caches/rv-mcp/opener", isDirectory: true)
        #expect(MCPSandbox.createCheckedDirectory(scratch.path))
        try Data("note".utf8).write(to: scratch.appendingPathComponent("note.txt"))
        let label = "dev.rv.mcp-cage-submit-\(getpid())-\(UUID().uuidString.prefix(8))"
        defer {
            let cleanup = Process()
            cleanup.executableURL = URL(fileURLWithPath: "/bin/launchctl")
            cleanup.arguments = ["remove", label]
            cleanup.standardError = FileHandle.nullDevice
            if (try? cleanup.run()) != nil { cleanup.waitUntilExit() }
        }
        let profile = try MCPSandbox.profile(
            policy: MCPSandboxPolicy(network: false), scratch: scratch.path, home: home.path,
            configDirectory: home.appendingPathComponent(".config/rv").path, temporaryDirectory: tmp.path).get()
        let script = """
            s="$1"; label="$2"
            /bin/echo STARTED
            /usr/bin/open -g -j "$s/note.txt" 2>/dev/null; echo "open rc=$?"
            /usr/bin/osascript -e 'tell application "Finder" to get name of startup disk' >/dev/null 2>&1; echo "event rc=$?"
            /bin/launchctl submit -l "$label" -- /usr/bin/true 2>/dev/null; echo "submit rc=$?"
            echo DONE
            """
        let output = try #require(try caged(profile, script, [scratch.path, label], in: scratch.path))
        #expect(output.contains("STARTED") && output.contains("DONE"), "\(output)")
        for route in ["open", "event", "submit"] {
            #expect(output.contains("\(route) rc=") && output.contains("\(route) rc=0\n") == false, "\(route): \(output)")
        }
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
        sibling.arguments = ["-p", profile, probe.path, "hold"]
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
        // sandbox-exec execs the probe in place: wait until it has. Inside
        // the cage a process that has exited is refused EPERM too, so the
        // sibling is shown readable from here before and after the caged
        // read, which is made once.
        let pid = sibling.processIdentifier
        let before = MCPPlaceholderLiveTests.procargsFromHere(probe, readableWithin: 10, pid, in: root)
        try #require(before.hasSuffix(" home=yes"), "the sibling never showed its environment here: \(before)")

        // The child holds the fifo until the script closes it; its read is
        // retried until it shows the child's own environment (a child that
        // has not yet exec'd the probe is refused), 60 times at most.
        let script = """
            p="$1"; sibling="$2"
            echo "sibling: $("$p" procargs "$sibling")"
            echo "self: $("$p" procargs self)"
            /usr/bin/mkfifo "$PWD/hold"
            HOME=/rv-procargs-child "$p" hold < "$PWD/hold" > /dev/null 2>&1 &
            child=$!
            exec 3> "$PWD/hold"
            tries=0
            while :; do
              got=$("$p" procargs $child)
              case "$got" in *" home=yes") break ;; esac
              tries=$((tries + 1)); [ $tries -ge 60 ] && break
              /bin/sleep 0.1
            done
            echo "child: $got"
            exec 3>&-
            wait $child
            echo DONE
            """
        let output = try #require(try caged(profile, script, [probe.path, String(pid)], in: scratch.path))
        #expect(output.contains("DONE"), "\(output)")
        #expect(output.contains("sibling: failed errno=\(EPERM)"), "\(output)")
        #expect(output.contains("self: ok argc="), "\(output)")
        #expect(output.contains("child: ok argc=") && output.contains(" home=yes\n"), "\(output)")
        let after = MCPPlaceholderLiveTests.procargsFromHere(probe, readableWithin: 10, pid, in: root)
        #expect(after.hasSuffix(" home=yes"), "\(after)")
        #expect(sibling.isRunning)
    }
}
#endif
