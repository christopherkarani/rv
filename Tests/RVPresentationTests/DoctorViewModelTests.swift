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

private let missingHosts = HookHost.setupSlotOrder.map {
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
    #expect(model.hosts.map(\.host) == HookHost.setupSlotOrder)
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

@Test func doctorViewModel_serviceDownIsUnhealthyEvenWithReadyFallback() {
    for state: DoctorServiceState in [.down, .notInstalled, .skew] {
        let service = DoctorServiceView(
            state: state,
            protocolName: "rv.ipc.v1",
            serviceSemver: "1.0.0" as String?,
            label: "dev.rv.evaluate",
            fallback: .ready,
            launchAgent: .loaded
        )
        let model = DoctorViewModel(
            service: service,
            packs: readyPacks,
            hosts: missingHosts,
            config: .readable
        )
        #expect(model.isHealthy == false, "service \(state.rawValue) must grade ok false")
        #expect(doctorRobotPayload(from: model).isHealthy == false)
    }
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

@Test func doctorViewModel_leftoversNeverChangeHealth() {
    var model = DoctorViewModel(
        service: DoctorServiceView(
            state: .running,
            protocolName: "rv.ipc.v1",
            serviceSemver: "1.0.0",
            label: "dev.rv.evaluate",
            fallback: .ready,
            launchAgent: .loaded
        ),
        packs: DoctorPacksView(enabled: dayOnePackIDs, registry: .ready),
        hosts: [],
        config: .readable
    )
    #expect(model.leftovers == nil)
    #expect(model.isHealthy)
    model.leftovers = .summary(DoctorLeftoversSummary(sessions: 3, strandedImages: 100, unattachedImageFiles: 484))
    #expect(model.isHealthy)
    #expect(DoctorLeftoversSummary(sessions: 0, strandedImages: 0, unattachedImageFiles: 0).isEmpty)
    #expect(DoctorLeftoversSummary(sessions: 0, strandedImages: nil, unattachedImageFiles: 0).isEmpty == false)
}
