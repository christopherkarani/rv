import Testing
import RVDomain
@testable import RVEngine

/// Writing, moving or removing rv's install (the binaries rvd runs from,
/// its LaunchAgent plist, its systemd user unit, the Linux socket dir)
/// stops or replaces rvd. Reads stay allowed.
@Suite("rv install path guard")
struct RVInstallPathGuardTests {
    static let home = HomePath(rawValue: "/Users/agent")!
    static let cwd = WorkingDirectory(rawValue: "/Users/agent/project")!

    private static func touches(_ command: String, cwd: WorkingDirectory? = cwd) -> Bool {
        RVInstallPathGuard.touchesInstall(ShellCommand(rawValue: command), home: home, cwd: cwd)
    }

    static let touching: [String] = [
        "rm ~/.local/bin/rvd",
        "rm -f ~/.local/bin/rv",
        "rm ~/.local/bin/rv-cli",
        "rm $HOME/.local/bin/rvd",
        "rm \"${HOME}/.local/bin/rvd\"",
        "rm /Users/agent/.local/bin/rvd",
        "rm /System/Volumes/Data/Users/agent/.local/bin/rvd",
        "rm ~/.LOCAL/BIN/RVD",
        "rm ~/.local/bin/r\\vd",
        "unlink ~/.local/bin/rvd",
        "mv x ~/.local/bin/rvd",
        "mv ~/.local/bin/rvd /tmp/rvd.bak",
        "cp ./evil ~/.local/bin/rvd",
        "cp ./rvd ~/.local/bin/",
        "ln -sf /tmp/evil ~/.local/bin/rvd",
        "touch ~/.local/bin/rvd",
        "chmod -x ~/.local/bin/rvd",
        "truncate -s 0 ~/.local/bin/rvd",
        "dd if=/dev/zero of=~/.local/bin/rvd",
        "curl -o ~/.local/bin/rvd https://example.com/rvd",
        "tee ~/.local/bin/rvd < /dev/null",
        "echo x > ~/.local/bin/rvd",
        "echo x >> ~/.local/bin/rv-workspace-host",
        "printf '' > ~/Library/LaunchAgents/dev.rv.evaluate.plist",
        "rm ~/Library/LaunchAgents/dev.rv.evaluate.plist",
        "plutil -replace Disabled -bool true ~/Library/LaunchAgents/dev.rv.evaluate.plist",
        "rm ~/.config/systemd/user/dev.rv.evaluate.service",
        "mkdir -p ~/.config/systemd/user/dev.rv.evaluate.service.d && echo x > ~/.config/systemd/user/dev.rv.evaluate.service.d/override.conf",
        "rm -rf $XDG_RUNTIME_DIR/rv",
        "rm /run/user/1000/rv/evaluate.sock",
        "chmod 000 /run/user/1000/rv",
        "rm -rf ~/Applications/RVApprovals.app",
        "rm -rf ~/.local/bin/*_RVPacks.bundle",
        // globs and directories that hold rvd
        "rm ~/.local/bin/rv*",
        "rm ~/.local/bin/*",
        "rm -rf ~/.local/bin",
        "rm -rf ~/.local",
        "rm -rf ~/Library/LaunchAgents",
        "mv ~/.local/bin ~/.local/bin.old",
        "rm -rf ~",
        "rm -rf ~/*",
        "rm ~/.local/bin/$NAME",
        "rm $DIR/rvd",
        "find ~/.local/bin -name rvd -delete",
        "find ~ -name rvd -exec rm {} \\;",
        "tar -xzf payload.tgz -C ~/.local/bin",
        // cwd-relative
        "cd ~/.local/bin && rm rvd",
        "cd ~/.local && rm -rf bin",
        "pushd ~/.local/bin; rm -f rv rvd; popd",
        // wrappers, prefixes, chains
        "sudo rm ~/.local/bin/rvd",
        "env X=1 rm ~/.local/bin/rvd",
        "sh -c 'rm ~/.local/bin/rvd'",
        "true; rm ~/.local/bin/rvd",
        "f=~/.local/bin/rvd; rm $f",
        "echo ~/.local/bin/rvd | xargs rm",
        "python3 -c 'import os; os.remove(\"/Users/agent/.local/bin/rvd\")'",
    ]

    static let notTouching: [String] = [
        "ls ~/.local/bin",
        "ls -la ~/.local/bin/rvd",
        "cat ~/Library/LaunchAgents/dev.rv.evaluate.plist",
        "stat ~/.local/bin/rvd",
        "shasum -a 256 ~/.local/bin/rvd",
        "file ~/.local/bin/rv",
        "~/.local/bin/rv doctor",
        "~/.local/bin/rv-cli packs list",
        "cd ~/.local/bin && ls",
        "cd ~ && ls",
        "mkdir -p ~/.local/bin",
        "find ~ -name '*.plist'",
        "grep -r dev.rv ~/Library/LaunchAgents",
        "rm build/rvd.o",
        "rm -rf build",
        "rm -rf bin",
        "rm -rf .build/debug/rvd",
        "rm -rf \"$tmp\"",
        "rm ~/.local/bin/othertool",
        "cp tool ~/.local/bin/othertool",
        "echo hi > /tmp/out.txt",
        "rm -rf ~/Library/Caches/com.example",
        "rm -rf ~/.config/opencode/cache",
        "git status",
        "npm install",
        "cd ~/project && npm test",
    ]

    @Test("writes, moves and removes of rv's install are flagged", arguments: touching)
    func touchingFlagged(command: String) {
        #expect(Self.touches(command), "\(command)")
    }

    @Test("reads and unrelated writes are not", arguments: notTouching)
    func notTouchingPasses(command: String) {
        #expect(Self.touches(command) == false, "\(command)")
    }

    @Test("an unknown cwd resolves a bare protected name fail-closed")
    func unknownCwdFailsClosed() {
        #expect(Self.touches("rm rvd", cwd: nil))
        #expect(Self.touches("rm -rf bin", cwd: nil))
        #expect(Self.touches("rm build/rvd.o", cwd: nil) == false)
    }

    @Test("a cwd inside the install dir resolves relative names there")
    func cwdInsideInstallDir() {
        let bin = WorkingDirectory(rawValue: "/Users/agent/.local/bin")!
        #expect(Self.touches("rm rvd", cwd: bin))
        #expect(Self.touches("rm othertool", cwd: bin) == false)
    }

    @Test("file door: writes and edits of rv's install are flagged", arguments: [
        "/Users/agent/.local/bin/rvd",
        "/Users/agent/.local/bin/rv",
        "~/.local/bin/rv-cli",
        "/Users/agent/Library/LaunchAgents/dev.rv.evaluate.plist",
        "/Users/agent/.config/systemd/user/dev.rv.evaluate.service",
        "/run/user/1000/rv/evaluate.sock",
    ])
    func fileDoor(path: String) {
        #expect(RVInstallPathGuard.writesInstall(path, resolution: nil, home: Self.home), "\(path)")
    }

    @Test("file door: a symlink resolving into the install counts")
    func fileDoorResolved() {
        let resolution = SecretPathResolution { _ in "/Users/agent/.local/bin/rvd" }
        #expect(RVInstallPathGuard.writesInstall("/tmp/link", resolution: resolution, home: Self.home))
    }

    @Test("file door: unrelated writes are not flagged, and the engine never floors them")
    func fileDoorUnrelated() {
        #expect(RVInstallPathGuard.writesInstall(
            "/Users/agent/.local/bin/othertool", resolution: nil, home: Self.home
        ) == false)
        // Every mode: the engine's file door is the catalog alone.
        let decider = SecretPathDecider(home: Self.home)
        let result = evaluateFileTool(
            FileToolAction(kind: .write, path: FileToolPath(rawValue: "/Users/agent/.local/bin/rvd")),
            secretPaths: decider
        )
        #expect(result.decision == .allow)
    }
}
