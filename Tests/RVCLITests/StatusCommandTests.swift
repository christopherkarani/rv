import Foundation
import Testing
@testable import RVCLI

struct StatusCommandTests {
    private func hosts(_ rows: [(String, String, String)]) -> HostModeRun.ListDocument {
        HostModeRun.ListDocument(
            guardMode: "observe",
            hosts: rows.map { HostModeRun.Row(host: $0.0, mode: $0.1, wiring: $0.2) },
            managedEnforce: false
        )
    }

    @Test func registersStatusAndVersion() {
        let names = RV.configuration.subcommands.compactMap { $0.configuration.commandName }
        #expect(names.contains("status"))
        #expect(names.contains("version"))
    }

    @Test func healthyMachineShowsInstalledHostsOnly() {
        let document = StatusRun.document(
            version: "9.9.9",
            service: ServiceStatusReport(state: "running", fallback: "inactive"),
            hosts: .success(hosts([("claude", "observe", "wired"), ("codex", "block", "missing")])),
            lastBlock: nil
        )
        #expect(document.healthy)
        let text = StatusRun.text(document)
        #expect(text.hasPrefix("rv 9.9.9\n"))
        #expect(text.contains("service   running"))
        #expect(text.contains("guard     observe"))
        #expect(text.contains("claude  observe"))
        #expect(text.contains("codex") == false, "a host that is not installed is left out")
        #expect(text.contains("no denials recorded"))
        #expect(text.contains("More: rv doctor"))
    }

    @Test func downServiceIsUnhealthyAndPointsAtDoctor() {
        let document = StatusRun.document(
            service: ServiceStatusReport(state: "down", fallback: "down", lastError: "not reachable"),
            hosts: .success(hosts([("claude", "block", "wired")])),
            lastBlock: nil
        )
        #expect(document.healthy == false)
        let text = StatusRun.text(document)
        #expect(text.contains("service   down (not reachable)"))
        #expect(text.contains("Next: rv doctor"))
    }

    @Test func brokenHookIsUnhealthyAndPointsAtSetup() {
        let document = StatusRun.document(
            service: ServiceStatusReport(state: "running", fallback: "inactive"),
            hosts: .success(hosts([("cursor", "block", "broken")])),
            lastBlock: nil
        )
        #expect(document.healthy == false)
        #expect(StatusRun.text(document).contains("Next: rv setup"))
    }

    @Test func agoIsCoarseAndNeverNegative() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(StatusRun.ago(now.addingTimeInterval(10), now: now) == "just now")
        #expect(StatusRun.ago(now.addingTimeInterval(-120), now: now) == "2m ago")
        #expect(StatusRun.ago(now.addingTimeInterval(-7200), now: now) == "2h ago")
        #expect(StatusRun.ago(now.addingTimeInterval(-172_800), now: now) == "2d ago")
    }

    @Test func statusAndVersionHaveHelpPages() {
        #expect(HelpDispatch.topic(arguments: ["help", "status"]) == .status)
        #expect(HelpDispatch.topic(arguments: ["version", "--help"]) == .version)
    }
}
