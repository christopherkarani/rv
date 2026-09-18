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
        "    readable · grade hook · safety normal · block ledger on",
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

@Test func doctorRenderer_wiredFileToolsShowsFileToolSuffix() {
    var fixture = doctorRendererFixture
    fixture.hosts = [
        DoctorHostView(host: .grok, state: .wired, fileTools: .wired),
        DoctorHostView(host: .cursor, state: .wired, fileTools: .shellOnly),
        DoctorHostView(host: .pi, state: .wired),
    ]

    let lines = DoctorRenderer().render(fixture, palette: colorOffPalette)
    let joined = lines.joined(separator: "\n")

    #expect(joined.contains("Grok") && joined.contains("wired · file-tool"))
    #expect(joined.contains("Cursor") && joined.contains("wired · shell-only"))
    #expect(joined.contains("Pi") && joined.contains("wired"))
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
    #expect(joined.contains("disabled ") == false)
}

@Test func doctorRenderer_disabledDayOneAsksPacksEnableNotSetup() {
    var fixture = doctorRendererFixture
    fixture.packs = DoctorPacksView(enabled: [.coreFilesystem, .systemDisk], registry: .ready)
    fixture.hosts = HookHost.setupSlotOrder.map {
        DoctorHostView(host: $0, state: .wired)
    }

    let lines = DoctorRenderer().render(fixture, palette: colorOffPalette)
    let joined = lines.joined(separator: "\n")

    #expect(joined.contains("disabled core.git"))
    #expect(joined.contains("missing ") == false)
    #expect(joined.contains("→  rv packs enable core.git"))
    #expect(joined.contains("rv setup") == false)
}

@Test func doctorRenderer_disabledDayOneListsPacksEnableBeforeOccupiedSetup() throws {
    var fixture = doctorRendererFixture
    fixture.packs = DoctorPacksView(enabled: [.coreFilesystem, .systemDisk], registry: .ready)
    fixture.hosts = [
        DoctorHostView(host: .grok, state: .wired),
        DoctorHostView(host: .pi, state: .occupied),
        DoctorHostView(host: .opencode, state: .wired),
        DoctorHostView(host: .claude, state: .wired),
    ]

    let lines = DoctorRenderer().render(fixture, palette: colorOffPalette)
    let joined = lines.joined(separator: "\n")
    let enable = try #require(joined.range(of: "→  rv packs enable core.git"))
    let force = try #require(joined.range(of: "→  rv setup --force    Replace occupied Pi"))

    #expect(enable.lowerBound < force.lowerBound)
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

@Test func doctorRenderer_emptyHostsAndServiceMetaFallbacks() {
    var empty = doctorRendererFixture
    empty.hosts = []
    let emptyText = DoctorRenderer().render(empty, palette: colorOffPalette).joined(separator: "\n")
    #expect(emptyText.contains("Hosts"))

    var runningUnknown = doctorRendererFixture
    runningUnknown.service.serviceSemver = nil
    #expect(
        DoctorRenderer().render(runningUnknown, palette: colorOffPalette)
            .joined(separator: "\n")
            .contains("unknown · rv.ipc.v1")
    )

    var skewBare = doctorRendererFixture
    skewBare.service.state = .skew
    skewBare.service.serviceSemver = nil
    #expect(
        DoctorRenderer().render(skewBare, palette: colorOffPalette)
            .joined(separator: "\n")
            .contains("rv.ipc.v1")
    )

    var downVersioned = doctorRendererFixture
    downVersioned.service.state = .down
    downVersioned.service.serviceSemver = "1.2.3"
    #expect(
        DoctorRenderer().render(downVersioned, palette: colorOffPalette)
            .joined(separator: "\n")
            .contains("1.2.3 · unavailable")
    )
}

@Test func doctorRenderer_serviceStatesAndWarning() {
    var down = doctorRendererFixture
    down.service.state = .down
    down.service.serviceSemver = nil
    down.service.warning = "peer closed"
    let downText = DoctorRenderer().render(down, palette: colorOffPalette).joined(separator: "\n")
    #expect(downText.contains("down"))
    #expect(downText.contains("unavailable"))
    #expect(downText.contains("peer closed"))

    var skew = doctorRendererFixture
    skew.service.state = .skew
    skew.service.serviceSemver = "0.9.0"
    skew.service.warning = ""
    let skewText = DoctorRenderer().render(skew, palette: colorOffPalette).joined(separator: "\n")
    #expect(skewText.contains("0.9.0 · rv.ipc.v1"))
    #expect(skewText.contains("peer closed") == false)
}

@Test func doctorRenderer_missingDayOneAndSingleExtra() {
    var missing = doctorRendererFixture
    missing.packs = DoctorPacksView(enabled: [.coreGit], registry: .ready)
    #expect(
        DoctorRenderer().render(missing, palette: colorOffPalette)
            .joined(separator: "\n")
            .contains("disabled core.filesystem and system.disk")
    )

    var extra = doctorRendererFixture
    extra.packs = DoctorPacksView(
        enabled: dayOnePackIDs + [PackID(rawValue: "core.network")],
        registry: .ready
    )
    #expect(
        DoctorRenderer().render(extra, palette: colorOffPalette)
            .joined(separator: "\n")
            .contains("+1 extra")
    )
}

@Test func doctorRenderer_nextActionsCoverHostSets() {
    var healthy = doctorRendererFixture
    healthy.hosts = HookHost.setupSlotOrder.map { DoctorHostView(host: $0, state: .wired) }
    let healthyLines = DoctorRenderer().render(healthy, palette: colorOffPalette)
    #expect(healthyLines.contains { $0.contains("Next") } == false)

    var one = doctorRendererFixture
    one.hosts = [DoctorHostView(host: .pi, state: .missing)]
    #expect(
        DoctorRenderer().render(one, palette: colorOffPalette)
            .joined(separator: "\n")
            .contains("rv setup    Wire Pi")
    )

    var mixed = doctorRendererFixture
    mixed.hosts = [
        DoctorHostView(host: .pi, state: .missing),
        DoctorHostView(host: .claude, state: .occupied),
        DoctorHostView(host: .grok, state: .broken),
    ]
    let mixedText = DoctorRenderer().render(mixed, palette: colorOffPalette).joined(separator: "\n")
    #expect(mixedText.contains("rv setup --force    Wire Pi and Grok; replace occupied Claude"))
    #expect(mixedText.contains("broken"))
}

@Test func doctorRenderer_colorOn_usesAllowFallbackAndConfigInk() {
    var fixture = doctorRendererFixture
    fixture.config = .unreadable
    fixture.blocksEnabled = false
    let palette = Palette(for: ColorCapability(colorsEnabled: true))
    let lines = DoctorRenderer().render(fixture, palette: palette)
    #expect(lines.contains { $0.contains(palette.allow) })
    #expect(lines.contains { $0.contains(palette.deny) && $0.contains("unreadable") })
    #expect(lines.contains { $0.contains("block ledger off") })
}

@Test func doctorRenderer_colorOffHasNoANSIOrBoxDrawing() {
    let output = DoctorRenderer()
        .render(doctorRendererFixture, palette: colorOffPalette)
        .joined(separator: "\n")

    #expect(output.contains("\u{001B}") == false)
    #expect(output.contains("═") == false)
    #expect(output.contains("│") == false)
}
