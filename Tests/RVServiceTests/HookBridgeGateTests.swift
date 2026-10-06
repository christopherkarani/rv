#if canImport(XPC)
import Foundation
import Testing
import RVDomain
import RVIPC
@testable import RVIsolation
import RVPolicy
@testable import RVService
@preconcurrency import XPC

/// Step 8B P7: `XPCOperatorUIBridge.hookReply` gate tests. Every
/// authority-bearing receive requires handshake + non-discovery +
/// message-authenticated `operatorUI` peer + registered session; every
/// failure answers opaque denial and never falls through to generic IPC.
@Suite("Hook XPC bridge gates")
struct HookBridgeGateTests {
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func handlesRoutesHookKeyOnly() {
        #expect(XPCOperatorUIBridge.handles(hookMessage(.hookList)) == true)
        #expect(XPCOperatorUIBridge.handles(xpc_dictionary_create_empty()) == false)
        // Garbage under the hook key still routes here (deny), never to
        // generic dispatch.
        let garbage = xpc_dictionary_create_empty()
        Data("nope".utf8).withUnsafeBytes { buffer in
            xpc_dictionary_set_data(
                garbage, UIBridgeWire.hookRequestKey, buffer.baseAddress, buffer.count)
        }
        #expect(XPCOperatorUIBridge.handles(garbage) == true)
    }

    @Test func hookListHappyPath() async throws {
        let env = try HookBridgeEnv(now: now)
        defer { env.tearDown() }
        try await env.register()
        let reply = try await env.hookReply(.hookList)
        guard case .uiHookReviewList(let list) = reply.result else {
            Issue.record("hookList must reply a list, got \(reply.result)")
            return
        }
        #expect(list.items.isEmpty)
    }

    @Test func wrongRolePeerIsDenied() async throws {
        let env = try HookBridgeEnv(now: now)
        defer { env.tearDown() }
        try await env.register()
        let reply = try await env.hookReply(
            .hookList, context: peerServiceContext())
        #expect(reply.result == .error(.authorizationDenied))
        let unauth = try await env.hookReply(
            .hookList, context: .unauthenticated)
        #expect(unauth.result == .error(.authorizationDenied))
    }

    @Test func unregisteredSessionIsDenied() async throws {
        let env = try HookBridgeEnv(now: now)
        defer { env.tearDown() }
        // Deliberately not registered.
        let reply = try await env.hookReply(.hookList)
        #expect(reply.result == .error(.authorizationDenied))
    }

    @Test func handshakeAndDiscoveryGatesDeny() async throws {
        let env = try HookBridgeEnv(now: now)
        defer { env.tearDown() }
        let noHandshake = try await env.hookReply(.hookList, handshakeOK: false)
        #expect(noHandshake.result == .error(.authorizationDenied))
        let discovery = try await env.hookReply(.hookList, discoveryOnly: true)
        #expect(discovery.result == .error(.authorizationDenied))
    }

    @Test func garbageBodyIsDenied() async throws {
        let env = try HookBridgeEnv(now: now)
        defer { env.tearDown() }
        try await env.register()
        let garbage = xpc_dictionary_create_empty()
        Data("nope".utf8).withUnsafeBytes { buffer in
            xpc_dictionary_set_data(
                garbage, UIBridgeWire.hookRequestKey, buffer.baseAddress, buffer.count)
        }
        let reply = try await env.rawReply(garbage)
        #expect(reply.result == .error(.authorizationDenied))
    }

    @Test func missingCeremoniesDeny() async throws {
        let env = try HookBridgeEnv(now: now)
        defer { env.tearDown() }
        try await env.register()
        let reply = try await env.hookReply(.hookList, hasCeremonies: false)
        #expect(reply.result == .error(.authorizationDenied))
    }

    @Test func bindDenyRoundTripOverBridge() async throws {
        let env = try HookBridgeEnv(now: now)
        defer { env.tearDown() }
        try await env.register()
        _ = try await env.seed(command: "git reset --hard", id: "bridge-1")

        let bound = try await env.hookReply(.hookBind(approvalID: "bridge-1"))
        guard case .uiHookChallengeBundle(let bundle) = bound.result else {
            Issue.record("bind must reply a bundle, got \(bound.result)")
            return
        }
        #expect(bundle.item.approvalID == "bridge-1")

        // A wrong challenge fails closed through the bridge (opaque deny).
        let forged = try await env.hookReply(.hookDeny(UIHookDeny(
            challengeID: UUID(), approvalID: "bridge-1")))
        #expect(forged.result == .error(.authorizationDenied))

        let denied = try await env.hookReply(.hookDeny(UIHookDeny(
            challengeID: bundle.challenge.challengeID,
            approvalID: bundle.item.approvalID)))
        guard case .uiHookStatus(let status) = denied.result else {
            Issue.record("deny must reply a status, got \(denied.result)")
            return
        }
        #expect(status.status == .denied)
    }
}

private func hookMessage(_ request: UIHookBridgeRequest) -> xpc_object_t {
    let message = xpc_dictionary_create_empty()
    let body = try! IPCJSON.encode(request)
    body.withUnsafeBytes { buffer in
        xpc_dictionary_set_data(
            message, UIBridgeWire.hookRequestKey, buffer.baseAddress, buffer.count)
    }
    return message
}

private final class HookBridgeEnv {
    private let homeURL: URL
    private let allowOnceDirectory: URL
    private let pending = FakePendingApprovals()
    private let sessions = LiveOperatorUISessionRegistry()
    private let ceremonies: HookReviewCeremonyService
    private let peer: AuthenticatedPeer
    private let context: AuthenticatedRequestContext
    private let now: Date

    init(now: Date) throws {
        self.now = now
        homeURL = try isolatedHomeDirectory()
        allowOnceDirectory = try isolatedAllowOnceDirectory()
        let home = try #require(HomeDirectory(validating: homeURL.path))
        ceremonies = HookReviewCeremonyService(
            pending: pending,
            allowOnce: AllowOnceStore(baseDirectory: allowOnceDirectory),
            grants: EphemeralAllowOnceTable(),
            home: home,
            clock: { now }
        )
        let code = PeerCodeIdentity(
            identifier: "peer-hook-bridge-fixture",
            teamIdentifier: nil,
            cdHash: Data([11]),
            executablePath: "/peer-hook-bridge-fixture",
            isAdHoc: true,
            hardenedRuntime: true,
            injectionExceptions: []
        )
        peer = AuthenticatedPeer(
            evidence: PlatformPeerEvidence(
                processID: 4244,
                effectiveUserID: 501,
                auditToken: Data([11]),
                codeIdentity: code,
                componentRole: .operatorUI
            ),
            connectionID: UUID()
        )
        context = .captured(peer: peer, connectionID: UUID())
    }

    @discardableResult
    func register() async throws -> AuthenticatedOperatorUIConnectionID {
        try await sessions.register(peer: peer)
    }

    func tearDown() {
        try? FileManager.default.removeItem(at: homeURL)
        try? FileManager.default.removeItem(at: allowOnceDirectory)
    }

    func hookReply(
        _ request: UIHookBridgeRequest,
        context: AuthenticatedRequestContext? = nil,
        handshakeOK: Bool = true,
        discoveryOnly: Bool = false,
        hasCeremonies: Bool = true
    ) async throws -> IPCResponse {
        let service: HookReviewCeremonyService? = hasCeremonies ? ceremonies : nil
        let response = await XPCOperatorUIBridge.hookReply(
            message: hookMessage(request),
            response: xpc_dictionary_create_empty(),
            context: context ?? self.context,
            handshakeOK: handshakeOK,
            discoveryOnly: discoveryOnly,
            sessions: sessions,
            hookCeremonies: service
        )
        let raw = try #require(response)
        let body = try #require(XPCIPCWire.body(from: raw))
        return try IPCJSON.decode(IPCResponse.self, from: body)
    }

    func rawReply(_ message: xpc_object_t) async throws -> IPCResponse {
        let response = await XPCOperatorUIBridge.hookReply(
            message: message,
            response: xpc_dictionary_create_empty(),
            context: context,
            handshakeOK: true,
            discoveryOnly: false,
            sessions: sessions,
            hookCeremonies: ceremonies
        )
        let raw = try #require(response)
        let body = try #require(XPCIPCWire.body(from: raw))
        return try IPCJSON.decode(IPCResponse.self, from: body)
    }

    func seed(command: String, id: String) async throws {
        let shell = ShellCommand(rawValue: command)
        let cwd = wd("/tmp/ws")
        _ = try await pending.create(
            PendingApprovalRequest(
                id: ApprovalID(rawValue: id),
                identity: ApprovalIdentity(
                    session: SessionID(validating: "sess-pi")!,
                    agent: .pi
                ),
                action: .shell(
                    ShellAction(
                        fingerprint: ActionFingerprint.make(
                            host: .pi,
                            session: SessionID(validating: "sess-pi"),
                            cwd: cwd,
                            command: shell
                        ),
                        scope: ActionScope(workingDirectory: cwd),
                        supportingCommand: shell
                    )
                ),
                reason: .hostAsk,
                continuation: .hostNative,
                timeoutPolicy: .keepWaiting
            ),
            now: now
        )
    }
}
#endif
