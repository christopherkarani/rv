import ArgumentParser
import Foundation
import Testing
import RVDomain
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

            let probe = AuthProbe(allow: false)
            let block = await HostModeRun.setMode(
                .block, for: .grok, env: environment, json: true, authenticate: probe.authenticate)
            #expect(block.exitCode == 0)
            #expect(block.stdout == #"{"host":"grok","mode":"block","schema":"rv.host-mode.v1","wiring":"wired"}"# + "\n")
            #expect(probe.calls == 0)
            #expect(store(home).load() == [.grok: .block])
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
            #expect(store(home).load().isEmpty)
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
            #expect(store(home).load() == [.grok: .observe])
            // Same mode again is not a loosening: no prompt.
            let again = AuthProbe(allow: false)
            let repeated = await HostModeRun.setMode(
                .observe, for: .grok, env: environment, json: true, authenticate: again.authenticate)
            #expect(repeated.exitCode == 0)
            #expect(again.calls == 0)
        }
    }

    @Test func off_removesOnlyThatHostsHooks_andBlockRewiresWithoutAuth() async throws {
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
            #expect(store(home).load() == [.grok: .off])

            // `rv setup` leaves an off host unwired.
            #expect(SetupRun.setup(environment).exitCode == 0)
            #expect(FileManager.default.fileExists(atPath: layout.grokHook) == false)

            let probe = AuthProbe(allow: false)
            let block = await HostModeRun.setMode(
                .block, for: .grok, env: environment, json: false, authenticate: probe.authenticate)
            #expect(block.exitCode == 0)
            #expect(block.stdout == "grok  block  wired\n")
            #expect(probe.calls == 0)
            #expect(FileManager.default.fileExists(atPath: layout.grokHook))
            #expect(store(home).load() == [.grok: .block])
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
            #expect(store(home).load().isEmpty)
            let retry = AuthProbe(allow: false)
            let again = await HostModeRun.setMode(
                .off, for: .grok, env: environment, json: true, authenticate: retry.authenticate)
            #expect(again.exitCode == 77)
            #expect(retry.calls == 1)
        }
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
                .block, for: .grok, env: environment, json: true, authenticate: AuthProbe(allow: false).authenticate)
            #expect(block.exitCode == 73)
            #expect(block.stderr.hasPrefix("rv host mode failed: unable to write grok hook"))
            #expect(FileManager.default.fileExists(atPath: layout.grokHook) == false)
            #expect(store(home).load() == [.grok: .block])
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
                    mode, for: .grok, env: environment, json: true,
                    authenticate: AuthProbe(allow: true).authenticate)
                #expect(outcome.exitCode != 0)
                #expect(outcome.stdout.isEmpty)
                #expect(outcome.stderr.contains("hooks would reject the installed rvd"))
                #expect(FileManager.default.fileExists(atPath: layout.grokHook) == false)
                #expect(store(home).load() == [.grok: .off])
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
            #expect(store(home).load().isEmpty)
            #expect(try Data(contentsOf: URL(fileURLWithPath: layout.grokHook)) == hook)
            // Observe is still stored: rvd pins enforce under the gate.
            let observe = await HostModeRun.setMode(
                .observe, for: .grok, env: environment, json: true, authenticate: probe.authenticate)
            #expect(observe.exitCode == 0)
            #expect(store(home).load() == [.grok: .observe])
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
