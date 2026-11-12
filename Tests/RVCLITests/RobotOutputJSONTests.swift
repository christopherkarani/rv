import ArgumentParser
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation
import Testing
import RVDomain
import RVIPC
import RVPolicy
import RVPresentation
@testable import RVCLI

private func jsonObject(_ text: String) throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
}

struct ServiceStatusJSONTests {
    private let down = ServiceStatusReport(state: "down", fallback: "down", lastError: "rvd is not running")

    @Test func explicitJSONIsTheRobotDocument() throws {
        let text = try ServiceStatusCommand.text(down, appearance: .robot, explicitRobot: true)
        let object = try jsonObject(text)
        #expect(object["schema"] as? String == "rv.service.status.v1")
        #expect(object["state"] as? String == "down")
        #expect(object["protocol"] as? String == "rv.ipc.v1")
        #expect(object["label"] as? String == "dev.rv.evaluate")
        #expect(object["keep_alive"] as? Bool == false)
        #expect(object["last_error"] as? String == "rvd is not running")
        // Hooks have no in-process fallback; the JSON does not pretend.
        #expect(object["fallback"] == nil)
    }

    @Test func pipedOutputWithoutAFlagKeepsKeyValueLines() throws {
        let text = try ServiceStatusCommand.text(down, appearance: .robot, explicitRobot: false)
        #expect(text.hasPrefix("state=down\n"))
    }

    @Test func goldenRunningDocument() throws {
        let running = ServiceStatusReport(state: "running", fallback: "inactive", keepAlive: true)
        #expect(try ServiceStatusCommand.jsonText(running)
            == #"{"keep_alive":true,"label":"dev.rv.evaluate","protocol":"rv.ipc.v1","schema":"rv.service.status.v1","state":"running"}"#)
    }
}

struct SetupJSONTests {
    @Test func aRunThatChangesNothingStillPrintsADocument() throws {
        try withTempHome { home, layout, launchctl in
            try FileManager.default.createDirectory(atPath: layout.piDirectory, withIntermediateDirectories: true)
            let environment = env(home: home, launchctl: launchctl, touchLaunchd: false)
            let first = SetupRun.setup(environment, json: true)
            #expect(first.exitCode == 0)
            let wired = try jsonObject(first.stdout)
            #expect(wired["schema"] as? String == "rv.setup.v1")
            #expect(wired["ok"] as? Bool == true)
            #expect(wired["outcome"] as? String == "complete")
            #expect((wired["hosts"] as? [String: String])?["pi"] == "wired")
            #expect(wired["wrote"] as? [String] == ["pi"])
            #expect(wired["service"] as? String == "not_managed")

            let second = SetupRun.setup(environment, json: true)
            #expect(second.exitCode == 0)
            #expect(second.stdout.hasSuffix("}\n"))
            let quiet = try jsonObject(second.stdout)
            #expect(quiet["outcome"] as? String == "unchanged")
            #expect(quiet["wrote"] as? [String] == [])
            // Without --json the same quiet run prints nothing, as before.
            #expect(SetupRun.setup(environment, appearance: .robot).stdout.isEmpty)
        }
    }

    @Test func aFailureIsAnOkFalseDocument() throws {
        try withTempHome { home, _, launchctl in
            var environment = env(home: home, launchctl: launchctl)
            environment.runningExecutable = "/somewhere/else/rv-cli"
            let outcome = SetupRun.setup(environment, json: true)
            #expect(outcome.exitCode == EX_USAGE)
            let object = try jsonObject(outcome.stdout)
            #expect(object["ok"] as? Bool == false)
            #expect(object["outcome"] as? String == "failed")
            #expect((object["error"] as? String)?.hasPrefix("rv setup failed: /somewhere/else/rv-cli is not the installed rv") == true)
            #expect(outcome.stderr.hasPrefix("rv setup failed:"))
        }
    }

    @Test func noHostsIsReported() throws {
        try withTempHome { home, _, launchctl in
            let outcome = SetupRun.setup(env(home: home, launchctl: launchctl, touchLaunchd: false), json: true)
            let object = try jsonObject(outcome.stdout)
            #expect(object["outcome"] as? String == "no_hosts")
        }
    }
}
