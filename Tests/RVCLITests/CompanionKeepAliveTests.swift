import Foundation
import Testing
@testable import RVCLI

func launchdPlist(_ text: String) throws -> [String: Any] {
    let data = try #require(text.data(using: .utf8))
    let object = try PropertyListSerialization.propertyList(from: data, format: nil)
    return try #require(object as? [String: Any])
}

func launchAgentKeepAlive(_ path: String) throws -> Bool {
    let text = try String(contentsOfFile: path, encoding: .utf8)
    let plist = try launchdPlist(text)
    return try #require(plist["KeepAlive"] as? Bool)
}

func expectLaunchAgentKeepAlive(
    _ path: String,
    _ expected: Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) throws {
    let value = try launchAgentKeepAlive(path)
    #expect(value == expected, sourceLocation: sourceLocation)
}

@Test func companionPresence_defaultSearchRoots_areSystemAndHomeApplications() {
    let roots = FilesystemCompanionPresence.defaultSearchRoots(home: "/tmp/rv-home")
    #expect(roots.map(\.path) == ["/Applications", "/tmp/rv-home/Applications"])
}

func plantCompanionApp(inApplicationsRoot root: URL, bundleId: String = "dev.rv.app") throws {
    let plistURL = root.appendingPathComponent("rv.app/Contents/Info.plist")
    try FileManager.default.createDirectory(
        at: plistURL.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    let plist: [String: Any] = [
        "CFBundleIdentifier": bundleId,
        "CFBundleName": "rv",
        "CFBundlePackageType": "APPL",
    ]
    let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
    try data.write(to: plistURL)
}

@Test func launchAgentTemplate_keepAliveFalse_parsesFalseAndLeavesRunAtLoadFalse() throws {
    let text = try LaunchAgentTemplate.rendered(rvdPath: "/opt/rvd", keepAlive: false)
    let plist = try launchdPlist(text)
    #expect(plist["KeepAlive"] as? Bool == false)
    #expect(plist["RunAtLoad"] as? Bool == false)
    #expect(plist["ProgramArguments"] as? [String] == ["/opt/rvd"])
}

#if !os(Linux)
@Test func launchAgentTemplate_keepAliveTrue_parsesTrueAndLeavesRunAtLoadFalse() throws {
    let text = try LaunchAgentTemplate.rendered(rvdPath: "/opt/rvd", keepAlive: true)
    let plist = try launchdPlist(text)
    #expect(plist["KeepAlive"] as? Bool == true)
    #expect(plist["RunAtLoad"] as? Bool == false)
    #expect(plist["ProgramArguments"] as? [String] == ["/opt/rvd"])
}

@Test func setup_injectedCompanionInstalled_writesKeepAliveTrue() throws {
    try withTempHome { home, layout, launchctl in
        let outcome = SetupRun.setup(
            env(
                home: home,
                launchctl: launchctl,
                companionPresence: FixedCompanionPresence(value: .installed)
            )
        )
        #expect(outcome.exitCode == 0)
        try expectLaunchAgentKeepAlive(layout.launchAgent, true)
        let plist = try launchdPlist(try String(contentsOfFile: layout.launchAgent, encoding: .utf8))
        #expect(plist["RunAtLoad"] as? Bool == false)
        #expect(launchctl.bootstraps.isEmpty == false)
    }
}

@Test func setup_injectedCompanionAbsent_writesKeepAliveFalse() throws {
    try withTempHome { home, layout, launchctl in
        let outcome = SetupRun.setup(
            env(
                home: home,
                launchctl: launchctl,
                companionPresence: FixedCompanionPresence(value: .absent)
            )
        )
        #expect(outcome.exitCode == 0)
        try expectLaunchAgentKeepAlive(layout.launchAgent, false)
    }
}

@Test func setup_reprobeHealsKeepAliveAfterCompanionLeaves() throws {
    try withTempHome { home, layout, launchctl in
        #expect(
            SetupRun.setup(
                env(
                    home: home,
                    launchctl: launchctl,
                    companionPresence: FixedCompanionPresence(value: .installed)
                )
            ).exitCode == 0
        )
        try expectLaunchAgentKeepAlive(layout.launchAgent, true)

        #expect(
            SetupRun.setup(
                env(
                    home: home,
                    launchctl: launchctl,
                    companionPresence: FixedCompanionPresence(value: .absent)
                )
            ).exitCode == 0
        )
        try expectLaunchAgentKeepAlive(layout.launchAgent, false)
        #expect(FileManager.default.fileExists(atPath: layout.launchAgent))
    }
}

@Test func restoreKeepAliveAfterCompanionUninstall_setsFalseAndLeavesCLI() throws {
    try withTempHome { home, layout, launchctl in
        try makeExecutable(URL(fileURLWithPath: layout.localRv))
        try makeExecutable(URL(fileURLWithPath: layout.localRvCli))
        try makeExecutable(URL(fileURLWithPath: layout.localRvd))
        let installed = env(
            home: home,
            launchctl: launchctl,
            companionPresence: FixedCompanionPresence(value: .installed)
        )
        #expect(SetupRun.setup(installed).exitCode == 0)
        try expectLaunchAgentKeepAlive(layout.launchAgent, true)

        try SetupRun.restoreKeepAliveAfterCompanionUninstall(installed)
        try expectLaunchAgentKeepAlive(layout.launchAgent, false)
        #expect(FileManager.default.fileExists(atPath: layout.launchAgent))
        #expect(FileManager.default.isExecutableFile(atPath: layout.localRv))
        #expect(FileManager.default.isExecutableFile(atPath: layout.localRvCli))
        #expect(FileManager.default.isExecutableFile(atPath: layout.localRvd))
        let plist = try launchdPlist(try String(contentsOfFile: layout.launchAgent, encoding: .utf8))
        #expect(plist["RunAtLoad"] as? Bool == false)
    }
}

@Test func restoreKeepAliveAfterCompanionUninstall_missingPlist_isNoOp() throws {
    try withTempHome { home, layout, launchctl in
        try makeExecutable(URL(fileURLWithPath: layout.localRv))
        try SetupRun.restoreKeepAliveAfterCompanionUninstall(
            env(home: home, launchctl: launchctl, touchLaunchd: false)
        )
        #expect(FileManager.default.fileExists(atPath: layout.launchAgent) == false)
        #expect(FileManager.default.isExecutableFile(atPath: layout.localRv))
        #expect(launchctl.bootstraps.isEmpty)
        #expect(launchctl.bootouts.isEmpty)
    }
}

@Test(arguments: ["dev.rv.app", "dev.rv.companion"])
func companionPresence_rvAppWithDevRvBundleId_isInstalled(bundleId: String) throws {
    try withTempHome { home, _, _ in
        let applications = home.appendingPathComponent("Applications", isDirectory: true)
        try plantCompanionApp(inApplicationsRoot: applications, bundleId: bundleId)
        let probe = FilesystemCompanionPresence(searchRoots: [applications])
        #expect(probe.presence() == .installed)
    }
}

@Test func companionPresence_cliPathsAreNotTheApp() throws {
    try withTempHome { home, _, _ in
        let applications = home.appendingPathComponent("Applications", isDirectory: true)
        try makeExecutable(home.appendingPathComponent(".local/bin/rv"))
        try makeExecutable(applications.appendingPathComponent("rv/bin/rv"))
        let probe = FilesystemCompanionPresence(searchRoots: [applications, home])
        #expect(probe.presence() == .absent)
    }
}

@Test func companionPresence_machServiceBundleId_isAbsent() throws {
    try withTempHome { home, _, _ in
        let applications = home.appendingPathComponent("Applications", isDirectory: true)
        try plantCompanionApp(inApplicationsRoot: applications, bundleId: "dev.rv.evaluate")
        let probe = FilesystemCompanionPresence(searchRoots: [applications])
        #expect(probe.presence() == .absent)
    }
}

// P2-3: suffixed service name must also be rejected.
@Test func companionPresence_machServicePrefixedBundleId_isAbsent() throws {
    try withTempHome { home, _, _ in
        let applications = home.appendingPathComponent("Applications", isDirectory: true)
        try plantCompanionApp(inApplicationsRoot: applications, bundleId: "dev.rv.evaluate.foo")
        let probe = FilesystemCompanionPresence(searchRoots: [applications])
        #expect(probe.presence() == .absent)
    }
}

@Test func companionPresence_foreignBundleId_isAbsent() throws {
    try withTempHome { home, _, _ in
        let applications = home.appendingPathComponent("Applications", isDirectory: true)
        try plantCompanionApp(inApplicationsRoot: applications, bundleId: "com.example.rv")
        let probe = FilesystemCompanionPresence(searchRoots: [applications])
        #expect(probe.presence() == .absent)
    }
}

@Test func companionPresence_fileNamedRvApp_isAbsent() throws {
    try withTempHome { home, _, _ in
        let applications = home.appendingPathComponent("Applications", isDirectory: true)
        try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
        try "not a bundle".write(
            to: applications.appendingPathComponent("rv.app"),
            atomically: true,
            encoding: .utf8
        )
        let probe = FilesystemCompanionPresence(searchRoots: [applications])
        #expect(probe.presence() == .absent)
    }
}

@Test func setup_filesystemProbeFindsTempHomeCompanionApp() throws {
    try withTempHome { home, layout, launchctl in
        let applications = home.appendingPathComponent("Applications", isDirectory: true)
        try plantCompanionApp(inApplicationsRoot: applications)
        let outcome = SetupRun.setup(
            env(
                home: home,
                launchctl: launchctl,
                companionPresence: FilesystemCompanionPresence(searchRoots: [applications])
            )
        )
        #expect(outcome.exitCode == 0)
        try expectLaunchAgentKeepAlive(layout.launchAgent, true)
    }
}
#endif
