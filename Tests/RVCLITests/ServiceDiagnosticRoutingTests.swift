import RVDomain
import RVIPC
import RVPresentation
import Testing
@testable import RVCLI

struct ServiceDiagnosticRoutingTests {
    @Test func validHelloReturnsExistingDoctorSnapshot() async throws {
        let snapshot = serviceSnapshot()
        let transport = ScriptedTransport(
            ack: validAck,
            responseResult: .doctorSnapshot(snapshot)
        )

        let result = try await isolatedClient(transport: transport).diagnostics()

        #expect(result == .xpc(snapshot: snapshot, localCorePacksReady: true))
        #expect(
            ServiceHealth.inspect(result)
                == .reachable(
                    .init(snapshot: snapshot, localCorePacksReady: true, launchAgent: .missing)
                )
        )
        #expect(transport.sendCount == 1)
    }

    @Test func diagnosticRequestUsesDoctorSnapshotMethod() async throws {
        let transport = ScriptedTransport(
            ack: validAck,
            responseResult: .doctorSnapshot(serviceSnapshot())
        )

        _ = try await isolatedClient(transport: transport).diagnostics()

        let request = try #require(transport.sends.first)
        #expect(try IPCJSON.decode(IPCRequest.self, from: request).method == .doctorSnapshot)
    }

    @Test func unavailableServiceReturnsLocalReadinessWithoutSending() async throws {
        let transport = ScriptedTransport(
            ack: validAck,
            helloError: .connectFailed
        )

        let result = try await isolatedClient(transport: transport).diagnostics()

        #expect(result == .local(.init(cause: .down, corePacksReady: true)))
        #expect(
            ServiceHealth.inspect(result)
                == .down(.init(corePacksReady: true, serviceSemver: nil, launchAgent: .missing))
        )
        #expect(transport.sendCount == 0)
    }

    @Test func malformedHelloIsTypedFailureNotMissingService() async throws {
        let transport = ScriptedTransport(
            ack: validAck,
            helloError: .decodeFailed
        )

        let result = try await isolatedClient(transport: transport).diagnostics()

        #expect(
            result == .local(
                .init(
                    cause: .requestFailed(.transport(.decodeFailed)),
                    corePacksReady: true
                )
            )
        )
        #expect(transport.sendCount == 0)
    }

    @Test func protocolSkewReturnsLocalReadinessWithoutSending() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(
                protocolName: "rv.ipc.v0",
                serviceSemver: "1.0.0",
                ok: true,
                skewReason: "protocol"
            )
        )

        let result = try await isolatedClient(transport: transport).diagnostics()

        #expect(
            result == .local(
                .init(
                    cause: .skew(.protocolMismatch),
                    corePacksReady: true,
                    serviceSemver: "1.0.0"
                )
            )
        )
        #expect(transport.sendCount == 0)
        #expect(transport.invalidationCount == 1)
        #expect(
            ServiceHealth.inspect(result)
                == .skew(
                    reason: .protocolMismatch,
                    local: .init(
                        corePacksReady: true,
                        serviceSemver: "1.0.0",
                        launchAgent: .missing
                    )
                )
        )
    }

    @Test func majorVersionSkewReturnsLocalReadinessWithoutSending() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(
                protocolName: "rv.ipc.v1",
                serviceSemver: "2.0.0",
                ok: true
            )
        )

        let result = try await isolatedClient(transport: transport).diagnostics()

        #expect(
            result == .local(
                .init(
                    cause: .skew(.majorVersionMismatch),
                    corePacksReady: true,
                    serviceSemver: "2.0.0"
                )
            )
        )
        #expect(transport.sendCount == 0)
        #expect(transport.invalidationCount == 1)
    }

    @Test func rejectedCoreHandshakeReportsUnavailableLocalCoreWithoutSending() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(
                protocolName: "rv.ipc.v1",
                serviceSemver: "1.0.0",
                ok: false,
                skewReason: "core packs unavailable"
            )
        )

        let result = await ServiceClient.missingCore(transport: transport).diagnostics()

        #expect(
            result == .local(
                .init(
                    cause: .skew(.corePacksUnavailable),
                    corePacksReady: false,
                    serviceSemver: "1.0.0"
                )
            )
        )
        #expect(transport.sendCount == 0)
        #expect(transport.invalidationCount == 1)
    }

    @Test func arbitraryRejectedHandshakeReasonIsNotSurfaced() async throws {
        let transport = ScriptedTransport(
            ack: HelloAckView(
                protocolName: "rv.ipc.v1",
                serviceSemver: "1.0.0",
                ok: false,
                skewReason: "peer supplied detail"
            )
        )
        let client = try isolatedClient(transport: transport)

        let result = await client.diagnostics()
        let status = await client.status()

        #expect(
            result == .local(
                .init(
                    cause: .skew(.rejected),
                    corePacksReady: true,
                    serviceSemver: "1.0.0"
                )
            )
        )
        #expect(status.lastError == "handshake rejected")
        #expect(status.lastError?.contains("peer supplied detail") == false)
        #expect(transport.sendCount == 0)
    }

    @Test func requestInterruptionReturnsTypedLocalFallback() async throws {
        let transport = ScriptedTransport(
            ack: validAck,
            sendError: .interrupted
        )

        let result = try await isolatedClient(transport: transport).diagnostics()

        #expect(
            result == .local(
                .init(
                    cause: .requestFailed(.transport(.interrupted)),
                    corePacksReady: true,
                    serviceSemver: "1.0.0"
                )
            )
        )
        #expect(transport.sendCount == 1)
        #expect(
            ServiceHealth.inspect(result)
                == .requestFailed(
                    failure: .transport(.interrupted),
                    local: .init(
                        corePacksReady: true,
                        serviceSemver: "1.0.0",
                        launchAgent: .missing
                    )
                )
        )
    }

    @Test func wrongResponseReturnsTypedLocalFallback() async throws {
        let transport = ScriptedTransport(
            ack: validAck,
            responseResult: .listPacks(.init(packs: [], enabledCount: 0, totalCount: 0))
        )

        let result = try await isolatedClient(transport: transport).diagnostics()

        #expect(
            result == .local(
                .init(
                    cause: .requestFailed(.unexpectedResponse),
                    corePacksReady: true,
                    serviceSemver: "1.0.0"
                )
            )
        )
    }
}

private let validAck = HelloAckView(
    protocolName: "rv.ipc.v1",
    serviceSemver: "1.0.0",
    ok: true
)

private func serviceSnapshot() -> DoctorSnapshotReply {
    DoctorSnapshotReply(
        serviceSemver: "1.0.0",
        state: .running,
        idleExitSeconds: 300,
        packsEnabled: [.coreGit, .coreFilesystem],
        checks: [
            DoctorCheck(id: "xpc", status: .ok, message: "listener"),
            DoctorCheck(id: "protocol", status: .ok, message: "rv.ipc.v1"),
            DoctorCheck(id: "packs", status: .ok, message: "core packs loaded"),
        ]
    )
}
