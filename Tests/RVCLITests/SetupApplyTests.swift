import Foundation
import RVPresentation
import Testing
@testable import RVCLI

@Test func setupApply_hostless_allPendingWroteEmpty() throws {
    try withTempHome { home, _, launchctl in
        let report = try SetupApply.setup(env(home: home, launchctl: launchctl), force: false)
        #expect(report.grok == .pending)
        #expect(report.pi == .pending)
        #expect(report.openCode == .pending)
        #expect(report.wrote.isEmpty)
        #expect(report.slots.isHostless)
    }
}

@Test func setupApply_occupied_reportsOccupiedAndLeavesBytes() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(
            atPath: layout.grokDirectory + "/hooks",
            withIntermediateDirectories: true
        )
        let foreign = "{\"hooks\":[]}\n"
        try foreign.write(toFile: layout.grokHook, atomically: true, encoding: .utf8)

        let report = try SetupApply.setup(env(home: home, launchctl: launchctl), force: false)

        #expect(report.grok == .occupied)
        #expect(report.wrote.contains(.grok) == false)
        #expect(try String(contentsOfFile: layout.grokHook, encoding: .utf8) == foreign)
    }
}

@Test func setupApply_force_wiresOccupiedAndKeepsBackup() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(
            atPath: layout.grokDirectory + "/hooks",
            withIntermediateDirectories: true
        )
        let foreign = "{\"hooks\":[]}\n"
        try foreign.write(toFile: layout.grokHook, atomically: true, encoding: .utf8)

        let report = try SetupApply.setup(env(home: home, launchctl: launchctl), force: true)

        #expect(report.grok == .wired)
        #expect(report.wrote.contains(.grok))
        #expect(
            try String(contentsOfFile: layout.grokHook, encoding: .utf8)
                == (try SetupHostKind.grok.adapterResource().rendered(rvPath: "/tmp/rv-bin/rv"))
        )
        #expect(try String(contentsOfFile: layout.grokHook + ".bak", encoding: .utf8) == foreign)
    }
}

@Test func setupApply_quietSecondRun_wroteEmpty() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
        let first = try SetupApply.setup(env(home: home, launchctl: launchctl), force: false)
        let second = try SetupApply.setup(env(home: home, launchctl: launchctl), force: false)
        #expect(first.grok == .wired)
        #expect(first.wrote.contains(.grok))
        #expect(second.grok == .wired)
        #expect(second.wrote.isEmpty)
        #expect(second.slots.isQuiet)
    }
}

@Test func setupApply_capturesInstallAnalyticsWithoutLiveSink() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
        let analytics = RecordingInstallAnalytics()
        let report = try SetupApply.setup(
            env(home: home, launchctl: launchctl, installAnalytics: analytics),
            force: false
        )
        #expect(report.grok == .wired)
        #expect(analytics.captures == [[
            "grok": "wired",
            "pi": "pending",
            "opencode": "pending",
        ]])
    }
}

@Test func setupApply_uninstall_alreadyClean_didRemoveAnythingIsFalse() throws {
    try withTempHome { home, _, launchctl in
        let report = try SetupApply.uninstall(env(home: home, launchctl: launchctl))
        #expect(report.didRemoveAnything == false)
        #expect(report.removedHosts.isEmpty)
        #expect(report.occupiedHosts.isEmpty)
        #expect(report.removedLaunchAgent == false)
        #expect(report.removedBinaries == false)
        #expect(report.removedConfigArtifacts == false)
    }
}

@Test func setupApply_uninstall_afterSetup_didRemoveAnything() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(atPath: layout.grokDirectory, withIntermediateDirectories: true)
        _ = try SetupApply.setup(env(home: home, launchctl: launchctl), force: false)
        let report = try SetupApply.uninstall(env(home: home, launchctl: launchctl))
        #expect(report.didRemoveAnything)
        #expect(report.removedHosts.contains(.grok))
        #expect(report.removedLaunchAgent)
        #expect(FileManager.default.fileExists(atPath: layout.grokHook) == false)
    }
}

@Test func setupApply_uninstall_occupied_leavesBytesAndDidRemoveAnythingIsFalse() throws {
    try withTempHome { home, layout, launchctl in
        try FileManager.default.createDirectory(
            atPath: layout.grokDirectory + "/hooks",
            withIntermediateDirectories: true
        )
        let foreign = "{\"hooks\":[]}\n"
        try foreign.write(toFile: layout.grokHook, atomically: true, encoding: .utf8)

        let report = try SetupApply.uninstall(env(home: home, launchctl: launchctl))

        #expect(report.didRemoveAnything == false)
        #expect(report.occupiedHosts.contains(.grok))
        #expect(report.removedHosts.contains(.grok) == false)
        #expect(try String(contentsOfFile: layout.grokHook, encoding: .utf8) == foreign)
    }
}
