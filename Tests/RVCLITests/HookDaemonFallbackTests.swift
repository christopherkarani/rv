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

    @Test(arguments: HookHost.allCases)
    func ownerObserveStepsAsideOnlyForAnAbsentDaemon(host: HookHost) {
        let allow = productionHostCodec(host).encodeAllow()
        let stepAside = HookWire(
            stdout: allow.stdout, exitCode: allow.exitCode, stderr: HookObserveFallback.message + "\n")
        for failure in HookDaemonFailure.allCases {
            for mode in [HookWhenDown.ask, .deny] {
                let wire = HookDaemonFallback.wire(host: host, failure: failure, mode: mode, ownerObserves: true)
                if failure == .unreachable {
                    #expect(wire == stepAside)
                } else {
                    // A slow daemon (which an agent can cause) keeps the mode's
                    // render; impersonation and malformed replies still deny.
                    #expect(wire == HookDaemonFallback.wire(host: host, failure: failure, mode: mode))
                }
            }
        }
    }

    @Test func observeMessageMatchesTheCClient() throws {
        let cSource = try String(
            contentsOf: URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Sources/rv-c/hook_fallback.c"),
            encoding: .utf8
        )
        #expect(cSource.contains("\"\(HookObserveFallback.message)\""), "C/Swift observe message drift")
        #expect(HookObserveFallback.message.contains("rv doctor"))
    }

    @Test func clientStepsAsideOnAMissWhenTheOwnerObserves() async throws {
        let observes: @Sendable (HookHost) -> Bool = { _ in true }
        // `.connectFailed` is the transports' positive-absence signal: connect
        // failed before any request byte was sent.
        let absent = ScriptedTransport(
            ack: HelloAckView(protocolName: ProtocolVersion.name, serviceSemver: "1.0.0", status: .ok),
            sendError: .connectFailed
        )
        let missing = try isolatedClient(transport: absent)
        let unreachable = await missing.hookEvaluate(
            host: .claude, stdin: "{}", whenDown: .ask, ownerObserves: observes)
        #expect(unreachable == HookDaemonFallback.wire(
            host: .claude, failure: .unreachable, mode: .ask, ownerObserves: true))
        #expect(unreachable.stdout.isEmpty && unreachable.exitCode == 0)

        // An explicit RV_HOOK_WHEN_DOWN=deny is the stricter choice and wins.
        let explicitDeny = await missing.hookEvaluate(
            host: .claude, stdin: "{}", whenDown: .deny, ownerObserves: observes)
        #expect(explicitDeny == HookDaemonFallback.wire(host: .claude, failure: .unreachable, mode: .deny))

        // No transport resolved (Linux: XDG_RUNTIME_DIR empty or over-long) and
        // a dropped connection prove nothing about rvd: they keep asking.
        let unresolved = try await isolatedClient(transport: nil).hookEvaluate(
            host: .claude, stdin: "{}", whenDown: .ask, ownerObserves: observes)
        #expect(unresolved == HookDaemonFallback.wire(host: .claude, failure: .connection, mode: .ask))
        let dropped = ScriptedTransport(
            ack: HelloAckView(protocolName: ProtocolVersion.name, serviceSemver: "1.0.0", status: .ok),
            sendError: .interrupted
        )
        let drop = try await isolatedClient(transport: dropped).hookEvaluate(
            host: .claude, stdin: "{}", whenDown: .ask, ownerObserves: observes)
        #expect(drop == HookDaemonFallback.wire(host: .claude, failure: .connection, mode: .ask),
                "a dropped connection still asks under observe")

        let slow = ScriptedTransport(
            ack: HelloAckView(protocolName: ProtocolVersion.name, serviceSemver: "1.0.0", status: .ok),
            sendError: .timeout
        )
        let timeout = try await isolatedClient(transport: slow).hookEvaluate(
            host: .cursor, stdin: "{}", whenDown: .ask, ownerObserves: observes)
        #expect(timeout == HookDaemonFallback.wire(host: .cursor, failure: .timeout, mode: .ask),
                "a slow daemon still asks under observe")

        let skewed = ScriptedTransport(
            ack: HelloAckView(protocolName: ProtocolVersion.name, serviceSemver: "1.0.0", status: .ok),
            responseResult: .error(.protocolSkew(.protocolSkew))
        )
        let protocolMiss = try await isolatedClient(transport: skewed).hookEvaluate(
            host: .claude, stdin: "{}", whenDown: .ask, ownerObserves: observes)
        #expect(protocolMiss == HookDaemonFallback.wire(host: .claude, failure: .protocol, mode: .deny))
    }

    /// `.unreachable` is the only class observe mode allows on, so it is
    /// reserved for a connect that failed before anything was sent. Every
    /// other failure, including errors this classifier does not recognize,
    /// keeps ask/deny (`.connection` / `.timeout`) or always denies.
    @Test func classifiesTransportErrors() {
        #expect(HookDaemonFallback.classify(ServiceTransportError.timeout) == .timeout)
        #expect(HookDaemonFallback.classify(ServiceTransportError.connectFailed) == .unreachable)
        #expect(HookDaemonFallback.classify(ServiceTransportError.interrupted) == .connection)
        #expect(HookDaemonFallback.classify(ServiceTransportError.decodeFailed) == .protocol)
        #expect(HookDaemonFallback.classify(ServiceTransportError.unexpected) == .protocol)
        #expect(HookDaemonFallback.classify(
            DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad reply"))) == .protocol)
        // Unrecognized errors used to read as an absent daemon, which observe
        // mode now turns into an allow; they must not.
        #expect(HookDaemonFallback.classify(CocoaError(.coderReadCorrupt)) == .connection)
        #expect(HookDaemonFallback.classify(CancellationError()) == .connection)
#if canImport(XPC)
        #expect(HookDaemonFallback.classify(XPCEvaluateClientError.authenticationFailed) == .untrusted)
        #expect(HookDaemonFallback.classify(XPCEvaluateClientError.connectFailed) == .unreachable)
        #expect(HookDaemonFallback.classify(XPCEvaluateClientError.connectionLost) == .connection)
        #expect(HookDaemonFallback.classify(XPCEvaluateClientError.malformedReply) == .protocol)
        #expect(HookDaemonFallback.classify(XPCEvaluateClientError.cancelled) == .connection)
#endif
#if os(Linux)
        typealias Failure = UnixServiceConnection.TransportFailure
        #expect(HookDaemonFallback.classify(Failure.untrustedDaemon) == .untrusted)
        #expect(HookDaemonFallback.classify(Failure.frameTooLarge) == .protocol)
        #expect(HookDaemonFallback.classify(Failure.io(EAGAIN)) == .timeout)
        #expect(HookDaemonFallback.classify(Failure.io(EWOULDBLOCK)) == .timeout)
        #expect(HookDaemonFallback.classify(Failure.io(ECONNRESET)) == .connection)
        #expect(HookDaemonFallback.classify(Failure.io(EPIPE)) == .connection)
        #expect(HookDaemonFallback.classify(Failure.connect(EAGAIN)) == .timeout)
        #expect(HookDaemonFallback.classify(Failure.connect(ETIMEDOUT)) == .timeout)
        // A raw connect miss is not proof: only the transport, which knows the
        // socket is the uid-derived one, turns it into `.connectFailed`.
        #expect(HookDaemonFallback.classify(Failure.connect(ENOENT)) == .connection)
        #expect(HookDaemonFallback.classify(Failure.connect(ECONNREFUSED)) == .connection)
        #expect(HookDaemonFallback.classify(Failure.connect(EACCES)) == .connection)
        #expect(HookDaemonFallback.classify(Failure.noSocketPath) == .connection)
#endif
    }

#if os(Linux)
    /// Mirrors run.sh's XDG cases for the C hook: a connect miss steps aside
    /// only on the uid-derived socket, never under an agent-chosen
    /// XDG_RUNTIME_DIR.
    @Test func linuxConnectMissIsAbsentOnlyOnTheOwnerRuntimeSocket() async throws {
        let missing = "/tmp/rv-miss-\(UUID().uuidString.prefix(8))/rv/evaluate.sock"
        for (ownerRuntime, want) in [(true, HookDaemonFailure.unreachable), (false, .connection)] {
            let transport = UnixSocketServiceTransport(socketPath: missing, ownerRuntimeSocket: ownerRuntime)
            do {
                _ = try await transport.sendHookConsult(Data("{}".utf8), timeoutMs: 100)
                Issue.record("connect to a missing socket succeeded")
            } catch {
                #expect(HookDaemonFallback.classify(error) == want, "ownerRuntime=\(ownerRuntime): \(error)")
            }
        }
    }
#endif

    @Test func missingTransportIsAConnectionFailureAndFollowsMode() async throws {
        let client = try isolatedClient(transport: nil)
        let connection = HookDaemonFallback.message(for: .connection)
        let ask = await client.hookEvaluate(host: .claude, stdin: "{}", whenDown: .ask)
        #expect(ask == HookDaemonFallback.wire(host: .claude, failure: .connection, mode: .ask))
        let deny = await client.hookEvaluate(host: .codex, stdin: "{}", whenDown: .deny)
        #expect(deny.exitCode == 2)
        #expect(deny.stderr.contains(connection))
        let grok = await client.hookEvaluate(host: .grok, stdin: "{}", whenDown: .ask)
        #expect(grok == HookDaemonFallback.wire(host: .grok, failure: .connection, mode: .deny),
                "hosts without an ask primitive deny")
    }

    @Test func defaultModeComesFromTheProcessEnvironment() async throws {
        let client = try isolatedClient(transport: nil)
        let unset = await CLIProcess.$context.withValue(CLIProcess.Context(environment: [:])) {
            await client.hookEvaluate(host: .claude, stdin: "{}")
        }
        #expect(unset == HookDaemonFallback.wire(host: .claude, failure: .connection, mode: .ask))
        let deny = await CLIProcess.$context.withValue(
            CLIProcess.Context(environment: [HookWhenDown.environmentKey: "deny"])
        ) {
            await client.hookEvaluate(host: .claude, stdin: "{}")
        }
        #expect(deny == HookDaemonFallback.wire(host: .claude, failure: .connection, mode: .deny))
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
