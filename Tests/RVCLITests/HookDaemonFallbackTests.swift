import Foundation
import Testing
import RVDomain
import RVHooks
import RVIPC
import RVService
@testable import RVCLI

/// Swift twin of `Sources/rv-c/tests/hook_fallback_test.c`: a daemon miss
/// is classified and rendered per `RV_HOOK_WHEN_DOWN`, never one generic deny.
struct HookDaemonFallbackTests {
    private static let unreachable = HookDaemonFallback.message(for: .unreachable)

    private static func json(_ wire: HookWire) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: Data(wire.stdout.utf8)) as? [String: Any])
    }

    @Test func whenDownParsesExactValuesAndDefaultsToAsk() {
        #expect(HookWhenDown(environmentValue: nil) == .ask)
        #expect(HookWhenDown(environmentValue: "") == .ask)
        #expect(HookWhenDown(environmentValue: "deny") == .deny)
        // No bypass value: "allow" can come from agent-writable host config.
        #expect(HookWhenDown(environmentValue: "allow") == .ask)
        #expect(HookWhenDown(environmentValue: "ALLOW") == .ask)
        #expect(HookWhenDown(environmentValue: "1") == .ask)
    }

    @Test func messagesAreDistinctActionableAndMatchTheCClient() throws {
        let messages = HookDaemonFailure.allCases.map(HookDaemonFallback.message(for:))
        #expect(Set(messages).count == messages.count)
        #expect(Self.unreachable.contains("rv doctor"))
        #expect(HookDaemonFallback.message(for: .untrusted).contains("rv setup"))
        let cSource = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/rv-c/hook_fallback.c"),
            encoding: .utf8
        )
        for message in messages {
            #expect(cSource.contains("\"\(message)\""), "C/Swift message drift: \(message)")
        }
    }

    @Test func askModeUsesNativeAskOnClaudeAndCursor() throws {
        let claude = HookDaemonFallback.wire(host: .claude, failure: .unreachable, mode: .ask)
        #expect(claude.exitCode == 0)
        #expect(claude.stdout == "{\"hookSpecificOutput\":{\"hookEventName\":\"PreToolUse\",\"permissionDecision\":\"ask\",\"permissionDecisionReason\":\"\(Self.unreachable)\"},\"systemMessage\":\"\(Self.unreachable)\"}\n")
        let claudeJSON = try Self.json(claude)
        let output = try #require(claudeJSON["hookSpecificOutput"] as? [String: Any])
        #expect(output["permissionDecision"] as? String == "ask")

        let cursor = HookDaemonFallback.wire(host: .cursor, failure: .timeout, mode: .ask)
        let cursorJSON = try Self.json(cursor)
        #expect(cursor.exitCode == 0)
        #expect(cursorJSON["permission"] as? String == "ask")
        #expect(cursorJSON["agent_message"] as? String == HookDaemonFallback.message(for: .timeout))
        #expect(cursor.stdout.contains("Wait for the human") == false)
    }

    @Test(arguments: HookHost.allCases)
    func everyHostRendersEachMode(host: HookHost) throws {
        for failure in HookDaemonFailure.allCases {
            let message = HookDaemonFallback.message(for: failure)
            let codecDeny = productionHostCodec(host).encodeDeny(reason: message, rule: nil, next: .none)

            #expect(HookDaemonFallback.wire(host: host, failure: failure, mode: .deny) == codecDeny)

            let ask = HookDaemonFallback.wire(host: host, failure: failure, mode: .ask)
            if failure == .untrusted || failure == .protocol {
                // Impersonation and malformed replies never soften.
                #expect(ask == codecDeny)
            } else if host == .claude || host == .cursor {
                #expect(ask.stdout.contains("\"ask\""))
                #expect(ask.stdout.contains(message))
                #expect(ask.exitCode == 0)
            } else {
                // No ask primitive: the host's own deny wire, exit code included.
                #expect(ask == codecDeny)
            }
        }
    }

    @Test func classifiesTransportFailuresExhaustively() {
        #expect(HookDaemonFallback.classify(.timeout) == .timeout)
        #expect(HookDaemonFallback.classify(.unreachable) == .unreachable)
        #expect(HookDaemonFallback.classify(.untrusted) == .untrusted)
        #expect(HookDaemonFallback.classify(.malformedReply) == .protocol)
    }

#if canImport(XPC)
    @Test func xpcTransportMapsUnforeseenErrorsToMalformedReply() {
        let map = XPCServiceTransport.transportFailure(from:)
        #expect(map(ServiceTransportFailure.timeout) == .timeout)
        #expect(map(XPCEvaluateClientError.authenticationFailed) == .untrusted)
        #expect(map(XPCEvaluateClientError.connectFailed) == .unreachable)
        #expect(map(XPCEvaluateClientError.cancelled) == .unreachable)
        #expect(map(XPCEvaluateClientError.malformedReply) == .malformedReply)
        #expect(map(CancellationError()) == .unreachable)
        #expect(map(CocoaError(.coderReadCorrupt)) == .malformedReply)
        #expect(map(DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "garbage"))) == .malformedReply)
        #expect(HookDaemonFallback.classify(map(CocoaError(.coderReadCorrupt))) == .protocol)
    }
#endif

    @Test func missingTransportIsUnreachableAndFollowsMode() async throws {
        let client = try isolatedClient(transport: nil)
        let ask = await client.hookEvaluate(host: .claude, stdin: "{}", whenDown: .ask)
        #expect(ask == HookDaemonFallback.wire(host: .claude, failure: .unreachable, mode: .ask))
        let deny = await client.hookEvaluate(host: .codex, stdin: "{}", whenDown: .deny)
        #expect(deny.exitCode == 2)
        #expect(deny.stderr.contains(Self.unreachable))
        let grok = await client.hookEvaluate(host: .grok, stdin: "{}", whenDown: .ask)
        #expect(grok == HookDaemonFallback.wire(host: .grok, failure: .unreachable, mode: .deny),
                "hosts without an ask primitive deny")
    }

    @Test func defaultModeComesFromTheProcessEnvironment() async throws {
        let client = try isolatedClient(transport: nil)
        let unset = await CLIProcess.$context.withValue(CLIProcess.Context(environment: [:])) {
            await client.hookEvaluate(host: .claude, stdin: "{}")
        }
        #expect(unset == HookDaemonFallback.wire(host: .claude, failure: .unreachable, mode: .ask))
        let deny = await CLIProcess.$context.withValue(
            CLIProcess.Context(environment: [HookWhenDown.environmentKey: "deny"])
        ) {
            await client.hookEvaluate(host: .claude, stdin: "{}")
        }
        #expect(deny == HookDaemonFallback.wire(host: .claude, failure: .unreachable, mode: .deny))
    }

    @Test func transportTimeoutIsClassifiedAndUsesTheHookBudget() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: ProtocolVersion.name, serviceSemver: "1.0.0", status: .ok),
            sendError: .timeout
        )
        let client = try isolatedClient(transport: transport)
        let wire = await client.hookEvaluate(host: .claude, stdin: "{}", whenDown: .ask)
        #expect(wire == HookDaemonFallback.wire(host: .claude, failure: .timeout, mode: .ask))
        #expect(transport.lastSendTimeoutMs == ServiceClient.hookEvaluateTimeoutMs)
        #expect(transport.sendCount == 1, "a hook request is never resent")
    }

    @Test func undecodableReplyDeniesUnderWhenDownAskAndInvalidates() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: ProtocolVersion.name, serviceSemver: "1.0.0", status: .ok),
            sendReply: Data("{not json".utf8)
        )
        let client = try isolatedClient(transport: transport)
        let wire = await client.hookEvaluate(host: .claude, stdin: "{}", whenDown: .ask)
        #expect(wire == HookDaemonFallback.wire(host: .claude, failure: .protocol, mode: .ask))
        #expect(wire.stdout.contains("\"deny\""))
        #expect(transport.invalidationCount == 1)
    }

    @Test func emptyReplyDeniesUnderWhenDownAsk() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: ProtocolVersion.name, serviceSemver: "1.0.0", status: .ok)
        )
        let client = try isolatedClient(transport: transport)
        let wire = await client.hookEvaluate(host: .claude, stdin: "{}", whenDown: .ask)
        #expect(wire == HookDaemonFallback.wire(host: .claude, failure: .protocol, mode: .ask))
    }

    @Test func serviceErrorReplyIsProtocol() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(protocolName: ProtocolVersion.name, serviceSemver: "1.0.0", status: .ok),
            responseResult: .error(.protocolSkew(.protocolSkew))
        )
        let client = try isolatedClient(transport: transport)
        let wire = await client.hookEvaluate(host: .cursor, stdin: "{}", whenDown: .ask)
        #expect(wire == HookDaemonFallback.wire(host: .cursor, failure: .protocol, mode: .deny),
                "a protocol failure denies even in ask mode")
        #expect(wire.stdout.contains("\"deny\""))
        #expect(transport.invalidationCount == 1)
    }
}
