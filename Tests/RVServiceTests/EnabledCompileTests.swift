import Foundation
import Testing
import RVDomain
import RVIPC
import RVPacks
@testable import RVService

struct EnabledCompileTests {
    @Test func dayOneEnabledCompilesExactlyTwoPackIDs() throws {
        let all = try PackRegistry.loadAll()
        #expect(all.count == 99)
        let session = EvaluateSession(snapshots: all, enabledPacks: dayOnePackIDs)
        #expect(session.compiledPackIDs == dayOnePackIDs)
        #expect(session.corePacksReady)
    }

    @Test func dayOneSessionDeniesResetHardAndAllowsStashDrop() throws {
        let all = try PackRegistry.loadAll()
        let session = EvaluateSession(snapshots: all, enabledPacks: dayOnePackIDs)
        let denied = session.evaluate(
            EvaluationRequest(
                command: ShellCommand(rawValue: "git reset --hard"),
                enabledPacks: dayOnePackIDs
            )
        )
        guard case .deny(let deny) = denied.decision else {
            Issue.record("day-one compile set must deny git reset --hard")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")

        let allowed = session.evaluate(
            EvaluationRequest(
                command: ShellCommand(rawValue: "git stash drop"),
                enabledPacks: dayOnePackIDs
            )
        )
        #expect(allowed.decision == .allow)
        #expect(allowed.matched?.ruleID.rawValue == "core.git:stash-drop")
    }

    @Test func extraCatalogPackCompilesThreeAndDeniesSqliteDrop() throws {
        let all = try PackRegistry.loadAll()
        let sqlite = PackID(rawValue: "database.sqlite")
        let enabled = (dayOnePackIDs + [sqlite]).sorted { $0.rawValue < $1.rawValue }
        let session = EvaluateSession(snapshots: all, enabledPacks: enabled)
        #expect(session.compiledPackIDs == enabled)

        let result = session.evaluate(
            EvaluationRequest(
                command: ShellCommand(rawValue: "DROP TABLE users"),
                enabledPacks: enabled
            )
        )
        guard case .deny(let deny) = result.decision else {
            Issue.record("compiled sqlite pack must deny DROP TABLE users")
            return
        }
        #expect(deny.ruleID.rawValue == "database.sqlite:drop-table")
    }

    @Test func emptySessionEnabledPacksCompilesNone() throws {
        let all = try PackRegistry.loadAll()
        let session = EvaluateSession(snapshots: all, enabledPacks: [])
        #expect(session.compiledPackIDs.isEmpty)
    }

    @Test func missingAndUncompilableCoreStayIndeterminate() {
        let missing = EvaluateSession.missingCore
        #expect(missing.corePacksReady == false)
        #expect(
            missing.evaluate(
                EvaluationRequest(
                    command: ShellCommand(rawValue: "git reset --hard"),
                    enabledPacks: dayOnePackIDs
                )
            ).decision == .indeterminate(.corePacksUnavailable)
        )

        let broken = EvaluateSession.uncompilableCore
        #expect(broken.corePacksReady == false)
        #expect(
            broken.evaluate(
                EvaluationRequest(
                    command: ShellCommand(rawValue: "git reset --hard"),
                    enabledPacks: dayOnePackIDs
                )
            ).decision == .indeterminate(.corePacksUnavailable)
        )
    }

    @Test func directConfigEditIsPickedUpByWarmRuntimeEvaluate() async throws {
        let home = try temporaryCompileHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let sqlite = PackID(rawValue: "database.sqlite")
        let runtime = ServiceRuntime(
            home: home,
            allowOnceDirectory: try isolatedAllowOnceDirectory()
        )
        #expect(await runtime.compiledPackIDs == dayOnePackIDs)

        // Production path: `rv packs enable` writes config.toml directly; no
        // XPC notification reaches this warm runtime.
        _ = try PacksFacade.enable(home: home, ids: [sqlite.rawValue])

        let denied = await runtime.dispatch(
            IPCRequest(
                method: .evaluate(
                    EvaluateParams(
                        request: EvaluationRequest(
                            command: ShellCommand(rawValue: "DROP TABLE users"),
                            enabledPacks: dayOnePackIDs + [sqlite]
                        )
                    )
                )
            )
        )
        guard case .evaluate(let reply) = denied.result else {
            Issue.record("expected evaluate reply")
            return
        }
        guard case .deny(let deny) = reply.result.decision else {
            Issue.record("warm runtime must pick up direct config edits; DROP TABLE users must deny")
            return
        }
        #expect(deny.ruleID.rawValue == "database.sqlite:drop-table")
        #expect(
            await runtime.compiledPackIDs
                == (dayOnePackIDs + [sqlite]).sorted { $0.rawValue < $1.rawValue }
        )
    }

    @Test func directConfigEditIsHealedByListPacksCoverageCheck() async throws {
        let home = try temporaryCompileHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let sqlite = PackID(rawValue: "database.sqlite")
        let runtime = ServiceRuntime(
            home: home,
            allowOnceDirectory: try isolatedAllowOnceDirectory()
        )
        #expect(await runtime.compiledPackIDs == dayOnePackIDs)
        _ = try PacksFacade.enable(home: home, ids: [sqlite.rawValue])

        _ = await runtime.dispatch(IPCRequest(method: .listPacks))

        #expect(
            await runtime.compiledPackIDs
                == (dayOnePackIDs + [sqlite]).sorted { $0.rawValue < $1.rawValue }
        )
    }

    @Test func setPackEnabledGrowsAndShrinksCompiledPackIDs() async throws {
        let home = try temporaryCompileHome()
        defer { try? FileManager.default.removeItem(atPath: home) }
        let sqlite = PackID(rawValue: "database.sqlite")
        let runtime = ServiceRuntime(
            home: home,
            allowOnceDirectory: try isolatedAllowOnceDirectory()
        )
        #expect(await runtime.compiledPackIDs == dayOnePackIDs)

        let enable = await runtime.dispatch(
            IPCRequest(method: .setPackEnabled(SetPackEnabledParams(id: sqlite, enabled: true)))
        )
        guard case .setPackEnabled = enable.result else {
            Issue.record("expected setPackEnabled enable reply, got \(enable.result)")
            return
        }
        let afterEnable = await runtime.compiledPackIDs
        #expect(afterEnable == (dayOnePackIDs + [sqlite]).sorted { $0.rawValue < $1.rawValue })

        let denied = await runtime.dispatch(
            IPCRequest(
                method: .evaluate(
                    EvaluateParams(
                        request: EvaluationRequest(
                            command: ShellCommand(rawValue: "DROP TABLE users"),
                            enabledPacks: dayOnePackIDs + [sqlite]
                        )
                    )
                )
            )
        )
        guard case .evaluate(let reply) = denied.result else {
            Issue.record("expected evaluate reply")
            return
        }
        guard case .deny(let deny) = reply.result.decision else {
            Issue.record("enabled sqlite must deny DROP TABLE users")
            return
        }
        #expect(deny.ruleID.rawValue == "database.sqlite:drop-table")

        let disable = await runtime.dispatch(
            IPCRequest(method: .setPackEnabled(SetPackEnabledParams(id: sqlite, enabled: false)))
        )
        guard case .setPackEnabled = disable.result else {
            Issue.record("expected setPackEnabled disable reply, got \(disable.result)")
            return
        }
        #expect(await runtime.compiledPackIDs == dayOnePackIDs)
    }
}

private func temporaryCompileHome() throws -> String {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("rv-t11-compile-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}
