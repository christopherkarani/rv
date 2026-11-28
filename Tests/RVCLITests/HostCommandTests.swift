import ArgumentParser
import Foundation
import Testing
import RVDomain
import RVHistory
import RVPolicy
import RVPresentation
@testable import RVCLI

private struct AuthRefused: Error {}

/// Records whether the owner check ran; `allow` decides its outcome.
private final class AuthProbe: @unchecked Sendable {
    private(set) var calls = 0
    let allow: Bool

    init(allow: Bool) {
        self.allow = allow
    }

    func authenticate() async throws {
        calls += 1
        if allow == false { throw AuthRefused() }
    }
}

private struct WriterRefused: Error {}

/// Keeps what it is handed, as F2's proposal store will.
private final class RecordingProposals: HostModeProposalSink, @unchecked Sendable {
    private(set) var submitted: [HostModeProposal] = []

    func submit(_ proposal: HostModeProposal) -> String? {
        submitted.append(proposal)
        return nil
    }
}

/// A file manager whose removes (and, when asked, directory creates) fail:
/// the seam for a host hook change that does not happen.
private final class RefusingFileManager: FileManager, @unchecked Sendable {
    let refuseCreateDirectory: Bool

    init(refuseCreateDirectory: Bool = false) {
        self.refuseCreateDirectory = refuseCreateDirectory
        super.init()
    }

    override func removeItem(atPath path: String) throws {
        throw WriterRefused()
    }

    override func createDirectory(
        atPath path: String, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]? = nil
    ) throws {
        if refuseCreateDirectory { throw WriterRefused() }
        try super.createDirectory(
            atPath: path, withIntermediateDirectories: withIntermediateDirectories, attributes: attributes)
    }
}

struct HostCommandTests {
    @Test func registeredWithHelpTopic() {
        let names = RV.configuration.subcommands.map { $0.configuration.commandName }
        #expect(names.contains("host"))
        #expect(HelpDispatch.topic(arguments: ["host", "--help"]) == .host)
        #expect(HelpDispatch.topic(arguments: ["help", "host"]) == .host)
    }

    @Test func unknownHostOrModeExits64() {
        for argv in [["nope", "off"], ["claude", "loud"]] {
            do {
                _ = try HostModeCommand.parse(argv)
                Issue.record("\(argv) must not parse")
            } catch {
                #expect(HostModeCommand.exitCode(for: error).rawValue == 64)
            }
        }
    }

    @Test func hostAloneAndModeWithoutArgumentsAreQuestionsNotErrors() throws {
        #expect(HostCommand.configuration.defaultSubcommand == HostListCommand.self)
        let bare = try HostModeCommand.parse([])
        #expect(bare.host == nil && bare.mode == nil)
        let one = try HostModeCommand.parse(["claude"])
        #expect(one.host == "claude" && one.mode == nil)
    }

    @Test func listJSON_everyHostSortedWithModeAndWiring() throws {
        try withTempHome { home, layout, launchctl in
            try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
            let environment = env(home: home, launchctl: launchctl, rvPath: try installedRv(in: home))
            #expect(SetupRun.setup(environment).exitCode == 0)
            try store(home).save(.observe, for: .claude)
            let outcome = HostModeRun.list(environment, json: true)
            #expect(outcome.exitCode == 0)
            let root = try #require(
                try JSONSerialization.jsonObject(with: Data(outcome.stdout.utf8)) as? [String: Any])
            #expect(root["schema"] as? String == "rv.hosts.v1")
            #expect(root["guard"] as? String == "enforce")
            #expect(root["managed_enforce"] as? Bool == false)
            let rows = try #require(root["hosts"] as? [[String: String]])
            #expect(rows.map { $0["host"] ?? "" } == HookHost.allCases.map(\.rawValue).sorted())
            #expect(rows.first { $0["host"] == "grok" } == ["host": "grok", "mode": "block", "wiring": "wired"])
            #expect(rows.first { $0["host"] == "claude" } == ["host": "claude", "mode": "observe", "wiring": "missing"])
            #expect(outcome.stdout.hasPrefix(#"{"guard":"enforce","hosts":[{"host":"antigravity","mode":"block","wiring":"#))
            #expect(outcome.stdout.hasSuffix(#""managed_enforce":false,"schema":"rv.hosts.v1"}"# + "\n"))
        }
    }

    /// `mode` is the host's effective mode: a host with no entry follows the
    /// global `guard.mode`, so under global observe it reads `observe`; an
    /// explicit `block` reads (and evaluates as) `block`.
    @Test func listJSON_underGlobalObserve_reportsEffectiveModes() async throws {
        try await withTempHomeAsync { home, layout, environment in
            try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
            #expect(SetupRun.setup(environment).exitCode == 0)
            let config = home.appendingPathComponent(".config/rv/config.json")
            try Data(#"{"guard":{"mode":"observe"}}"#.utf8).write(to: config)
            let before = HostModeRun.list(environment, json: true)
            #expect(before.stdout.contains(#""guard":"observe""#))
            #expect(before.stdout.contains(#"{"host":"grok","mode":"observe","wiring":"wired"}"#))

            // Under global observe a block stops agents: permanent only with
            // the owner's check at a terminal.
            let probe = AuthProbe(allow: true)
            let block = await HostModeRun.setMode(
                .block, for: .grok, env: environment, json: true, requester: Self.owner,
                authenticate: probe.authenticate)
            #expect(block.exitCode == 0)
            #expect(block.stdout == #"{"host":"grok","mode":"block","schema":"rv.host-mode.v1","wiring":"wired"}"# + "\n")
            #expect(probe.calls == 1)
            #expect(store(home).read() == .entries([.grok: .block]))
            let after = HostModeRun.list(environment, json: true)
            #expect(after.stdout.contains(#"{"host":"grok","mode":"block","wiring":"wired"}"#))
            #expect(after.stdout.contains(#"{"host":"claude","mode":"observe","wiring":"missing"}"#))
        }
    }

    @Test func loosening_withoutOwnerAuth_exits77AndWritesNothing() async throws {
        try await withTempHomeAsync { home, layout, environment in
            try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
            #expect(SetupRun.setup(environment).exitCode == 0)
            let hook = try Data(contentsOf: URL(fileURLWithPath: layout.grokHook))
            for mode in [HostMode.observe, .off] {
                let probe = AuthProbe(allow: false)
                let outcome = await HostModeRun.setMode(
                    mode, for: .grok, env: environment, json: true, authenticate: probe.authenticate)
                #expect(outcome.exitCode == 77)
                #expect(outcome.stdout.isEmpty)
                #expect(outcome.stderr.contains("device-owner authentication required"))
                #expect(probe.calls == 1)
            }
            #expect(store(home).read() == .entries([:]))
            #expect(try Data(contentsOf: URL(fileURLWithPath: layout.grokHook)) == hook)
        }
    }

    @Test func observe_withOwnerAuth_writesModeAndKeepsWiring() async throws {
        try await withTempHomeAsync { home, layout, environment in
            try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
            #expect(SetupRun.setup(environment).exitCode == 0)
            let probe = AuthProbe(allow: true)
            let outcome = await HostModeRun.setMode(
                .observe, for: .grok, env: environment, json: true, authenticate: probe.authenticate)
            #expect(outcome.exitCode == 0)
            #expect(outcome.stdout == #"{"host":"grok","mode":"observe","schema":"rv.host-mode.v1","wiring":"wired"}"# + "\n")
            #expect(probe.calls == 1)
            #expect(store(home).read() == .entries([.grok: .observe]))
            // Same mode again is not a loosening: no prompt.
            let again = AuthProbe(allow: false)
            let repeated = await HostModeRun.setMode(
                .observe, for: .grok, env: environment, json: true, authenticate: again.authenticate)
            #expect(repeated.exitCode == 0)
            #expect(again.calls == 0)
        }
    }

    @Test func off_removesOnlyThatHostsHooks_andTheOwnersBlockRewires() async throws {
        try await withTempHomeAsync { home, layout, environment in
            try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: layout.piDirectory, withIntermediateDirectories: true)
            #expect(SetupRun.setup(environment).exitCode == 0)
            let piBytes = try Data(contentsOf: URL(fileURLWithPath: layout.piExtension))
            let off = await HostModeRun.setMode(
                .off, for: .grok, env: environment, json: true, authenticate: AuthProbe(allow: true).authenticate)
            #expect(off.exitCode == 0)
            #expect(off.stdout == #"{"host":"grok","mode":"off","schema":"rv.host-mode.v1","wiring":"absent-file"}"# + "\n")
            #expect(FileManager.default.fileExists(atPath: layout.grokHook) == false)
            #expect(try Data(contentsOf: URL(fileURLWithPath: layout.piExtension)) == piBytes)
            #expect(FileManager.default.fileExists(atPath: layout.launchAgent))
            #expect(store(home).read() == .entries([.grok: .off]))

            // `rv setup` leaves an off host unwired.
            #expect(SetupRun.setup(environment).exitCode == 0)
            #expect(FileManager.default.fileExists(atPath: layout.grokHook) == false)

            let probe = AuthProbe(allow: true)
            let block = await HostModeRun.setMode(
                .block, for: .grok, env: environment, json: false, requester: Self.owner,
                authenticate: probe.authenticate)
            #expect(block.exitCode == 0)
            #expect(block.stdout == "grok  block  wired\n")
            #expect(probe.calls == 1)
            #expect(FileManager.default.fileExists(atPath: layout.grokHook))
            #expect(store(home).read() == .entries([.grok: .block]))
        }
    }

    /// A config `GuardConfig` rejects (here a repeated key) is unreadable,
    /// not "no entries", and no writer rewrites it: `block` stores nothing
    /// and re-wires nothing (the host stays as `off` left it, never looser),
    /// and tells the owner to fix the file.
    @Test func block_overAnUnreadableConfigWithTheHostOff_refusesAndStaysUnwired() async throws {
        try await withTempHomeAsync { home, layout, environment in
            try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
            #expect(SetupRun.setup(environment).exitCode == 0)
            let off = await HostModeRun.setMode(
                .off, for: .grok, env: environment, json: true, authenticate: AuthProbe(allow: true).authenticate)
            #expect(off.exitCode == 0)
            #expect(FileManager.default.fileExists(atPath: layout.grokHook) == false)
            let config = home.appendingPathComponent(".config/rv/config.json")
            try Data(#"{"guard":{"hosts":{"grok":"off"}},"guard.mode":"enforce","guard.mode":"enforce"}"#.utf8)
                .write(to: config)
            #expect(store(home).read() == .unreadable)
            let list = HostModeRun.list(environment, json: true)
            #expect(list.stdout.contains(#"{"host":"grok","mode":"block","wiring":"absent-file"}"#))

            let unreadable = try Data(contentsOf: config)
            let probe = AuthProbe(allow: false)
            let block = await HostModeRun.setMode(
                .block, for: .grok, env: environment, json: true, authenticate: probe.authenticate)
            #expect(block.exitCode == EX_DATAERR)
            #expect(block.stdout.isEmpty)
            #expect(block.stderr.contains("fix config.json by hand"))
            #expect(probe.calls == 0)
            #expect(FileManager.default.fileExists(atPath: layout.grokHook) == false)
            #expect(try Data(contentsOf: config) == unreadable)
        }
    }

    /// Reading an unreadable config as possibly `off` runs the
    /// trusted-daemon check first; with a trusted daemon the write is then
    /// refused, and the wired hook and the file are left as they were.
    @Test func block_overAnUnreadableConfigWithTheHostWired_keepsTheHookAndChecksTheDaemon() async throws {
        try await withTempHomeAsync { home, layout, base in
            try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
            #expect(SetupRun.setup(base).exitCode == 0)
            let hook = try Data(contentsOf: URL(fileURLWithPath: layout.grokHook))
            let config = home.appendingPathComponent(".config/rv/config.json")
            let unreadable = Data(#"{"guard.mode":"enforce","guard.mode":"enforce"}"#.utf8)
            try unreadable.write(to: config)
            if FileManager.default.isExecutableFile(atPath: base.rvdPath) == false {
                try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: base.rvdPath))
                try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.rvdPath)
            }

            var untrusted = base
            untrusted.daemonTrust = { _ in
                DoctorServiceTrust(source: "manifest", satisfied: false, reason: "installed rvd is ad-hoc signed")
            }
            let refused = await HostModeRun.setMode(
                .block, for: .grok, env: untrusted, json: true, authenticate: AuthProbe(allow: false).authenticate)
            #expect(refused.exitCode != 0)
            #expect(refused.stderr.contains("hooks would reject the installed rvd"))
            #expect(try Data(contentsOf: config) == unreadable)
            #expect(try Data(contentsOf: URL(fileURLWithPath: layout.grokHook)) == hook)

            let block = await HostModeRun.setMode(
                .block, for: .grok, env: base, json: true, authenticate: AuthProbe(allow: false).authenticate)
            #expect(block.exitCode == EX_DATAERR)
            #expect(block.stderr.contains("fix config.json by hand"))
            #expect(try Data(contentsOf: URL(fileURLWithPath: layout.grokHook)) == hook)
            #expect(try Data(contentsOf: config) == unreadable)
        }
    }

    /// Loosening from an unreadable config needs the owner: the host reads
    /// as `block` for that question.
    @Test func loosening_overAnUnreadableConfig_needsTheOwner() async throws {
        try await withTempHomeAsync { home, layout, environment in
            try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
            #expect(SetupRun.setup(environment).exitCode == 0)
            let config = home.appendingPathComponent(".config/rv/config.json")
            let unreadable = Data(#"{"guard":{"hosts":{"grok":"observe","grok":"observe"}}}"#.utf8)
            try unreadable.write(to: config)
            let probe = AuthProbe(allow: false)
            let observe = await HostModeRun.setMode(
                .observe, for: .grok, env: environment, json: true, authenticate: probe.authenticate)
            #expect(observe.exitCode == 77)
            #expect(probe.calls == 1)
            #expect(try Data(contentsOf: config) == unreadable)
        }
    }

    /// The hook change runs before the config write: a detach that leaves
    /// the hook in place stores nothing, so rvd never observes a host whose
    /// hooks still fire, and a retry still needs the owner.
    @Test func off_whenTheHookCannotBeRemoved_exits73AndStoresNothing() async throws {
        try await withTempHomeAsync { home, layout, base in
            try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
            #expect(SetupRun.setup(base).exitCode == 0)
            var environment = base
            environment.fileManager = RefusingFileManager()
            let probe = AuthProbe(allow: true)
            let off = await HostModeRun.setMode(
                .off, for: .grok, env: environment, json: true, authenticate: probe.authenticate)
            #expect(off.exitCode == 73)
            #expect(off.stdout.isEmpty)
            #expect(off.stderr.hasPrefix("rv host mode failed: unable to remove grok hook"))
            #expect(FileManager.default.fileExists(atPath: layout.grokHook))
            #expect(store(home).read() == .entries([:]))
            let retry = AuthProbe(allow: false)
            let again = await HostModeRun.setMode(
                .off, for: .grok, env: environment, json: true, authenticate: retry.authenticate)
            #expect(again.exitCode == 77)
            #expect(retry.calls == 1)
        }
    }

    /// `off` is recorded before the hooks come out: when the audit log
    /// cannot take it, the hooks stay and nothing is stored.
    @Test func off_whenTheChangeCannotBeRecorded_exits74AndKeepsTheHooks() async throws {
        try await withTempHomeAsync { home, layout, base in
            try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
            #expect(SetupRun.setup(base).exitCode == 0)
            let config = home.appendingPathComponent(".config/rv", isDirectory: true)
            let log = AuditLog.fileURL(configDirectory: config)
            try? FileManager.default.removeItem(at: log)
            try FileManager.default.createDirectory(at: log, withIntermediateDirectories: true)
            let off = await HostModeRun.setMode(
                .off, for: .grok, env: base, json: true, authenticate: AuthProbe(allow: true).authenticate)
            #expect(off.exitCode == 74)
            #expect(off.stderr.hasPrefix("rv host mode: the audit log could not record the guard.hosts.grok change"))
            #expect(FileManager.default.fileExists(atPath: layout.grokHook))
            #expect(store(home).read() == .entries([:]))
        }
    }

    @Test func setupObserve_whenTheChangeCannotBeRecorded_exits74() {
        let output = setupFailureOutput(
            .guardModeUnrecorded(ConfigChangeUnrecorded(subject: "guard.mode")), command: .setup)
        #expect(output.exitCode == ConfigChangeRefusal.exitCode)
        #expect(output.stderr.hasPrefix("rv setup failed: the audit log could not record the guard.mode change"))
    }

    @Test func setupObserve_whenConfigCannotBeRewritten_exitsDataErrAndNamesTheFix() {
        let output = setupFailureOutput(.guardConfigUnreadable, command: .setup)
        #expect(output.exitCode == EX_DATAERR)
        #expect(output.stderr.hasPrefix("rv setup failed: config.json cannot be rewritten safely"))
        #expect(output.stderr.contains("no hooks were wired"))
        #expect(output.stderr.contains("fix config.json by hand"))
    }

    /// Leaving `off` stores the tighter mode before re-wiring: a re-wire
    /// that fails leaves the host unwired under `block` (which `rv setup`
    /// repairs), never wired under `off`.
    @Test func leavingOff_whenTheHookCannotBeWritten_exits73AndStoresTheTighterMode() async throws {
        try await withTempHomeAsync { home, layout, base in
            try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
            #expect(SetupRun.setup(base).exitCode == 0)
            let off = await HostModeRun.setMode(
                .off, for: .grok, env: base, json: true, authenticate: AuthProbe(allow: true).authenticate)
            #expect(off.exitCode == 0)
            var environment = base
            environment.fileManager = RefusingFileManager(refuseCreateDirectory: true)
            let block = await HostModeRun.setMode(
                .block, for: .grok, env: environment, json: true, requester: Self.owner,
                authenticate: AuthProbe(allow: true).authenticate)
            #expect(block.exitCode == 73)
            #expect(block.stderr.hasPrefix("rv host mode failed: unable to write grok hook"))
            #expect(FileManager.default.fileExists(atPath: layout.grokHook) == false)
            #expect(store(home).read() == .entries([.grok: .block]))
            #expect(SetupRun.setup(base).exitCode == 0)
            #expect(FileManager.default.fileExists(atPath: layout.grokHook))
        }
    }

    /// Same incident guard as `rv setup`: re-wiring one host to an rvd the
    /// fail-closed hook would reject denies every tool call on that host.
    /// Refuse before storing or writing anything; the host stays off.
    @Test func leavingOff_whenHooksWouldRejectRvd_refusesAndStaysOff() async throws {
        try await withTempHomeAsync { home, layout, base in
            try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
            #expect(SetupRun.setup(base).exitCode == 0)
            let off = await HostModeRun.setMode(
                .off, for: .grok, env: base, json: true, authenticate: AuthProbe(allow: true).authenticate)
            #expect(off.exitCode == 0)
            try Data("#!/bin/sh\n".utf8).write(to: URL(fileURLWithPath: base.rvdPath))
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: base.rvdPath)
            var environment = base
            environment.daemonTrust = { _ in
                DoctorServiceTrust(source: "manifest", satisfied: false, reason: "installed rvd is ad-hoc signed")
            }
            for mode in [HostMode.block, .observe] {
                let outcome = await HostModeRun.setMode(
                    mode, for: .grok, env: environment, json: true, requester: Self.owner,
                    authenticate: AuthProbe(allow: true).authenticate)
                #expect(outcome.exitCode != 0)
                #expect(outcome.stdout.isEmpty)
                #expect(outcome.stderr.contains("hooks would reject the installed rvd"))
                #expect(FileManager.default.fileExists(atPath: layout.grokHook) == false)
                #expect(store(home).read() == .entries([.grok: .off]))
            }
        }
    }

    @Test func off_underOrganizationGate_exits77AndWritesNothing() async throws {
        try await withTempHomeAsync { home, layout, base in
            var environment = base
            environment.managedEnforce = { _ in true }
            try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
            #expect(SetupRun.setup(environment).exitCode == 0)
            let hook = try Data(contentsOf: URL(fileURLWithPath: layout.grokHook))
            let probe = AuthProbe(allow: true)
            let off = await HostModeRun.setMode(
                .off, for: .grok, env: environment, json: true, authenticate: probe.authenticate)
            #expect(off.exitCode == 77)
            #expect(off.stdout.isEmpty)
            #expect(off.stderr == "rv host mode failed: organization policy requires rv on grok\n")
            #expect(probe.calls == 0)
            #expect(store(home).read() == .entries([:]))
            #expect(try Data(contentsOf: URL(fileURLWithPath: layout.grokHook)) == hook)
            // Observe is still stored: rvd pins enforce under the gate.
            let observe = await HostModeRun.setMode(
                .observe, for: .grok, env: environment, json: true, authenticate: probe.authenticate)
            #expect(observe.exitCode == 0)
            #expect(store(home).read() == .entries([.grok: .observe]))
            let list = HostModeRun.list(environment, json: true)
            #expect(list.stdout.contains(#""managed_enforce":true"#))
        }
    }

    /// A gate that arrives after a host went `off` leaves it unwired until
    /// `rv setup`: list shows it (mode off, not wired, managed_enforce) and
    /// the text form says how to restore it.
    @Test func list_underALaterOrganizationGate_namesTheUnwiredOffHost() async throws {
        try await withTempHomeAsync { _, layout, base in
            try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
            #expect(SetupRun.setup(base).exitCode == 0)
            let off = await HostModeRun.setMode(
                .off, for: .grok, env: base, json: true, authenticate: AuthProbe(allow: true).authenticate)
            #expect(off.exitCode == 0)
            #expect(HostModeRun.list(base, json: false).stdout.contains("rv setup") == false)
            var gated = base
            gated.managedEnforce = { _ in true }
            let json = HostModeRun.list(gated, json: true).stdout
            #expect(json.contains(#"{"host":"grok","mode":"off","wiring":"absent-file"}"#))
            #expect(json.contains(#""managed_enforce":true"#))
            let text = HostModeRun.list(gated, json: false).stdout
            #expect(text.contains("grok  off  absent-file\n"))
            #expect(text.hasSuffix("off and unwired under the organization gate: grok; run rv setup to restore\n"))
        }
    }

    @Test func setup_underOrganizationGate_wiresHostsStoredOff() async throws {
        try await withTempHomeAsync { home, layout, base in
            try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
            try store(home).save(.off, for: .grok)
            #expect(SetupRun.setup(base).exitCode == 0)
            #expect(FileManager.default.fileExists(atPath: layout.grokHook) == false)
            var gated = base
            gated.managedEnforce = { _ in true }
            #expect(SetupRun.setup(gated).exitCode == 0)
            #expect(FileManager.default.fileExists(atPath: layout.grokHook))
        }
    }

    /// Duplicate `guard` keys read as enforce at rvd. `block` tightens, so it
    /// asks no owner, and it must not rewrite the file to the first
    /// (observe) copy either: it refuses and names the fix.
    @Test func block_onADuplicateKeyConfig_refusesAndLeavesTheFile() async throws {
        try await withTempHomeAsync { home, _, environment in
            let text = Data(#"{"guard":{"mode":"observe"},"guard":{"mode":"enforce"}}"#.utf8)
            let file = store(home).configFile
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: file)
            let probe = AuthProbe(allow: false)
            let outcome = await HostModeRun.setMode(
                .block, for: .claude, env: environment, json: true, authenticate: probe.authenticate)
            #expect(outcome.exitCode == EX_DATAERR)
            #expect(outcome.stdout.isEmpty)
            #expect(outcome.stderr.hasPrefix("rv host mode failed:"))
            #expect(outcome.stderr.contains("fix config.json by hand"))
            #expect(probe.calls == 0)
            #expect(try Data(contentsOf: file) == text)
        }
    }

    @Test func notTheInstalledCopy_exits64() async throws {
        try await withTempHomeAsync { _, _, base in
            var environment = base
            environment.runningExecutable = "/somewhere/else/rv-cli"
            let outcome = await HostModeRun.setMode(
                .block, for: .grok, env: environment, json: true, authenticate: AuthProbe(allow: true).authenticate)
            #expect(outcome.exitCode == 64)
            #expect(outcome.stderr.hasPrefix("rv host mode failed:"))
        }
    }

    // MARK: F3: a tighten that can't lock you out (Q4, 2026-11-27)

    static let utc = TimeZone(identifier: "UTC")!
    /// 14:12 UTC.
    static let t0 = Date(timeIntervalSince1970: 1_764_252_720)
    /// An agent in Claude Code (CLAUDECODE=1), no terminal.
    static let claudeAgent = HostModeRequester(atTerminal: false, callingHosts: [.claude])

    /// grok wired and stored `observe` by the owner.
    private func observedGrok(_ environment: SetupEnvironment, _ layout: OwnedPaths) async throws {
        try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
        #expect(SetupRun.setup(environment).exitCode == 0)
        let observe = await HostModeRun.setMode(
            .observe, for: .grok, env: environment, json: true, authenticate: AuthProbe(allow: true).authenticate)
        #expect(observe.exitCode == 0)
    }

    @Test func agentBlockOfAnotherHost_holdsForAnHour_thenTheStoredModeIsBack() async throws {
        try await withTempHomeAsync { home, layout, environment in
            try await observedGrok(environment, layout)
            let probe = AuthProbe(allow: false)
            let block = await HostModeRun.setMode(
                .block, for: .grok, env: environment, json: false, requester: Self.claudeAgent,
                now: Self.t0, timeZone: Self.utc, authenticate: probe.authenticate)
            #expect(block.exitCode == 0)
            #expect(block.stdout == """
                grok  block  wired  until 15:12
                  An agent's block ends on its own after an hour; then grok is back to observe.
                  To keep it blocked, you type:
                → rv host mode grok block

                """)
            #expect(probe.calls == 0)
            // The owner's mode is never overwritten: it is what comes back.
            #expect(store(home).read() == .entries([.grok: .observe]))
            let during = HostModeRun.list(environment, json: false, now: Self.t0.addingTimeInterval(600), timeZone: Self.utc)
            #expect(during.stdout.contains("grok  block  wired  until 15:12\n"))
            let duringJSON = HostModeRun.list(environment, json: true, now: Self.t0.addingTimeInterval(600))
            #expect(duringJSON.stdout.contains(#"{"host":"grok","mode":"block","until":"2025-11-27T15:12:00Z","wiring":"wired"}"#))

            // A fresh read an hour on, as a restarted rvd does: back to
            // observe with nothing written.
            let config = GuardConfig.read(home: environment.home)
            #expect(GuardModeResolution.resolve(config, host: .grok, environment: [:], now: Self.t0.addingTimeInterval(3599)) == .enforce)
            #expect(GuardModeResolution.resolve(config, host: .grok, environment: [:], now: Self.t0.addingTimeInterval(3600)) == .observe)
            let after = HostModeRun.list(environment, json: false, now: Self.t0.addingTimeInterval(3600), timeZone: Self.utc)
            #expect(after.stdout.contains("grok  observe  wired\n"))
        }
    }

    @Test func agentBlockOfAnotherHost_json_namesTheEndAndWhatComesBack() async throws {
        try await withTempHomeAsync { _, layout, environment in
            try await observedGrok(environment, layout)
            let block = await HostModeRun.setMode(
                .block, for: .grok, env: environment, json: true, requester: Self.claudeAgent,
                now: Self.t0, authenticate: AuthProbe(allow: false).authenticate)
            #expect(block.exitCode == 0)
            #expect(block.stdout == #"{"host":"grok","mode":"block","schema":"rv.host-mode.v1","then":"observe","until":"2025-11-27T15:12:00Z","wiring":"wired"}"# + "\n")
        }
    }

    /// Asking again neither extends the block nor makes it permanent.
    @Test func agentBlockAgain_isNotExtendedOrMadePermanent() async throws {
        try await withTempHomeAsync { home, layout, environment in
            try await observedGrok(environment, layout)
            _ = await HostModeRun.setMode(
                .block, for: .grok, env: environment, json: false, requester: Self.claudeAgent,
                now: Self.t0, timeZone: Self.utc, authenticate: AuthProbe(allow: false).authenticate)
            let again = await HostModeRun.setMode(
                .block, for: .grok, env: environment, json: false, requester: Self.claudeAgent,
                now: Self.t0.addingTimeInterval(1800), timeZone: Self.utc, authenticate: AuthProbe(allow: false).authenticate)
            #expect(again.exitCode == 0)
            #expect(again.stdout.contains("An agent already blocked grok; it ends on its own at 15:12."))
            #expect(store(home).read() == .entries([.grok: .observe]))
            let window = try #require(store(home).readGuardConfig()?.temporaryBlocks[.grok])
            #expect(window.until == Self.t0.addingTimeInterval(3600))
        }
    }

    /// Acceptance: no agent path can put the agent's own host into block.
    @Test func agentBlockOfItsOwnHost_isAProposal_andChangesNothing() async throws {
        try await withTempHomeAsync { home, layout, environment in
            try await observedGrok(environment, layout)
            let config = store(home).configFile
            let before = try Data(contentsOf: config)
            let grokAgent = HostModeRequester(atTerminal: false, callingHosts: [.grok])
            let sink = RecordingProposals()
            let probe = AuthProbe(allow: true)
            let outcome = await HostModeRun.setMode(
                .block, for: .grok, env: environment, json: false, requester: grokAgent,
                now: Self.t0, proposals: sink, authenticate: probe.authenticate)
            #expect(outcome.exitCode == 77)
            #expect(outcome.stdout == """
                ⏺ asks  block grok: you decide
                  Blocking grok would stop the agent that asked, so nothing changed.
                  To do it, you type:
                → rv host mode grok block

                """)
            #expect(probe.calls == 0)
            #expect(sink.submitted == [HostModeProposal(host: .grok, mode: .block, reason: .ownHost)])
            #expect(try Data(contentsOf: config) == before)
            let resolved = GuardModeResolution.resolve(
                GuardConfig.read(home: environment.home), host: .grok, environment: [:], now: Self.t0)
            #expect(resolved == .observe)
        }
    }

    @Test func blockWithNoAgentMarkerOrOfAnOffHost_isAProposal() async throws {
        try await withTempHomeAsync { home, layout, environment in
            try await observedGrok(environment, layout)
            let unknown = await HostModeRun.setMode(
                .block, for: .grok, env: environment, json: true, now: Self.t0,
                authenticate: AuthProbe(allow: true).authenticate)
            #expect(unknown.exitCode == 77)
            #expect(unknown.stdout == #"{"host":"grok","mode":"block","proposed":true,"reason":"unknown-caller","schema":"rv.host-mode-proposal.v1"}"# + "\n")

            let off = await HostModeRun.setMode(
                .off, for: .grok, env: environment, json: true, authenticate: AuthProbe(allow: true).authenticate)
            #expect(off.exitCode == 0)
            let fromOff = await HostModeRun.setMode(
                .block, for: .grok, env: environment, json: false, requester: Self.claudeAgent, now: Self.t0,
                authenticate: AuthProbe(allow: true).authenticate)
            #expect(fromOff.exitCode == 77)
            #expect(fromOff.stdout.contains("grok is off; an agent can't wire it back in as block, so nothing changed."))
            #expect(FileManager.default.fileExists(atPath: layout.grokHook) == false)
            #expect(store(home).read() == .entries([.grok: .off]))
        }
    }

    /// Ending an agent's block early loosens: it needs the owner, and with
    /// the owner the block is gone and the asked mode stands.
    @Test func endingAnAgentsBlockEarly_needsTheOwner() async throws {
        try await withTempHomeAsync { home, layout, environment in
            try await observedGrok(environment, layout)
            _ = await HostModeRun.setMode(
                .block, for: .grok, env: environment, json: true, requester: Self.claudeAgent,
                now: Self.t0, authenticate: AuthProbe(allow: false).authenticate)
            let refused = AuthProbe(allow: false)
            let early = await HostModeRun.setMode(
                .observe, for: .grok, env: environment, json: true, requester: Self.claudeAgent,
                now: Self.t0.addingTimeInterval(60), authenticate: refused.authenticate)
            #expect(early.exitCode == 77)
            #expect(refused.calls == 1)
            #expect(store(home).readGuardConfig()?.temporaryBlocks[.grok] != nil)

            let owner = AuthProbe(allow: true)
            let ended = await HostModeRun.setMode(
                .observe, for: .grok, env: environment, json: true, requester: Self.owner,
                now: Self.t0.addingTimeInterval(60), authenticate: owner.authenticate)
            #expect(ended.exitCode == 0)
            #expect(owner.calls == 1)
            // The record stays, ended now: the cooldown counts from here.
            let ended60 = Self.t0.addingTimeInterval(60)
            #expect(store(home).readGuardConfig()?.temporaryBlocks[.grok] == GuardWindow(from: Self.t0, until: ended60))
            #expect(GuardModeResolution.resolve(
                GuardConfig.read(home: environment.home), host: .grok, environment: [:], now: ended60) == .observe)
            #expect(store(home).read() == .entries([.grok: .observe]))

            let reAsk = await HostModeRun.setMode(
                .block, for: .grok, env: environment, json: true, requester: Self.claudeAgent,
                now: Self.t0.addingTimeInterval(120), authenticate: AuthProbe(allow: false).authenticate)
            #expect(reAsk.exitCode == 77)
            #expect(reAsk.stdout.contains(#""reason":"cooldown""#))
        }
    }

    /// Acceptance: an agent re-asking as each block ends cannot keep a host
    /// blocked; inside six hours of the end it is a proposal.
    @Test func agentReAskRightAfterExpiry_isAProposalUntilTheCooldownEnds() async throws {
        try await withTempHomeAsync { home, layout, environment in
            try await observedGrok(environment, layout)
            let first = await HostModeRun.setMode(
                .block, for: .grok, env: environment, json: true, requester: Self.claudeAgent,
                now: Self.t0, authenticate: AuthProbe(allow: false).authenticate)
            #expect(first.exitCode == 0)
            let end = Self.t0.addingTimeInterval(3600)
            let reAsk = await HostModeRun.setMode(
                .block, for: .grok, env: environment, json: false, requester: Self.claudeAgent,
                now: end.addingTimeInterval(1), timeZone: Self.utc, authenticate: AuthProbe(allow: false).authenticate)
            #expect(reAsk.exitCode == 77)
            #expect(reAsk.stdout.contains(
                "An agent's block of grok ended less than 6 hours ago; another waits for you, so nothing changed."))
            #expect(store(home).readGuardConfig()?.temporaryBlocks[.grok]?.until == end)
            #expect(GuardModeResolution.resolve(
                GuardConfig.read(home: environment.home), host: .grok, environment: [:], now: end.addingTimeInterval(1))
                == .observe)

            let later = await HostModeRun.setMode(
                .block, for: .grok, env: environment, json: true, requester: Self.claudeAgent,
                now: end.addingTimeInterval(6 * 3600), authenticate: AuthProbe(allow: false).authenticate)
            #expect(later.exitCode == 0)
            #expect(store(home).readGuardConfig()?.temporaryBlocks[.grok]?.until == end.addingTimeInterval(6 * 3600 + 3600))
        }
    }

    /// The owner prompt needs stdin and stdout on a terminal and no agent
    /// marker; anything else goes to HostTighten unprompted.
    @Test(arguments: [
        (stdin: true, stdout: true, env: [String: String](), atTerminal: true),
        (stdin: true, stdout: false, env: [:], atTerminal: false),
        (stdin: false, stdout: true, env: [:], atTerminal: false),
        (stdin: true, stdout: true, env: ["CLAUDECODE": "1"], atTerminal: false),
    ])
    func liveRequester_needsBothTTYsAndNoMarker(stdin: Bool, stdout: Bool, env: [String: String], atTerminal: Bool) {
        let requester = CLIProcess.$context.withValue(
            CLIProcess.Context(environment: env, stdinIsTTY: stdin, stdoutIsTTY: stdout)) { HostModeRequester.live() }
        #expect(requester.atTerminal == atTerminal)
        #expect(requester.callingHosts == (env.isEmpty ? [] : [.claude]))
    }

    /// An agent holding a pty (both TTYs, its marker set) never raises the
    /// owner prompt for a permanent block: it gets the one-hour block.
    @Test func agentWithAPty_isNotPrompted_andGetsTheOneHourBlock() async throws {
        try await withTempHomeAsync { home, layout, environment in
            try await observedGrok(environment, layout)
            let probe = AuthProbe(allow: true)
            let context = CLIProcess.Context(environment: ["CLAUDECODE": "1"], stdinIsTTY: true, stdoutIsTTY: true)
            let outcome = await CLIProcess.$context.withValue(context) {
                await HostModeRun.setMode(
                    .block, for: .grok, env: environment, json: true, requester: .live(), now: Self.t0,
                    authenticate: probe.authenticate)
            }
            #expect(outcome.exitCode == 0)
            #expect(outcome.stdout.contains(#""until":"2025-11-27T15:12:00Z""#))
            #expect(probe.calls == 0)
            #expect(store(home).read() == .entries([.grok: .observe]))
        }
    }

    /// The owner at a terminal sets block for good (and an agent's block
    /// under it is replaced); a refused check changes nothing.
    @Test func ownerAtTerminal_blocksForGood_orNothingChanges() async throws {
        try await withTempHomeAsync { home, layout, environment in
            try await observedGrok(environment, layout)
            let before = try Data(contentsOf: store(home).configFile)
            let refused = AuthProbe(allow: false)
            let no = await HostModeRun.setMode(
                .block, for: .grok, env: environment, json: true, requester: Self.owner,
                now: Self.t0, authenticate: refused.authenticate)
            #expect(no.exitCode == 77)
            #expect(refused.calls == 1)
            #expect(try Data(contentsOf: store(home).configFile) == before)

            _ = await HostModeRun.setMode(
                .block, for: .grok, env: environment, json: true, requester: Self.claudeAgent,
                now: Self.t0, authenticate: AuthProbe(allow: false).authenticate)
            let yes = await HostModeRun.setMode(
                .block, for: .grok, env: environment, json: true, requester: Self.owner,
                now: Self.t0.addingTimeInterval(60), authenticate: AuthProbe(allow: true).authenticate)
            #expect(yes.exitCode == 0)
            #expect(yes.stdout == #"{"host":"grok","mode":"block","schema":"rv.host-mode.v1","wiring":"wired"}"# + "\n")
            #expect(store(home).read() == .entries([.grok: .block]))
            #expect(store(home).readGuardConfig()?.temporaryBlocks.isEmpty == true)
            let later = GuardModeResolution.resolve(
                GuardConfig.read(home: environment.home), host: .grok, environment: [:],
                now: Self.t0.addingTimeInterval(86_400))
            #expect(later == .enforce)
        }
    }

    /// The owner check is the real abstraction's test double: an
    /// unattended context (no `.authenticated` seam) never passes it.
    @Test func ownerCheck_throughTheSeam_failsClosedWithoutTheOwner() async throws {
        try await withTempHomeAsync { home, layout, environment in
            try await observedGrok(environment, layout)
            let outcome = await CLIProcess.$context.withValue(CLIProcess.Context(stdinIsTTY: true, stdoutIsTTY: true)) {
                await HostModeRun.setMode(
                    .block, for: .grok, env: environment, json: true, requester: .live(), now: Self.t0,
                    authenticate: { try await CLIOwnerAuth.requireAuthenticated(reason: "test") })
            }
            #expect(outcome.exitCode == 77)
            #expect(store(home).read() == .entries([.grok: .observe]))
        }
    }

    /// The owner at a terminal: a block asks the owner check and is permanent.
    static let owner = HostModeRequester(atTerminal: true, callingHosts: [])

    private func store(_ home: URL) -> HostModeStore {
        HostModeStore(configDirectory: home.appendingPathComponent(".config/rv", isDirectory: true))
    }

    private func withTempHomeAsync(
        _ body: (URL, OwnedPaths, SetupEnvironment) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-host-mode-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dummyRvd = root.appendingPathComponent("rvd")
        try "#!/bin/sh\n".write(to: dummyRvd, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dummyRvd.path)
        let layout = OwnedPaths(home: try #require(HomeDirectory(validating: root.path)))
        var environment = env(home: root, launchctl: RecordingLaunchctl(), rvPath: try installedRv(in: root))
        environment.managedEnforce = { _ in false }
        try await body(root, layout, environment)
    }

    /// Doctor-grade `wired` needs an executable baked `rv` with `rv-cli` beside it.
    private func installedRv(in home: URL) throws -> String {
        let bin = home.appendingPathComponent("bin", isDirectory: true)
        try makeExecutable(bin.appendingPathComponent("rv"))
        try makeExecutable(bin.appendingPathComponent("rv-cli"))
        return bin.appendingPathComponent("rv").path
    }
}
