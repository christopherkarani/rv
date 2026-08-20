import RVDomain
import RVPresentation
import Testing

private let readyService = DoctorServiceView(
    state: .running,
    protocolName: "rv.ipc.v1",
    serviceSemver: "1.0.0" as String?,
    label: "dev.rv.evaluate",
    fallback: .ready,
    launchAgent: .loaded
)

private let readyPacks = DoctorPacksView(
    enabled: dayOnePackIDs,
    registry: .ready
)

private let missingHosts = SetupHostKind.allCases.map {
    DoctorHostView(host: $0, state: .missing)
}

@Test func doctorViewModel_readyPacksAndReadableConfigAreHealthy() {
    let model = DoctorViewModel(
        service: readyService,
        packs: readyPacks,
        hosts: missingHosts,
        config: .readable
    )

    #expect(model.isHealthy)
    #expect(model.grade == .hook)
    #expect(model.hosts.map(\.host) == SetupHostKind.allCases)
}

@Test func doctorViewModel_missingDayOnePackIsUnhealthy() {
    let packs = DoctorPacksView(
        enabled: [.coreGit],
        registry: .ready
    )
    let model = DoctorViewModel(
        service: readyService,
        packs: packs,
        hosts: missingHosts,
        config: .readable
    )

    #expect(model.isHealthy == false)
}

@Test func doctorViewModel_unreadableConfigIsUnhealthy() {
    let model = DoctorViewModel(
        service: readyService,
        packs: readyPacks,
        hosts: missingHosts,
        config: .unreadable
    )

    #expect(model.isHealthy == false)
}
