#if os(macOS)
import Foundation
import Testing
@testable import RVIsolation

@Test func pseudoTerminalEnvironmentAdvertisesColorOutput() {
    let values = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .pseudoTerminal(rows: 24, columns: 80), hostEnvironment: [:]
    )
    #expect(values.contains("TERM=xterm-256color"))
    #expect(values.contains("CLICOLOR=1"))
    // zsh ignores an inherited PS1, so none is set; the prompt stays the
    // zsh default unless the user creates a workspace-local .zshrc.
    #expect(values.allSatisfy { $0.hasPrefix("PS1=") == false })
    #expect(values.contains("PATH=/usr/bin:/bin"))
    #expect(values.contains("HOME=/tmp/ws"))
    // Empty host env means no usable home, so the cage falls back to the
    // workspace itself. Real runs always resolve an RV-managed home/tmp.
    #expect(values.contains("TMPDIR=/tmp/ws"))
}

@Test func nonTerminalEnvironmentStaysNonInteractive() {
    let values = containedRuntimeEnvironment(
        workspace: "/tmp/ws",
        io: .inherit,
        agentBin: "/opt/rv/bin/rv-agent-bin",
        egressProxyPort: 39321,
        hostEnvironment: ["ANTHROPIC_BASE_URL": "http://127.0.0.1:10100"]
    )
    #expect(values.contains("TERM=xterm-256color") == false)
    #expect(values.contains("CLICOLOR=1") == false)
    #expect(values.allSatisfy { $0.hasPrefix("PS1=") == false })
    #expect(values.contains("PATH=/usr/bin:/bin"))
    #expect(values.contains("TMPDIR=/tmp/ws"))
    // Explicitly requested proxy and gateway passthrough still apply to
    // one-shot runs; only terminal affordances stay off.
    #expect(values.contains("HTTPS_PROXY=http://127.0.0.1:39321"))
    #expect(values.contains("ANTHROPIC_BASE_URL=http://127.0.0.1:10100"))
}

@Test func terminalPATHPrefersInstalledAgentBin() throws {
    let plain = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .pseudoTerminal(rows: 24, columns: 80),
        agentBin: nil, hostEnvironment: [:]
    )
    #expect(plain.contains("PATH=/usr/bin:/bin"))
    // Nonexistent agentBin dirs are sanitized out, never blindly prepended.
    // A HOME the runtime cannot prepare (no RV home, no shim prefix) keeps
    // the PATH assertion exact.
    let missing = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .pseudoTerminal(rows: 24, columns: 80),
        agentBin: "/opt/rv/bin/rv-agent-bin", hostEnvironment: ["HOME": "/Users/test"]
    )
    #expect(missing.contains("PATH=/usr/bin:/bin"))
    // An installed agentBin dir is preferred first.
    let staged = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-agentbin-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: staged) }
    let agent = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .pseudoTerminal(rows: 24, columns: 80),
        agentBin: staged.path, hostEnvironment: ["HOME": "/Users/test"]
    )
    let canonical = try #require(posixRealpath(staged.path))
    #expect(agent.contains("PATH=\(canonical):/usr/bin:/bin"))
    // The cage cannot manage host services or rewrite installs.
    #expect(agent.contains("OCX_SHIM_BYPASS=1"))
    #expect(agent.contains("MUSE_NO_AUTO_UPDATE=1"))
    #expect(agent.contains("DISABLE_AUTOUPDATER=1"))
    #expect(plain.allSatisfy { $0.hasPrefix("OCX_SHIM_BYPASS=") == false })
    let oneShot = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .inherit,
        agentBin: "/opt/rv/bin/rv-agent-bin", hostEnvironment: ["HOME": "/Users/test"]
    )
    #expect(oneShot.contains("PATH=/usr/bin:/bin"))
}
@Test func terminalEnvironmentExposesEgressProxy() {
    let values = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .pseudoTerminal(rows: 24, columns: 80),
        egressProxyPort: 39321, hostEnvironment: [:]
    )
    #expect(values.contains("HTTPS_PROXY=http://127.0.0.1:39321"))
    #expect(values.contains("HTTP_PROXY=http://127.0.0.1:39321"))
    #expect(values.contains("https_proxy=http://127.0.0.1:39321"))
    #expect(values.contains("http_proxy=http://127.0.0.1:39321"))
    #expect(values.contains("NO_PROXY=localhost,127.0.0.1,::1"))
    #expect(values.contains("no_proxy=localhost,127.0.0.1,::1"))
    for bad in [0, -1, 70_000] {
        let omitted = containedRuntimeEnvironment(
            workspace: "/tmp/ws", io: .pseudoTerminal(rows: 24, columns: 80),
            egressProxyPort: bad, hostEnvironment: [:]
        )
        #expect(omitted.allSatisfy { $0.hasPrefix("HTTPS_PROXY=") == false })
        #expect(omitted.allSatisfy { $0.hasPrefix("NO_PROXY=") == false })
        #expect(omitted.allSatisfy { $0.hasPrefix("no_proxy=") == false })
    }
    let missing = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .pseudoTerminal(rows: 24, columns: 80),
        hostEnvironment: [:]
    )
    #expect(missing.allSatisfy { $0.hasPrefix("HTTPS_PROXY=") == false })
    #expect(missing.allSatisfy { $0.hasPrefix("NO_PROXY=") == false })
}

@Test func terminalEnvironmentPassesGatewayThrough() {
    let values = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .pseudoTerminal(rows: 24, columns: 80),
        agentBin: "/opt/rv/bin/rv-agent-bin",
        hostEnvironment: [
            "ANTHROPIC_BASE_URL": "http://127.0.0.1:10100",
            "CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY": "1",
            "ANTHROPIC_API_KEY": "host-key-value",
        ]
    )
    #expect(values.contains("ANTHROPIC_BASE_URL=http://127.0.0.1:10100"))
    #expect(values.contains("CLAUDE_CODE_ENABLE_GATEWAY_MODEL_DISCOVERY=1"))
    #expect(values.contains("ANTHROPIC_API_KEY=host-key-value"))
    #expect(values.allSatisfy { $0.hasPrefix("CLAUDE_CODE_AUTO_COMPACT_WINDOW=") == false })
}

@Test func terminalEnvironmentKeyPolicy() {
    let values = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .pseudoTerminal(rows: 24, columns: 80),
        agentBin: "/opt/rv/bin/rv-agent-bin",
        hostEnvironment: [
            "META_API_KEY": "keychain-captive",
            "OPENAI_API_KEY": "must-not-pass",
        ]
    )
    #expect(values.contains("META_API_KEY=keychain-captive"))
    #expect(values.allSatisfy { $0.hasPrefix("OPENAI_API_KEY=") == false })
    // No host key: the gateway placeholder stands in, never empty/absent.
    #expect(values.contains("ANTHROPIC_API_KEY=rv-cage-gateway-placeholder"))
    // A host key wins over the placeholder.
    let explicit = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .pseudoTerminal(rows: 24, columns: 80),
        agentBin: "/opt/rv/bin/rv-agent-bin",
        hostEnvironment: ["ANTHROPIC_API_KEY": "host-key-value"]
    )
    #expect(explicit.contains("ANTHROPIC_API_KEY=host-key-value"))
    #expect(explicit.allSatisfy { $0 != "ANTHROPIC_API_KEY=rv-cage-gateway-placeholder" })
    // AgentBin key compat applies to one-shot runs too: agents authenticate
    // the same way in both modes. A host key wins over the placeholder.
    let oneShot = containedRuntimeEnvironment(
        workspace: "/tmp/ws", io: .inherit,
        agentBin: "/opt/rv/bin/rv-agent-bin",
        hostEnvironment: ["META_API_KEY": "x", "ANTHROPIC_API_KEY": "x"]
    )
    #expect(oneShot.contains("META_API_KEY=x"))
    #expect(oneShot.contains("ANTHROPIC_API_KEY=x"))
    #expect(oneShot.allSatisfy { $0 != "ANTHROPIC_API_KEY=rv-cage-gateway-placeholder" })
}

@Test func productiveResolutionCarriesSystemTemporaryDirectory() throws {
    // confstr is authoritative and host-independent: a hostile host TMPDIR
    // cannot redirect the grant.
    let resolution = resolveProductiveWorkspace(
        workspacePath: "/tmp/ws",
        hostEnvironment: ["HOME": "/Users/test", "PATH": "/usr/bin:/bin", "TMPDIR": "/elsewhere"]
    )
    let systemTmp = try #require(resolution.systemTemporaryDirectory)
    #expect(systemTmp.hasPrefix("/"))
    #expect(systemTmp.contains("/elsewhere") == false)
    // Canonical spelling: the kernel evaluates symlinks before Seatbelt
    // matching, so an unresolved `/var/...` grant would never match.
    #expect(posixRealpath(systemTmp) == systemTmp)
    var isDirectory: ObjCBool = false
    #expect(FileManager.default.fileExists(atPath: systemTmp, isDirectory: &isDirectory))
    #expect(isDirectory.boolValue)
}

@Test func productiveProfileGrantsSystemTemporaryDirectoryReadWrite() {
    var resolution = ProductiveWorkspaceResolution()
    resolution.systemTemporaryDirectory = "/private/var/folders/x/T"
    let base = SeatbeltProfile(source: "(version 1)\n(deny default)\n", workspacePath: "/tmp/ws")
    let profile = base.allowingProductiveWorkspace(resolution)
    // Read-write: the link needs temp writes and test-bundle plist
    // processing needs temp read-back (backup exclusion). Exactly one
    // mention: the grant stays scoped to the fallback dir.
    #expect(profile.source.contains("(allow file-read* file-write*\n    (subpath \"/private/var/folders/x/T\"))"))
    #expect(profile.source.components(separatedBy: "/private/var/folders/x/T").count == 2)
}

@Test func productiveProfileOmitsSystemTemporaryDirectoryWhenUnresolved() {
    let resolution = ProductiveWorkspaceResolution()
    #expect(resolution.systemTemporaryDirectory == nil)
    let base = SeatbeltProfile(source: "(version 1)\n(deny default)\n", workspacePath: "/tmp/ws")
    let profile = base.allowingProductiveWorkspace(resolution)
    #expect(profile.source.contains("(allow file-write*") == false)
}

@Test func sanitizedPATHImpliesBinParentsButNeverRoot() {
    // Hermetic toolchain layout: no directory entries, so only the
    // admitted-`bin` expansion fires.
    let probe = ContainedPATHProbe(
        realpath: { $0 },
        isDirectory: { ["/opt/tool/usr/bin", "/usr/bin", "/bin"].contains($0) },
        isExecutable: { _ in true },
        listDirectory: { _ in [] }
    )
    let sanitized = ContainedPATH.sanitize(
        hostPATH: "/opt/tool/usr/bin", hostHome: "/Users/test",
        agentBin: nil, probe: probe
    )
    #expect(sanitized.directories.contains("/opt/tool/usr/bin"))
    // Sibling `lib` trees stay readable for toolchain binaries.
    #expect(sanitized.impliedDirectories.contains("/opt/tool/usr"))
    // `/usr/bin` expands to the already-granted `/usr`; `/bin` expands to
    // nothing — the filesystem root is never implied.
    #expect(sanitized.impliedDirectories.contains("/usr"))
    #expect(sanitized.impliedDirectories.contains("/") == false)
}

@Test func sanitizedPATHBinParentExpansionHonorsSecretVeto() {
    // `~/.local/bin` is admitted (no catalog rule names it), but its parent
    // sits above `.local/share` credential paths, so the expansion vetoes.
    let home = "/Users/test"
    let probe = ContainedPATHProbe(
        realpath: { $0 },
        isDirectory: { [home + "/.local/bin", "/usr/bin", "/bin"].contains($0) },
        isExecutable: { _ in true },
        listDirectory: { _ in [] }
    )
    let sanitized = ContainedPATH.sanitize(
        hostPATH: home + "/.local/bin", hostHome: home,
        agentBin: nil, probe: probe
    )
    #expect(sanitized.directories.contains(home + "/.local/bin"))
    #expect(sanitized.impliedDirectories.contains(home + "/.local") == false)
}

@Test func sanitizedPATHSymlinkGrandparentNeverReachesRoot() {
    // A symlink resolving into `/bin` implies `/bin` (the target parent)
    // but the `bin`-grandparent step must stop before the root. `/bin` is
    // absent here so the implication is observable (normally admitted).
    let probe = ContainedPATHProbe(
        realpath: { $0 == "/w/bin/x" ? "/bin/sh" : $0 },
        isDirectory: { ["/w/bin", "/usr/bin"].contains($0) },
        isExecutable: { _ in true },
        listDirectory: { $0 == "/w/bin" ? ["x"] : [] }
    )
    let sanitized = ContainedPATH.sanitize(
        hostPATH: "/w/bin", hostHome: "/Users/test",
        agentBin: nil, probe: probe
    )
    #expect(sanitized.impliedDirectories.contains("/bin"))
    #expect(sanitized.impliedDirectories.contains("/") == false)
}
#endif
