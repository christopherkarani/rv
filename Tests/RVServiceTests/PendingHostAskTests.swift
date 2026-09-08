import Foundation
import Testing
import RVDomain
import RVIPC
import RVPolicy
@testable import RVService

@Suite("PendingHostAsk service door")
struct PendingHostAskServiceTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func PendingHostAsk_askWithSessionWritesAwaitingRowThatSurvivesNewStore() async throws {
        let env = try IsolatedPendingHostAsk()
        defer { env.tearDown() }

        let wire = await env.runtime.dispatch(
            IPCRequest(method: .hookEvaluate(HookEvaluateParams(host: .pi, stdin: env.askStdin)))
        )
        try assertAsk(wire)

        let listed = try await env.store.list(now: now)
        #expect(listed.count == 1)
        let row = try #require(listed.first)
        #expect(row.state == .awaitingHuman)
        #expect(row.reason == .hostAsk)
        #expect(row.continuation == .hostNative)
        #expect(row.timeoutPolicy == .keepWaiting)
        #expect(row.identity.session.rawValue == "sess-pi")
        #expect(row.identity.agent.rawValue == HookHost.pi.rawValue)
        #expect(row.action.supportingCommand?.rawValue == "git reset --hard")
        #expect(row.expiresAt == now.addingTimeInterval(PendingApprovalRequest.defaultTTL))

        let restarted = PendingApprovalStore.live(home: env.home)
        let afterRestart = try await restarted.list(now: now)
        #expect(afterRestart.map(\.id) == [row.id])
        #expect(afterRestart.first?.state == .awaitingHuman)

        let ipcList = await env.runtime.dispatch(IPCRequest(method: .pendingList))
        try assertNoCommandText(ipcList)
        guard case .pendingList(let reply) = ipcList.result else {
            Issue.record("Ask with session must list the wait")
            return
        }
        #expect(reply.items.map(\.id) == [row.id])
    }

    @Test func PendingHostAsk_spendAllowEmptiesMatchingAwaiting() async throws {
        let env = try IsolatedPendingHostAsk()
        defer { env.tearDown() }

        _ = await env.runtime.dispatch(
            IPCRequest(method: .hookEvaluate(HookEvaluateParams(host: .pi, stdin: env.askStdin)))
        )
        #expect(try await env.store.list(now: now).count == 1)

        let spendAllow = await env.runtime.dispatch(
            IPCRequest(method: .hookEvaluate(HookEvaluateParams(host: .pi, stdin: env.spendStdin)))
        )
        guard case .hookEvaluate(let allowReply) = spendAllow.result else {
            Issue.record("spend must return hookEvaluate")
            return
        }
        #expect(allowReply.stdout.isEmpty)
        #expect(allowReply.exitCode == 0)
        #expect(try await env.store.list(now: now).isEmpty)
    }

    @Test func PendingHostAsk_spendDenyStillCancelsMatchingAwaiting() async throws {
        let env = try IsolatedPendingHostAsk()
        defer { env.tearDown() }

        _ = await env.runtime.dispatch(
            IPCRequest(method: .hookEvaluate(HookEvaluateParams(host: .pi, stdin: env.askStdin)))
        )
        #expect(try await env.store.list(now: now).count == 1)

        try env.makeAllowOnceUnwritable()
        let spendDeny = await env.runtime.dispatch(
            IPCRequest(method: .hookEvaluate(HookEvaluateParams(host: .pi, stdin: env.spendStdin)))
        )
        guard case .hookEvaluate(let denyReply) = spendDeny.result else {
            Issue.record("failed spend must still return hookEvaluate")
            return
        }
        #expect(denyReply.stdout.isEmpty == false)
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(denyReply.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String == "deny")
        #expect(json["decision"] as? String != "ask")
        #expect(try await env.store.list(now: now).isEmpty)
    }

    @Test func PendingHostAsk_missingSessionEncodesAskWithEmptyList() async throws {
        let env = try IsolatedPendingHostAsk()
        defer { env.tearDown() }

        let wire = await env.runtime.dispatch(
            IPCRequest(
                method: .hookEvaluate(
                    HookEvaluateParams(
                        host: .pi,
                        stdin: """
                        {"toolName":"bash","cwd":"/tmp/ws","input":{"command":"git reset --hard"}}
                        """
                    )
                )
            )
        )
        try assertAsk(wire)
        #expect(try await env.store.list(now: now).isEmpty)
        let listed = await env.runtime.dispatch(IPCRequest(method: .pendingList))
        guard case .pendingList(let reply) = listed.result else {
            Issue.record("missing session must still list")
            return
        }
        #expect(reply.items.isEmpty)
    }

    @Test func PendingHostAsk_secondAskSameIdentityKeepsOneAwaiting() async throws {
        let env = try IsolatedPendingHostAsk()
        defer { env.tearDown() }

        _ = await env.runtime.dispatch(
            IPCRequest(method: .hookEvaluate(HookEvaluateParams(host: .pi, stdin: env.askStdin)))
        )
        _ = await env.runtime.dispatch(
            IPCRequest(method: .hookEvaluate(HookEvaluateParams(host: .pi, stdin: env.askStdin)))
        )
        let listed = try await env.store.list(now: now)
        #expect(listed.count == 1)
        #expect(listed.first?.state == .awaitingHuman)
    }

    @Test func PendingHostAsk_grokCreatesNoRows() async throws {
        let env = try IsolatedPendingHostAsk()
        defer { env.tearDown() }

        let wire = await env.runtime.dispatch(
            IPCRequest(
                method: .hookEvaluate(
                    HookEvaluateParams(
                        host: .grok,
                        stdin: """
                        {"hookEventName":"pre_tool_use","cwd":"/tmp/ws","sessionId":"sess-grok","toolName":"run_terminal_command","toolInput":{"command":"git reset --hard"}}
                        """
                    )
                )
            )
        )
        guard case .hookEvaluate(let reply) = wire.result else {
            Issue.record("Grok must still encode")
            return
        }
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(reply.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String != "ask")
        #expect(try await env.store.list(now: now).isEmpty)
    }

    private func assertAsk(_ response: IPCResponse) throws {
        guard case .hookEvaluate(let reply) = response.result else {
            Issue.record("expected hookEvaluate, got \(response.result)")
            throw PendingHostAskExpectation()
        }
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(reply.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String == "ask")
        #expect(reply.stdout.contains("\"decision\":\"allow\"") == false)
        #expect(reply.exitCode == 1)
    }

    private func assertNoCommandText(_ response: IPCResponse) throws {
        let data = try IPCJSON.encode(response)
        let text = String(data: data, encoding: .utf8) ?? ""
        #expect(text.contains("supportingCommand") == false)
        let object = try JSONSerialization.jsonObject(with: data)
        assertNoCommandKeys(object)
    }

    private func assertNoCommandKeys(_ object: Any) {
        switch object {
        case let dict as [String: Any]:
            #expect(dict["command"] == nil)
            #expect(dict["supportingCommand"] == nil)
            for value in dict.values {
                assertNoCommandKeys(value)
            }
        case let array as [Any]:
            for value in array {
                assertNoCommandKeys(value)
            }
        default:
            break
        }
    }

    private struct PendingHostAskExpectation: Error {}
}

private struct IsolatedPendingHostAsk {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let homeURL: URL
    let allowOnceDirectory: URL
    let home: HomeDirectory
    let runtime: ServiceRuntime
    let store: PendingApprovalStore
    let askStdin = """
    {"toolName":"bash","cwd":"/tmp/ws","sessionId":"sess-pi","input":{"command":"git reset --hard"}}
    """
    let spendStdin = """
    {"toolName":"bash","cwd":"/tmp/ws","sessionId":"sess-pi","input":{"command":"git reset --hard"},"hostAsk":"spend"}
    """

    init() throws {
        homeURL = try isolatedHomeDirectory()
        allowOnceDirectory = try isolatedAllowOnceDirectory()
        home = try #require(HomeDirectory(validating: homeURL.path))
        runtime = ServiceRuntime(
            home: home,
            allowOnceDirectory: allowOnceDirectory,
            clock: { Date(timeIntervalSince1970: 1_700_000_000) },
            pendingApprovals: .automatic
        )
        store = PendingApprovalStore.live(home: home)
    }

    func makeAllowOnceUnwritable() throws {
        // AllowOnceStore resets directory mode to 0700 before write, so a
        // chmod is not a plant failure. A file where the store directory
        // should be makes createDirectory fail closed.
        if FileManager.default.fileExists(atPath: allowOnceDirectory.path) {
            try FileManager.default.removeItem(at: allowOnceDirectory)
        }
        try Data("not-a-directory".utf8).write(to: allowOnceDirectory)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: homeURL)
        try? FileManager.default.removeItem(at: allowOnceDirectory)
    }
}
