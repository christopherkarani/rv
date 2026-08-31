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
        DoctorHostView(host: .opencode, state: .absentFile),
        DoctorHostView(host: .claude, state: .missing),
    ],
    config: .readable
)

@Test func doctorRenderer_emitsSectionedPrettyFacts() {
    let lines = DoctorRenderer().render(doctorRendererFixture, palette: colorOffPalette)

    #expect(lines == [
        "  Service",
        "  •  running        1.0.0 · rv.ipc.v1",
        "                    dev.rv.evaluate · launch-agent loaded · fallback ready",
        "",
        "  Hosts",
        "  •  Grok      wired",
        "  ◦  Pi        missing",
        "  ◦  OpenCode  absent-file",
        "  ◦  Claude    missing",
        "",
        "  Packs",
        "    core.filesystem · core.git · system.disk",
        "    extras off",
        "",
        "  Config",
        "    readable · grade hook",
        "",
        "  Next",
        "  →  rv setup    Wire Pi, OpenCode, and Claude",
    ])
}

@Test func doctorRenderer_usesHumanServiceStateText() {
    var fixture = doctorRendererFixture
    fixture.service.state = .notInstalled
    fixture.service.serviceSemver = nil

    let lines = DoctorRenderer().render(fixture, palette: colorOffPalette)
    let joined = lines.joined(separator: "\n")

    #expect(joined.contains("not installed"))
    #expect(joined.contains("unavailable"))
}

@Test func doctorRenderer_missingHostsGetSetupNextNotOccupied() {
    let lines = DoctorRenderer().render(doctorRendererFixture, palette: colorOffPalette)
    let joined = lines.joined(separator: "\n")

    #expect(joined.contains("→  rv setup    Wire Pi, OpenCode, and Claude"))
    #expect(joined.contains("Grok") && joined.contains("wired"))
    #expect(lines.contains { $0.contains("Grok") && $0.contains("rv setup") } == false)
}

@Test func doctorRenderer_occupiedHostsDoNotClaimSetupFixesThem() {
    var fixture = doctorRendererFixture
    fixture.hosts = [
        DoctorHostView(host: .grok, state: .wired),
        DoctorHostView(host: .pi, state: .occupied),
        DoctorHostView(host: .opencode, state: .occupied),
        DoctorHostView(host: .claude, state: .wired),
    ]

    let lines = DoctorRenderer().render(fixture, palette: colorOffPalette)
    let joined = lines.joined(separator: "\n")

    #expect(joined.contains("→  rv setup --force    Replace occupied Pi and OpenCode"))
    #expect(joined.contains("→  rv setup    Wire") == false)
}

@Test func doctorRenderer_brokenRegistryDoesNotClaimPacksAreMissing() {
    var fixture = doctorRendererFixture
    fixture.packs.registry = .broken

    let lines = DoctorRenderer().render(fixture, palette: colorOffPalette)
    let joined = lines.joined(separator: "\n")

    #expect(joined.contains("broken"))
    #expect(joined.contains("missing ") == false)
}

@Test func doctorRenderer_extrasAreCountedNotListed() {
    var fixture = doctorRendererFixture
    fixture.packs = DoctorPacksView(
        enabled: dayOnePackIDs + [
            PackID(rawValue: "core.network"),
            PackID(rawValue: "strict_git"),
            PackID(rawValue: "database.sqlite"),
        ],
        registry: .ready
    )

    let lines = DoctorRenderer().render(fixture, palette: colorOffPalette)
    let joined = lines.joined(separator: "\n")

    #expect(joined.contains("core.filesystem · core.git"))
    #expect(joined.contains("+3 extras"))
    #expect(joined.contains("core.network") == false)
    #expect(joined.contains("extras off") == false)
}

@Test func doctorRenderer_colorOffHasNoANSIOrBoxDrawing() {
    let output = DoctorRenderer()
        .render(doctorRendererFixture, palette: colorOffPalette)
        .joined(separator: "\n")

    #expect(output.contains("\u{001B}") == false)
    #expect(output.contains("═") == false)
    #expect(output.contains("│") == false)
}
