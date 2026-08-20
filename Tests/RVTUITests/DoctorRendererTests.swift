import RVDomain
import RVPresentation
import RVTheme
import RVTUI
import Testing

private let doctorRendererFixture = DoctorViewModel(
    service: DoctorServiceView(
        state: .running,
        protocolName: "rv.ipc.v1",
        serviceSemver: "1.0.0" as String?,
        label: "dev.rv.evaluate",
        fallback: .ready,
        launchAgent: .loaded
    ),
    packs: DoctorPacksView(
        enabled: dayOnePackIDs,
        registry: .ready
    ),
    hosts: [
        DoctorHostView(host: .grok, state: .wired),
        DoctorHostView(host: .pi, state: .missing),
        DoctorHostView(host: .openCode, state: .absentFile),
    ],
    config: .readable
)

@Test func doctorRenderer_emitsOneFactPerLine() {
    let lines = DoctorRenderer().render(doctorRendererFixture, palette: colorOffPalette)

    #expect(lines == [
        "service: running",
        "protocol: rv.ipc.v1",
        "service-version: 1.0.0 (compatible)",
        "service-label: dev.rv.evaluate",
        "fallback: ready",
        "launch-agent: loaded",
        "packs: core.filesystem and core.git enabled; extras off",
        "host Grok: wired",
        "host Pi: missing — run rv setup",
        "host OpenCode: absent-file — run rv setup",
        "config: readable",
        "grade: hook",
    ])
}

@Test func doctorRenderer_usesHumanServiceStateText() {
    var fixture = doctorRendererFixture
    fixture.service.state = .notInstalled
    fixture.service.serviceSemver = nil

    let lines = DoctorRenderer().render(fixture, palette: colorOffPalette)

    #expect(lines.contains("service: not installed"))
    #expect(lines.contains("service-version: unavailable"))
}

@Test func doctorRenderer_nonWiredHostsHaveOneSetupAction() {
    let lines = DoctorRenderer().render(doctorRendererFixture, palette: colorOffPalette)

    #expect(lines.filter { $0.contains("run rv setup") }.count == 2)
    #expect(lines.first { $0.contains("host Grok") }?.contains("rv setup") == false)
}

@Test func doctorRenderer_brokenRegistryDoesNotClaimPacksAreMissing() {
    var fixture = doctorRendererFixture
    fixture.packs.registry = .broken

    let lines = DoctorRenderer().render(fixture, palette: colorOffPalette)

    #expect(lines.contains("packs: broken"))
    #expect(lines.contains("packs: missing ") == false)
}

@Test func doctorRenderer_hasNoANSIOrBoxDrawing() {
    let output = DoctorRenderer()
        .render(doctorRendererFixture, palette: colorOffPalette)
        .joined(separator: "\n")

    #expect(output.contains("\u{001B}") == false)
    #expect(output.contains("═") == false)
    #expect(output.contains("│") == false)
}
