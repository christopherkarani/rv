import Foundation
import Testing
import RVDomain
import RVHooks
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
            IPCRequest(method: .hookEvaluate(HookEvaluateParams(host: .pi, stdin: env.askStdin))),
            context: peerHookContext()
        )
        try assertAsk(wire)

        let listed = try await env.store.list(now: now)
        #expect(listed.count == 1)
        let row = try #require(listed.first)
        #expect(row.state == .awaitingHuman)
        #expect(row.reason == .hostAsk)
        #expect(row.continuation == .retry(row.action.fingerprint))
        #expect(row.timeoutPolicy == .autoDeny)
        #expect(row.identity.session.rawValue == "sess-pi")
        #expect(row.identity.agent.rawValue == HookHost.pi.rawValue)
        #expect(row.action.supportingCommand?.rawValue == "git reset --hard")
        #expect(row.expiresAt == now.addingTimeInterval(PendingApprovalRequest.defaultTTL))

        let restarted = PendingApprovalStore.makeLive(home: env.home)
        let afterRestart = try await restarted.list(now: now)
        #expect(afterRestart.map(\.id) == [row.id])
        #expect(afterRestart.first?.state == .awaitingHuman)

        let ipcList = await env.runtime.dispatch(IPCRequest(method: .pendingList), context: peerServiceContext())
        try assertNoCommandText(ipcList)
        guard case .pendingList(let reply) = ipcList.result else {
            Issue.record("Ask with session must list the wait")
            return
        }
        #expect(reply.items.map(\.id) == [row.id])
    }

    @Test func PendingHostAsk_legacySpendEnvelopeIsIgnoredRowStaysAwaiting() async throws {
        let env = try IsolatedPendingHostAsk()
        defer { env.tearDown() }

        _ = await env.runtime.dispatch(
            IPCRequest(method: .hookEvaluate(HookEvaluateParams(host: .pi, stdin: env.askStdin))),
            context: peerHookContext()
        )
        #expect(try await env.store.list(now: now).count == 1)

        // Step 8B: the bare `hostAsk:spend` attestation is ignored. The
        // envelope decodes as an ordinary shell consult: ask-denial again,
        // same awaiting row by dedupe, never an allow.
        let legacy = await env.runtime.dispatch(
            IPCRequest(method: .hookEvaluate(HookEvaluateParams(host: .pi, stdin: env.spendStdin))),
            context: peerHookContext()
        )
        guard case .hookEvaluate(let reply) = legacy.result else {
            Issue.record("legacy spend must return hookEvaluate")
            return
        }
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(reply.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String == "deny")
        #expect(reply.stdout.contains(approvalPendingLine))
        #expect(reply.exitCode == 1)
        let listed = try await env.store.list(now: now)
        #expect(listed.count == 1)
        #expect(listed.first?.state == .awaitingHuman)
    }

    @Test func PendingHostAsk_legacySpendWithUnwritableStoreStillAskDenies() async throws {
        let env = try IsolatedPendingHostAsk()
        defer { env.tearDown() }

        _ = await env.runtime.dispatch(
            IPCRequest(method: .hookEvaluate(HookEvaluateParams(host: .pi, stdin: env.askStdin))),
            context: peerHookContext()
        )
        #expect(try await env.store.list(now: now).count == 1)

        try env.makeAllowOnceUnwritable()
        let legacy = await env.runtime.dispatch(
            IPCRequest(method: .hookEvaluate(HookEvaluateParams(host: .pi, stdin: env.spendStdin))),
            context: peerHookContext()
        )
        guard case .hookEvaluate(let denyReply) = legacy.result else {
            Issue.record("legacy spend must still return hookEvaluate")
            return
        }
        #expect(denyReply.stdout.isEmpty == false)
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(denyReply.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String == "deny")
        #expect(json["decision"] as? String != "ask")
        #expect(denyReply.stdout.contains(approvalPendingLine))
        // The pending store (under home) is intact; the row survives by dedupe.
        #expect(try await env.store.list(now: now).count == 1)
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
            ),
            context: peerHookContext()
        )
        try assertAsk(wire)
        #expect(try await env.store.list(now: now).isEmpty)
        let listed = await env.runtime.dispatch(IPCRequest(method: .pendingList), context: peerServiceContext())
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
            IPCRequest(method: .hookEvaluate(HookEvaluateParams(host: .pi, stdin: env.askStdin))),
            context: peerHookContext()
        )
        _ = await env.runtime.dispatch(
            IPCRequest(method: .hookEvaluate(HookEvaluateParams(host: .pi, stdin: env.askStdin))),
            context: peerHookContext()
        )
        let listed = try await env.store.list(now: now)
        #expect(listed.count == 1)
        #expect(listed.first?.state == .awaitingHuman)
    }

    @Test func PendingHostAsk_grokAskDenialCreatesRow() async throws {
        let env = try IsolatedPendingHostAsk()
        defer { env.tearDown() }

        // Step 8B: every host records a universal review row. Grok has no
        // native Ask, so the row plus TTY code is its whole fallback.
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
            ),
            context: peerHookContext()
        )
        guard case .hookEvaluate(let reply) = wire.result else {
            Issue.record("Grok must still encode")
            return
        }
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(reply.stdout.utf8)) as? [String: Any]
        )
        #expect(json["decision"] as? String == "deny")
        #expect(reply.stdout.contains(approvalPendingLine))
        let listed = try await env.store.list(now: now)
        #expect(listed.count == 1)
        #expect(listed.first?.state == .awaitingHuman)
        #expect(listed.first?.identity.agent == .grok)
    }

    private func assertAsk(_ response: IPCResponse) throws {
        guard case .hookEvaluate(let reply) = response.result else {
            Issue.record("expected hookEvaluate, got \(response.result)")
            throw PendingHostAskExpectation()
        }
        let json = try #require(
            JSONSerialization.jsonObject(with: Data(reply.stdout.utf8)) as? [String: Any]
        )
        // Step 8B: ASK renders as deny-with-guidance on the wire.
        #expect(json["decision"] as? String == "deny")
        #expect(reply.stdout.contains(approvalPendingLine))
        #expect(reply.stdout.contains("\"decision\":\"allow\"") == false)
        #expect(reply.stdout.contains("\"decision\":\"ask\"") == false)
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
        store = PendingApprovalStore.makeLive(home: home)
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
