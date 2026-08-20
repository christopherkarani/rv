import RVDomain
import RVIPC
import RVPresentation
import Testing
@testable import RVCLI

struct ServiceHealthTests {
    @Test func omittedLaunchAgentKeepsDownFromBecomingNotInstalled() {
        let diagnostics = local(.down)
        let health = ServiceHealth.inspect(diagnostics)

        #expect(health == .down(readyLocal()))
        #expect(health.fallbackReady)
        #expect(health.enabledPacks == dayOnePackIDs)
        #expect(health.packCheckReady)
        #expect(health.launchAgent == .missing)
    }

    @Test func observedMissingLaunchAgentMakesDownNotInstalled() {
        let health = ServiceHealth.inspect(
            local(.down),
            launchAgentInstalled: false,
            launchAgentLoaded: false
        )

        #expect(health == .notInstalled(readyLocal()))
        #expect(health.launchAgent == .missing)
        #expect(health.statusReport.state == "down")
        #expect(health.statusReport.fallback == "down")
        #expect(health.statusReport.lastError == nil)
    }

    @Test func installedLaunchAgentKeepsDownFromBecomingNotInstalled() {
        let health = ServiceHealth.inspect(
            local(.down),
            launchAgentInstalled: true,
            launchAgentLoaded: false
        )

        #expect(health == .down(readyLocal(launchAgent: .installed)))
        #expect(health.launchAgent == .installed)
    }

    @Test func loadedLaunchAgentWinsOverInstalledOnDown() {
        let health = ServiceHealth.inspect(
            local(.down),
            launchAgentInstalled: true,
            launchAgentLoaded: true
        )

        #expect(health == .down(readyLocal(launchAgent: .loaded)))
        #expect(health.launchAgent == .loaded)
    }

    @Test func skewMeaningIsIndependentOfLaunchAgent() {
        let diagnostics = local(.skew(.protocolMismatch), serviceSemver: "1.0.0")

        #expect(
            ServiceHealth.inspect(diagnostics)
                == .skew(reason: .protocolMismatch, local: readyLocal(serviceSemver: "1.0.0"))
        )
        #expect(
            ServiceHealth.inspect(
                diagnostics,
                launchAgentInstalled: false,
                launchAgentLoaded: false
            ) == .skew(reason: .protocolMismatch, local: readyLocal(serviceSemver: "1.0.0"))
        )
    }

    @Test func requestFailedMeaningIsIndependentOfLaunchAgent() {
        let diagnostics = local(.requestFailed(.invalidResponse), serviceSemver: "1.0.0")

        #expect(
            ServiceHealth.inspect(diagnostics)
                == .requestFailed(
                    failure: .invalidResponse,
                    local: readyLocal(serviceSemver: "1.0.0")
                )
        )
        #expect(
            ServiceHealth.inspect(
                diagnostics,
                launchAgentInstalled: true,
                launchAgentLoaded: true
            ) == .requestFailed(
                failure: .invalidResponse,
                local: readyLocal(serviceSemver: "1.0.0", launchAgent: .loaded)
            )
        )
    }

    @Test func reachableSnapshotKeepsLocalFallbackAndPackChecks() {
        let snapshot = runningSnapshot()
        let health = ServiceHealth.inspect(
            .xpc(snapshot: snapshot, localCorePacksReady: true),
            launchAgentInstalled: false,
            launchAgentLoaded: true
        )

        #expect(
            health == .reachable(
                .init(snapshot: snapshot, localCorePacksReady: true, launchAgent: .loaded)
            )
        )
        #expect(health.fallbackReady)
        #expect(health.enabledPacks == snapshot.packsEnabled)
        #expect(health.packCheckReady)
    }

    @Test func emptyEnabledPacksMeansNone() {
        let health = ServiceHealth.inspect(local(.down, corePacksReady: false))

        #expect(health.enabledPacks.isEmpty)
        #expect(health.packCheckReady == false)
        #expect(health.fallbackReady == false)
    }

    @Test func reachableWithoutPacksCheckIsNotPackReady() {
        let snapshot = DoctorSnapshotReply(
            serviceSemver: "1.0.0",
            state: .running,
            idleExitSeconds: 300,
            packsEnabled: dayOnePackIDs,
            checks: []
        )
        let health = ServiceHealth.inspect(.xpc(snapshot: snapshot, localCorePacksReady: true))

        #expect(health.packCheckReady == false)
        #expect(health.enabledPacks == dayOnePackIDs)
        #expect(health.fallbackReady)
    }
}

private func local(
    _ cause: ServiceFallbackCause,
    corePacksReady: Bool = true,
    serviceSemver: String? = nil
) -> ServiceDiagnosticResult {
    .local(
        ServiceFallbackDiagnostic(
            cause: cause,
            corePacksReady: corePacksReady,
            serviceSemver: serviceSemver
        )
    )
}

private func readyLocal(
    serviceSemver: String? = nil,
    launchAgent: DoctorLaunchAgentState = .missing
) -> ServiceHealth.Local {
    ServiceHealth.Local(
        corePacksReady: true,
        serviceSemver: serviceSemver,
        launchAgent: launchAgent
    )
}

private func runningSnapshot() -> DoctorSnapshotReply {
    DoctorSnapshotReply(
        serviceSemver: "1.0.0",
        state: .running,
        idleExitSeconds: 300,
        packsEnabled: dayOnePackIDs,
        checks: [DoctorCheck(id: "packs", status: .ok, message: "ready")]
    )
}
