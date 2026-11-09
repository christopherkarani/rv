import Foundation
import Testing
import RVDomain
import RVPolicy
@testable import RVCLI

private struct ObserveAuthRefused: Error {}

/// Records whether the owner check ran; `allow` decides its outcome.
private final class ObserveAuthProbe: @unchecked Sendable {
    private(set) var calls = 0
    let allow: Bool

    init(allow: Bool) {
        self.allow = allow
    }

    func authenticate() async throws {
        calls += 1
        if allow == false { throw ObserveAuthRefused() }
    }
}

/// `rv setup --observe`: install straight into observe mode. Going to
/// observe sheds oversight only when rv is already enforcing a wired host;
/// then the owner must authenticate, like `rv host mode <host> observe`.
struct SetupObserveTests {
    @Test func flagParses() throws {
        #expect(try Setup.parse(["--observe"]).observe)
        #expect(try Setup.parse([]).observe == false)
    }

    @Test func freshInstall_writesObserveWithoutOwnerAuth_andWires() async throws {
        try await withObserveHome { home, layout, environment in
            try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
            let probe = ObserveAuthProbe(allow: false)
            let outcome = await observeSetup(environment, probe: probe)
            #expect(outcome.exitCode == 0)
            #expect(probe.calls == 0)
            #expect(try guardMode(home) == "observe")
            #expect(FileManager.default.fileExists(atPath: layout.grokHook))
            #expect(outcome.stderr.contains("rv setup: observe mode on"))
        }
    }

    @Test func observe_keepsEveryOtherConfigKey() async throws {
        try await withObserveHome { home, _, environment in
            try writeConfig(home, #"{"analytics.enabled":false,"guard":{"hosts":{"cursor":"off"}}}"#)
            let outcome = await observeSetup(environment, probe: ObserveAuthProbe(allow: false))
            #expect(outcome.exitCode == 0)
            let root = try config(home)
            #expect(root["analytics.enabled"] as? Bool == false)
            let guardObject = try #require(root["guard"] as? [String: Any])
            #expect(guardObject["mode"] as? String == "observe")
            #expect(guardObject["hosts"] as? [String: String] == ["cursor": "off"])
        }
    }

    @Test func overEnforcingInstall_ownerRefuses_exits77AndWritesNothing() async throws {
        try await withObserveHome { home, layout, environment in
            try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
            #expect(SetupRun.setup(environment).exitCode == 0)
            let before = try? Data(contentsOf: configURL(home))
            let probe = ObserveAuthProbe(allow: false)
            let outcome = await observeSetup(environment, probe: probe)
            #expect(outcome.exitCode == 77)
            #expect(outcome.stderr.contains("device-owner authentication required"))
            #expect(probe.calls == 1)
            #expect((try? Data(contentsOf: configURL(home))) == before)
        }
    }

    @Test func overEnforcingInstall_ownerAuthenticates_writesObserve() async throws {
        try await withObserveHome { home, layout, environment in
            try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
            #expect(SetupRun.setup(environment).exitCode == 0)
            let probe = ObserveAuthProbe(allow: true)
            let outcome = await observeSetup(environment, probe: probe)
            #expect(outcome.exitCode == 0)
            #expect(probe.calls == 1)
            #expect(try guardMode(home) == "observe")
        }
    }

    @Test func alreadyObserving_needsNoOwnerAuth() async throws {
        try await withObserveHome { home, layout, environment in
            try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
            #expect(SetupRun.setup(environment).exitCode == 0)
            try writeConfig(home, #"{"guard":{"mode":"observe"}}"#)
            let probe = ObserveAuthProbe(allow: false)
            let outcome = await observeSetup(environment, probe: probe)
            #expect(outcome.exitCode == 0)
            #expect(probe.calls == 0)
        }
    }

    /// The synchronous door has no owner prompt, so a loosening through it
    /// fails closed instead of skipping authentication.
    @Test func syncDoor_overEnforcingInstall_failsClosed() throws {
        try withTempHome { home, layout, launchctl in
            try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
            var environment = env(home: home, launchctl: launchctl, rvPath: try observeInstalledRv(in: home))
            environment.managedEnforce = { _ in false }
            #expect(SetupRun.setup(environment).exitCode == 0)
            let outcome = SetupFlow(makeEnvironment: { environment })
                .run(SetupIntent(kind: .install, observe: true))
            #expect(outcome.exitCode == 77)
            #expect(try guardMode(home) == nil)
        }
    }

    @Test func organizationGate_refusesBeforeWritingAnything() async throws {
        try await withObserveHome { home, layout, base in
            try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
            var environment = base
            environment.managedEnforce = { _ in true }
            let probe = ObserveAuthProbe(allow: true)
            let outcome = await observeSetup(environment, probe: probe)
            #expect(outcome.exitCode == 77)
            #expect(outcome.stderr.contains("organization policy pins enforce"))
            #expect(outcome.stderr.contains("rv setup without --observe"))
            #expect(probe.calls == 0)
            #expect(FileManager.default.fileExists(atPath: configURL(home).path) == false)
            #expect(FileManager.default.fileExists(atPath: layout.grokHook) == false)
        }
    }

    @Test func plainSetup_neverWritesGuardMode() async throws {
        try await withObserveHome { home, layout, environment in
            try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
            let outcome = await SetupFlow(makeEnvironment: { environment })
                .run(SetupIntent(kind: .install), authenticate: ObserveAuthProbe(allow: true).authenticate)
            #expect(outcome.exitCode == 0)
            #expect(try guardMode(home) == nil)
        }
    }

    @Test func hostsPinnedToBlock_areNamed() async throws {
        try await withObserveHome { home, _, environment in
            try writeConfig(home, #"{"guard":{"hosts":{"claude":"block","cursor":"observe"}}}"#)
            let outcome = await observeSetup(environment, probe: ObserveAuthProbe(allow: false))
            #expect(outcome.exitCode == 0)
            #expect(outcome.stderr.contains("claude stays block (rv host mode claude observe to change)"))
            #expect(outcome.stderr.contains("cursor stays") == false)
            #expect(try HostModeStore(configDirectory: configURL(home).deletingLastPathComponent()).load()
                == [.claude: .block, .cursor: .observe])
        }
    }

    @Test func unreadableGuardObject_refusesBeforeWiring() async throws {
        try await withObserveHome { home, layout, environment in
            try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
            try writeConfig(home, #"{"guard":"loud"}"#)
            let outcome = await observeSetup(environment, probe: ObserveAuthProbe(allow: true))
            #expect(outcome.exitCode == 73)
            #expect(outcome.stderr.contains("unable to write guard.mode"))
            #expect(try String(contentsOf: configURL(home), encoding: .utf8) == #"{"guard":"loud"}"#)
            #expect(FileManager.default.fileExists(atPath: layout.grokHook) == false)
        }
    }

    // MARK: - Helpers

    private func observeSetup(_ environment: SetupEnvironment, probe: ObserveAuthProbe) async -> SetupOutcome {
        await SetupFlow(makeEnvironment: { environment })
            .run(SetupIntent(kind: .install, observe: true), authenticate: probe.authenticate)
    }

    private func configURL(_ home: URL) -> URL {
        home.appendingPathComponent(".config/rv/config.json")
    }

    private func writeConfig(_ home: URL, _ text: String) throws {
        try FileManager.default.createDirectory(
            at: configURL(home).deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: configURL(home))
    }

    private func config(_ home: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: configURL(home))) as? [String: Any])
    }

    private func guardMode(_ home: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: configURL(home).path) else { return nil }
        return (try config(home)["guard"] as? [String: Any])?["mode"] as? String
    }

    private func withObserveHome(
        _ body: (URL, OwnedPaths, SetupEnvironment) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-setup-observe-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let dummyRvd = root.appendingPathComponent("rvd")
        try "#!/bin/sh\n".write(to: dummyRvd, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dummyRvd.path)
        let layout = OwnedPaths(home: try #require(HomeDirectory(validating: root.path)))
        var environment = env(home: root, launchctl: RecordingLaunchctl(), rvPath: try observeInstalledRv(in: root))
        environment.managedEnforce = { _ in false }
        try await body(root, layout, environment)
    }
}

/// Doctor-grade `wired` needs an executable baked `rv` with `rv-cli` beside it.
private func observeInstalledRv(in home: URL) throws -> String {
    let bin = home.appendingPathComponent("bin", isDirectory: true)
    try makeExecutable(bin.appendingPathComponent("rv"))
    try makeExecutable(bin.appendingPathComponent("rv-cli"))
    return bin.appendingPathComponent("rv").path
}
