import Foundation
import RVDomain
import RVPolicy
import RVPresentation
import Testing
@testable import RVCLI

@Test func setupPlan_missingAndOccupiedAndWrite() throws {
    let path = OwnedPaths(home: try #require(HomeDirectory(validating: "/tmp"))).hostAdapter(for: .grok)
    let payload = Data("wired".utf8)
    #expect(HostAdapterInstallation.missing(path).setupPlan(force: false) == .skipUndetected)
    #expect(HostAdapterInstallation.missing(path).setupPlan(force: true) == .skipUndetected)
    #expect(HostAdapterInstallation.occupied(path).setupPlan(force: false) == .skipOccupied)
    #expect(HostAdapterInstallation.occupied(path).setupPlan(force: true) == .forceClearThenWrite)
    #expect(HostAdapterInstallation.absentFile(path).setupPlan(force: false) == .write(existingData: nil))
    #expect(
        HostAdapterInstallation.broken(path: path, existingData: payload).setupPlan(force: false)
            == .write(existingData: payload)
    )
    #expect(
        HostAdapterInstallation.wired(path: path, existingData: payload).setupPlan(force: false)
            == .write(existingData: payload)
    )
}

@Test func uninstallPlan_removeOccupiedSkip() throws {
    let path = OwnedPaths(home: try #require(HomeDirectory(validating: "/tmp"))).hostAdapter(for: .pi)
    let payload = Data("x".utf8)
    #expect(HostAdapterInstallation.broken(path: path, existingData: payload).uninstallPlan == .remove)
    #expect(HostAdapterInstallation.wired(path: path, existingData: payload).uninstallPlan == .remove)
    #expect(HostAdapterInstallation.occupied(path).uninstallPlan == .leaveOccupied)
    #expect(HostAdapterInstallation.missing(path).uninstallPlan == .skip)
    #expect(HostAdapterInstallation.absentFile(path).uninstallPlan == .skip)
}

@Test func workPlan_occupiedGrokAndAbsentPi_skipsGrokWritesPiWithoutFilesystem() throws {
    let homePath = "/tmp/rv-workplan-absent-\(UUID().uuidString)"
    let layout = OwnedPaths(home: try #require(HomeDirectory(validating: homePath)))
    let installations = HostAdapterInstallationSnapshot(
        grok: .occupied(layout.hostAdapter(for: .grok)),
        pi: .absentFile(layout.hostAdapter(for: .pi)),
        openCode: .missing(layout.hostAdapter(for: .opencode)),
        claude: .missing(layout.hostAdapter(for: .claude)),
        openClaw: .missing(layout.hostAdapter(for: .openclaw)),
        hermes: .missing(layout.hostAdapter(for: .hermes)),
        codex: .missing(layout.hostAdapter(for: .codex)),
        cursor: .missing(layout.hostAdapter(for: .cursor))
    )

    let plan = SetupWorkPlanBuilder.make(
        installations: installations,
        layout: layout,
        force: false,
        rvdIsExecutable: true
    )

    #expect(plan.steps == [
        .createConfigDirectory,
        .skipOccupied(.grok),
        .write(HostArtifacts.attach(host: .pi, layout: layout, existingData: nil, forceClear: false)),
        .skipUndetected(.opencode),
        .skipUndetected(.claude),
        .skipUndetected(.openclaw),
        .skipUndetected(.hermes),
        .skipUndetected(.codex),
        .skipUndetected(.cursor),
        .writeLaunchAgent,
    ])
    #expect(
        FileManager.default.fileExists(atPath: homePath) == false,
        "plan builder must not create HOME"
    )
}

@Test func workPlan_rvdNotExecutable_skipsLaunchAgent() throws {
    let homePath = "/tmp/rv-workplan-no-rvd-\(UUID().uuidString)"
    let layout = OwnedPaths(home: try #require(HomeDirectory(validating: homePath)))
    let installations = HostAdapterInstallationSnapshot(
        grok: .missing(layout.hostAdapter(for: .grok)),
        pi: .missing(layout.hostAdapter(for: .pi)),
        openCode: .missing(layout.hostAdapter(for: .opencode)),
        claude: .missing(layout.hostAdapter(for: .claude)),
        openClaw: .missing(layout.hostAdapter(for: .openclaw)),
        hermes: .missing(layout.hostAdapter(for: .hermes)),
        codex: .missing(layout.hostAdapter(for: .codex)),
        cursor: .missing(layout.hostAdapter(for: .cursor))
    )

    let plan = SetupWorkPlanBuilder.make(
        installations: installations,
        layout: layout,
        force: false,
        rvdIsExecutable: false
    )

    #expect(plan.steps.contains(.skipLaunchAgent))
    #expect(plan.steps.contains(.writeLaunchAgent) == false)
    #expect(plan.steps == [
        .createConfigDirectory,
        .skipUndetected(.grok),
        .skipUndetected(.pi),
        .skipUndetected(.opencode),
        .skipUndetected(.claude),
        .skipUndetected(.openclaw),
        .skipUndetected(.hermes),
        .skipUndetected(.codex),
        .skipUndetected(.cursor),
        .skipLaunchAgent,
    ])
    #expect(
        FileManager.default.fileExists(atPath: homePath) == false,
        "plan builder must not create HOME"
    )
}

@Test func workPlan_forceOccupied_isForceClearThenWrite() throws {
    let layout = OwnedPaths(home: try #require(HomeDirectory(validating: "/tmp")))
    let installations = HostAdapterInstallationSnapshot(
        grok: .occupied(layout.hostAdapter(for: .grok)),
        pi: .missing(layout.hostAdapter(for: .pi)),
        openCode: .missing(layout.hostAdapter(for: .opencode)),
        claude: .missing(layout.hostAdapter(for: .claude)),
        openClaw: .missing(layout.hostAdapter(for: .openclaw)),
        hermes: .missing(layout.hostAdapter(for: .hermes)),
        codex: .missing(layout.hostAdapter(for: .codex)),
        cursor: .missing(layout.hostAdapter(for: .cursor))
    )

    let plan = SetupWorkPlanBuilder.make(
        installations: installations,
        layout: layout,
        force: true,
        rvdIsExecutable: true
    )

    let grokForce = HostArtifacts.attach(
        host: .grok,
        layout: layout,
        existingData: nil,
        forceClear: true
    )
    #expect(plan.steps.contains(.forceClearThenWrite(grokForce)))
    #expect(plan.steps.contains(.skipOccupied(.grok)) == false)
    #expect(plan.steps == [
        .createConfigDirectory,
        .forceClearThenWrite(grokForce),
        .skipUndetected(.pi),
        .skipUndetected(.opencode),
        .skipUndetected(.claude),
        .skipUndetected(.openclaw),
        .skipUndetected(.hermes),
        .skipUndetected(.codex),
        .skipUndetected(.cursor),
        .writeLaunchAgent,
    ])
}

@Test func workPlan_claudeWrite_carriesSettingsMergeWithoutForce() throws {
    let layout = OwnedPaths(home: try #require(HomeDirectory(validating: "/tmp")))
    let payload = Data("settings".utf8)
    let installations = HostAdapterInstallationSnapshot(
        grok: .missing(layout.hostAdapter(for: .grok)),
        pi: .missing(layout.hostAdapter(for: .pi)),
        openCode: .missing(layout.hostAdapter(for: .opencode)),
        claude: .wired(path: layout.hostAdapter(for: .claude), existingData: payload),
        openClaw: .missing(layout.hostAdapter(for: .openclaw)),
        hermes: .missing(layout.hostAdapter(for: .hermes)),
        codex: .missing(layout.hostAdapter(for: .codex)),
        cursor: .missing(layout.hostAdapter(for: .cursor))
    )

    let plan = SetupWorkPlanBuilder.make(
        installations: installations,
        layout: layout,
        force: false,
        rvdIsExecutable: true
    )
    let write = HostArtifacts.attach(
        host: .claude,
        layout: layout,
        existingData: payload,
        forceClear: false
    )

    #expect(write.adapter == .claudeSettingsMerge(force: false))
    #expect(write.prelude == .none)
    #expect(write.existing == .useOrReread(payload))
    #expect(write.companions.isEmpty)
    #expect(plan.steps.contains(.write(write)))
}

@Test func workPlan_claudeForceOccupied_carriesSettingsMergeAndSymlinkPrelude() throws {
    let layout = OwnedPaths(home: try #require(HomeDirectory(validating: "/tmp")))
    let installations = HostAdapterInstallationSnapshot(
        grok: .missing(layout.hostAdapter(for: .grok)),
        pi: .missing(layout.hostAdapter(for: .pi)),
        openCode: .missing(layout.hostAdapter(for: .opencode)),
        claude: .occupied(layout.hostAdapter(for: .claude)),
        openClaw: .missing(layout.hostAdapter(for: .openclaw)),
        hermes: .missing(layout.hostAdapter(for: .hermes)),
        codex: .missing(layout.hostAdapter(for: .codex)),
        cursor: .missing(layout.hostAdapter(for: .cursor))
    )

    let plan = SetupWorkPlanBuilder.make(
        installations: installations,
        layout: layout,
        force: true,
        rvdIsExecutable: true
    )
    let write = HostArtifacts.attach(
        host: .claude,
        layout: layout,
        existingData: nil,
        forceClear: true
    )

    #expect(write.adapter == .claudeSettingsMerge(force: true))
    #expect(write.prelude == .occupiedIfDestinationSymlink)
    #expect(write.existing == .reread)
    #expect(write.companions.isEmpty)
    #expect(plan.steps.contains(.forceClearThenWrite(write)))
}

@Test func workPlan_openClawWrite_carriesPluginCompanionsFromTable() throws {
    let layout = OwnedPaths(home: try #require(HomeDirectory(validating: "/tmp")))
    let installations = HostAdapterInstallationSnapshot(
        grok: .missing(layout.hostAdapter(for: .grok)),
        pi: .missing(layout.hostAdapter(for: .pi)),
        openCode: .missing(layout.hostAdapter(for: .opencode)),
        claude: .missing(layout.hostAdapter(for: .claude)),
        openClaw: .absentFile(layout.hostAdapter(for: .openclaw)),
        hermes: .missing(layout.hostAdapter(for: .hermes)),
        codex: .missing(layout.hostAdapter(for: .codex)),
        cursor: .missing(layout.hostAdapter(for: .cursor))
    )

    let plan = SetupWorkPlanBuilder.make(
        installations: installations,
        layout: layout,
        force: false,
        rvdIsExecutable: true
    )
    let write = HostArtifacts.attach(
        host: .openclaw,
        layout: layout,
        existingData: nil,
        forceClear: false
    )
    let directory = (write.destination as NSString).deletingLastPathComponent

    #expect(write.adapter == .writeOwnedRendered)
    #expect(write.companions == [
        .pluginManifest(path: directory + "/openclaw.plugin.json"),
        .packageManifest(path: directory + "/package.json"),
    ])
    #expect(plan.steps.contains(.write(write)))
}

@Test func hostArtifacts_attach_definedForEveryHost() throws {
    let layout = OwnedPaths(home: try #require(HomeDirectory(validating: "/tmp")))
    for host in HookHost.setupSlotOrder {
        let write = HostArtifacts.attach(
            host: host,
            layout: layout,
            existingData: nil,
            forceClear: false
        )
        #expect(write.host == host)
        #expect(write.destination == layout.hostAdapter(for: host).destination)
        #expect(write.prelude == .none)
    }
}

@Test func hostArtifacts_forceClear_claudeDoesNotBackupOwnedPath() throws {
    let layout = OwnedPaths(home: try #require(HomeDirectory(validating: "/tmp")))
    let claude = HostArtifacts.attach(
        host: .claude,
        layout: layout,
        existingData: nil,
        forceClear: true
    )
    let grok = HostArtifacts.attach(
        host: .grok,
        layout: layout,
        existingData: nil,
        forceClear: true
    )
    #expect(claude.prelude == .occupiedIfDestinationSymlink)
    #expect(claude.adapter == .claudeSettingsMerge(force: true))
    #expect(grok.prelude == .backupAndClearOwnedPath)
    #expect(grok.adapter == .applyGrokThenWriteOwned)
}

@Test func hostArtifacts_writeArtifacts_foldsCompanionsOnClaudeSettingsMerge() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(
            atPath: layout.claudeDirectory,
            withIntermediateDirectories: true
        )
        let companionPath = home.appendingPathComponent("extra-companion.js").path
        let write = HostAttachWrite(
            host: .claude,
            destination: layout.claudeSettings,
            existing: .use(nil),
            prelude: .none,
            adapter: .claudeSettingsMerge(force: false),
            companions: [.openCodeTuiPlugin(path: companionPath)]
        )
        let files = FileOps(fileManager: .default)
        let wrote = try SetupRun.writeArtifacts(
            write,
            existingData: nil,
            env: env(home: home, launchctl: launchctl, touchLaunchd: false),
            layout: layout,
            files: files
        )
        #expect(wrote)
        #expect(FileManager.default.fileExists(atPath: companionPath))
        #expect(FileManager.default.fileExists(atPath: layout.claudeSettings))
    }
}
