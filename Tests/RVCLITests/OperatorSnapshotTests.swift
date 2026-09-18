import RVDomain
import RVIPC
import RVPolicy
import RVPresentation
import Testing
@testable import RVCLI

struct OperatorSnapshotTests {
    @Test func project_usesHomePacksNotServiceSnapshot() throws {
        let snapshot = OperatorSnapshot.project(
            OperatorInputs(
                diagnostics: .xpc(
                    snapshot: DoctorSnapshotReply(
                        serviceSemver: "1.0.0",
                        state: .running,
                        idleExitSeconds: 300,
                        packsEnabled: [.coreGit],
                        checks: [DoctorCheck(id: .packs, status: .ok, message: "ready")]
                    ),
                    localCorePacksReady: true
                ),
                launchAgent: .observed(.loaded),
                packs: .home(dayOnePackIDs),
                hosts: try missingHosts()
            )
        )

        #expect(snapshot.packs == .home(dayOnePackIDs))
        #expect(snapshot.health.enabledPacks == [.coreGit])
        #expect(snapshot.health.packCheckReady)
        #expect(snapshot.health.launchAgent == .loaded)
        #expect(
            DoctorRun.packsView(snapshot.packs, packCheckReady: snapshot.health.packCheckReady)
                .enabled == dayOnePackIDs
        )
    }

    @Test func project_unreadableHomePacksStayBroken() throws {
        let snapshot = OperatorSnapshot.project(
            OperatorInputs(
                diagnostics: .local(
                    ServiceFallbackDiagnostic(cause: .down, corePacksReady: true)
                ),
                launchAgent: .observed(.missing),
                packs: .unreadable,
                hosts: try missingHosts()
            )
        )

        #expect(snapshot.packs == .unreadable)
        let view = DoctorRun.packsView(
            snapshot.packs,
            packCheckReady: snapshot.health.packCheckReady
        )
        #expect(view.enabled.isEmpty)
        #expect(view.registry == .broken)
    }

    @Test func project_unknownLaunchAgentKeepsDownFromBecomingNotInstalled() throws {
        let snapshot = OperatorSnapshot.project(
            OperatorInputs(
                diagnostics: .local(
                    ServiceFallbackDiagnostic(cause: .down, corePacksReady: true)
                ),
                launchAgent: .unknown,
                packs: .home(dayOnePackIDs),
                hosts: try missingHosts()
            )
        )

        #expect(snapshot.health == ServiceHealth.inspect(
            .local(ServiceFallbackDiagnostic(cause: .down, corePacksReady: true))
        ))
        guard case .down = snapshot.health else {
            Issue.record("unknown LaunchAgent must not promote down to not-installed")
            return
        }
    }
}

private func missingHosts() throws -> HostAdapterInstallationSnapshot {
    let layout = OwnedPaths(home: try #require(HomeDirectory(validating: "/tmp/rv-operator")))
    return HostAdapterInstallationSnapshot(
        grok: .missing(layout.hostAdapter(for: .grok)),
        pi: .missing(layout.hostAdapter(for: .pi)),
        openCode: .missing(layout.hostAdapter(for: .opencode)),
        claude: .missing(layout.hostAdapter(for: .claude)),
        openClaw: .missing(layout.hostAdapter(for: .openclaw)),
        hermes: .missing(layout.hostAdapter(for: .hermes)),
        codex: .missing(layout.hostAdapter(for: .codex)),
        cursor: .missing(layout.hostAdapter(for: .cursor))
    )
}
