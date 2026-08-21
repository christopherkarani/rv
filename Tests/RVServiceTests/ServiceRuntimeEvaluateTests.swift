import Foundation
import Testing
import RVDomain
import RVIPC
import RVPolicy
@testable import RVService

struct ServiceRuntimeEvaluateTests {
    @Test func isolatedRuntime_setPackEnabledDoesNotWriteLiveHome() async throws {
        let live = try liveRVConfigSnapshot()
        let home = try isolatedHomeDirectory()
        let runtime = ServiceRuntime(
            home: home.path,
            allowOnceDirectory: try isolatedAllowOnceDirectory()
        )
        let disable = await runtime.dispatch(
            IPCRequest(method: .setPackEnabled(SetPackEnabledParams(id: .coreGit, enabled: false)))
        )
        guard case .setPackEnabled(let reply) = disable.result else {
            Issue.record("expected setPackEnabled reply")
            return
        }
        #expect(reply.pack.enabled == false)

        let listed = await runtime.dispatch(IPCRequest(method: .listPacks))
        guard case .listPacks(let packs) = listed.result else {
            Issue.record("expected listPacks reply")
            return
        }
        let git = try #require(packs.packs.first { $0.id == .coreGit })
        #expect(git.enabled == false)

        let tempConfig = PacksConfigStore.configURL(home: home.path)
        #expect(FileManager.default.fileExists(atPath: tempConfig.path))
        let persisted = try PacksConfigStore.load(home: home.path)
        #expect(persisted.disabled.contains(PackID.coreGit.rawValue))

        #expect(try liveRVConfigSnapshot() == live)
    }

    @Test func dispatchEvaluate_emptyEnabledPacksDoesNotRefillDayOne() async throws {
        let runtime = try isolatedRuntime()
        let response = await runtime.dispatch(
            IPCRequest(
                method: .evaluate(
                    EvaluateParams(
                        request: EvaluationRequest(
                            command: ShellCommand(rawValue: "git reset --hard"),
                            enabledPacks: []
                        )
                    )
                )
            )
        )
        guard case .evaluate(let reply) = response.result else {
            Issue.record("expected evaluate reply")
            return
        }
        if case .deny = reply.result.decision {
            Issue.record("empty enabledPacks means none enabled, not day-one refill")
        }
        #expect(reply.result.decision == .allow)
    }

    @Test func dispatchEvaluate_disabledCatalogPackStillDeniesResetHard() async throws {
        let runtime = try isolatedRuntime()
        let disable = await runtime.dispatch(
            IPCRequest(
                method: .setPackEnabled(SetPackEnabledParams(id: .coreGit, enabled: false))
            )
        )
        guard case .setPackEnabled = disable.result else {
            Issue.record("expected setPackEnabled reply")
            return
        }
        let response = await runtime.dispatch(
            IPCRequest(
                method: .evaluate(
                    EvaluateParams(
                        request: EvaluationRequest(
                            command: ShellCommand(rawValue: "git reset --hard"),
                            enabledPacks: dayOnePackIDs
                        )
                    )
                )
            )
        )
        guard case .evaluate(let reply) = response.result else {
            Issue.record("expected evaluate reply")
            return
        }
        guard case .deny(let deny) = reply.result.decision else {
            Issue.record("catalog disable must not change the evaluate set")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }

    @Test func dispatchEvaluate_grantHonorsOnceForCwd() async throws {
        let runtime = try isolatedRuntime()
        try await runtime.insertGranted(matchingView: "git reset --hard", cwd: "/tmp/ws")
        let request = EvaluationRequest(
            command: ShellCommand(rawValue: "git reset --hard"),
            enabledPacks: dayOnePackIDs
        )
        let first = await runtime.dispatch(
            IPCRequest(method: .evaluate(EvaluateParams(request: request, cwd: "/tmp/ws")))
        )
        guard case .evaluate(let allowed) = first.result else {
            Issue.record("expected evaluate reply")
            return
        }
        #expect(allowed.result.decision == .allow)
        #expect(allowed.result.policyOverride == .allowOnce)
        #expect(allowed.result.blockingMatch == nil)
        let second = await runtime.dispatch(
            IPCRequest(method: .evaluate(EvaluateParams(request: request, cwd: "/tmp/ws")))
        )
        guard case .evaluate(let denied) = second.result else {
            Issue.record("expected second evaluate reply")
            return
        }
        guard case .deny = denied.result.decision else {
            Issue.record("second evaluate must deny after the grant is spent")
            return
        }
    }

    @Test func classify_honoredAllowIsNotHighBecauseLeftoverMatch() async throws {
        let runtime = try isolatedRuntime()
        try await runtime.insertGranted(matchingView: "git reset --hard", cwd: "/tmp/ws")
        let request = EvaluationRequest(
            command: ShellCommand(rawValue: "git reset --hard"),
            enabledPacks: dayOnePackIDs
        )
        let response = await runtime.dispatch(
            IPCRequest(method: .classify(ClassifyParams(request: request, cwd: "/tmp/ws")))
        )
        guard case .classify(let reply) = response.result else {
            Issue.record("expected classify reply")
            return
        }
        #expect(reply.decision == .allow)
        #expect(reply.risk != .high)
        #expect(reply.risk != .critical)
    }

    @Test func classify_advisoryStashDropMapsMedium() async throws {
        let runtime = try isolatedRuntime()
        let response = await runtime.dispatch(
            IPCRequest(
                method: .classify(
                    ClassifyParams(
                        request: EvaluationRequest(
                            command: ShellCommand(rawValue: "git stash drop"),
                            enabledPacks: dayOnePackIDs
                        )
                    )
                )
            )
        )
        guard case .classify(let reply) = response.result else {
            Issue.record("expected classify reply")
            return
        }
        #expect(reply.decision == .allow)
        #expect(reply.risk == .medium)
    }
}

private struct LiveRVConfigSnapshot: Equatable {
    var directoryExists: Bool
    var configContents: Data?
}

private func liveRVConfigSnapshot() throws -> LiveRVConfigSnapshot {
    let home = try #require(
        ProcessInfo.processInfo.environment["HOME"].flatMap { $0.isEmpty ? nil : $0 }
    )
    let directory = URL(fileURLWithPath: home, isDirectory: true)
        .appendingPathComponent(".config", isDirectory: true)
        .appendingPathComponent("rv", isDirectory: true)
    let config = directory.appendingPathComponent("config.toml")
    let directoryExists = FileManager.default.fileExists(atPath: directory.path)
    let configContents = directoryExists ? try? Data(contentsOf: config) : nil
    return LiveRVConfigSnapshot(directoryExists: directoryExists, configContents: configContents)
}
