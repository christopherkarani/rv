import RVPresentation
import RVTheme

/// Vercel-quiet doctor: silver sections, status ink, copy-pasteable Next.
public struct DoctorRenderer: FrameRenderer {
    public static let leadingPad = "  "

    public init() {}

    public func render(_ model: DoctorViewModel, palette: Palette) -> [String] {
        var lines: [String] = []
        lines.append(contentsOf: serviceSection(model.service, palette: palette))
        lines.append("")
        lines.append(contentsOf: hostsSection(model.hosts, palette: palette))
        lines.append("")
        lines.append(contentsOf: packsSection(model.packs, palette: palette))
        lines.append("")
        lines.append(contentsOf: configSection(model, palette: palette))
        if let next = nextSection(model, palette: palette) {
            lines.append("")
            lines.append(contentsOf: next)
        }
        return lines.map { $0.isEmpty ? $0 : Self.leadingPad + $0 }
    }

    private func heading(_ text: String, palette: Palette) -> String {
        paint(text, slot: palette.silver, reset: palette.reset)
    }

    /// Wide enough for `not installed`; keeps meta + detail on one column.
    private static let serviceStateWidth = 13
    private static let serviceGap = "  "

    private func serviceSection(_ service: DoctorServiceView, palette: Palette) -> [String] {
        let mark = serviceMark(service.state)
        let state = padRight(serviceStateText(service.state), to: Self.serviceStateWidth)
        let ink = serviceInk(service.state, palette: palette)
        let gap = Self.serviceGap
        let factIndent = String(
            repeating: " ",
            count: mark.count + gap.count + state.count + gap.count
        )

        var lines = [
            heading("Service", palette: palette),
            "\(paint(mark, slot: ink, reset: palette.reset))\(gap)\(paint(state, slot: palette.fact, reset: palette.reset))\(gap)\(paint(serviceMeta(service), slot: palette.silver, reset: palette.reset))",
            "\(factIndent)\(paint(serviceDetail(service), slot: palette.silver, reset: palette.reset))",
        ]
        if let warning = service.warning, warning.isEmpty == false {
            lines.append("\(factIndent)\(paint(warning, slot: palette.deny, reset: palette.reset))")
        }
        return lines
    }

    private func hostsSection(_ hosts: [DoctorHostView], palette: Palette) -> [String] {
        let nameWidth = hosts.map(\.host.displayName.count).max() ?? 0
        var lines = [heading("Hosts", palette: palette)]
        for host in hosts {
            lines.append(hostRow(host, nameWidth: nameWidth, palette: palette))
        }
        return lines
    }

    private func hostRow(_ host: DoctorHostView, nameWidth: Int, palette: Palette) -> String {
        let good = host.state == .wired
        let mark = good ? "•" : "◦"
        let ink = hostInk(host.state, palette: palette)
        let paintedMark = paint(mark, slot: ink, reset: palette.reset)
        let name = padRight(host.host.displayName, to: nameWidth)
        let status = paint(host.state.rawValue, slot: good ? palette.fact : ink, reset: palette.reset)
        return "\(paintedMark)  \(name)  \(status)"
    }

    private func packsSection(_ packs: DoctorPacksView, palette: Palette) -> [String] {
        var lines = [heading("Packs", palette: palette)]
        switch packs.registry {
        case .broken:
            lines.append("  \(paint("broken", slot: palette.deny, reset: palette.reset))")
        case .ready where packs.areDayOnePacksReady == false:
            let missing = joinedList(packs.missingDayOne.map(\.rawValue).sorted())
            lines.append("  \(paint("missing \(missing)", slot: palette.deny, reset: palette.reset))")
        case .ready:
            // Day-one IDs only — extras scale via count, not a runaway · list.
            let dayOne = packs.dayOneEnabled.map(\.rawValue).joined(separator: " · ")
            lines.append("  \(paint(dayOne, slot: palette.fact, reset: palette.reset))")
            lines.append("  \(paint(extrasLine(packs.extrasEnabled.count), slot: palette.silver, reset: palette.reset))")
        }
        return lines
    }

    private func extrasLine(_ count: Int) -> String {
        switch count {
        case 0:
            "extras off"
        case 1:
            "+1 extra"
        default:
            "+\(count) extras"
        }
    }

    private func configSection(_ model: DoctorViewModel, palette: Palette) -> [String] {
        let configInk = model.config == .readable ? palette.fact : palette.deny
        let body = paint(
            "\(model.config.rawValue) · grade \(model.grade.rawValue)",
            slot: configInk,
            reset: palette.reset
        )
        return [
            heading("Config", palette: palette),
            "  \(body)",
        ]
    }

    private func nextSection(_ model: DoctorViewModel, palette: Palette) -> [String]? {
        guard let action = nextAction(for: model) else { return nil }
        let arrow = paint("→  ", slot: palette.silver, reset: palette.reset)
        return [
            heading("Next", palette: palette),
            "\(arrow)\(action)",
        ]
    }

    /// Occupied is not fixable by plain `rv setup`; `--force` is the one-stop repair.
    private func nextAction(for model: DoctorViewModel) -> String? {
        let fixable = model.hosts.filter { hostNeedsSetup($0.state) }
        let occupied = model.hosts.filter { $0.state == .occupied }
        let fixNames = joinedList(fixable.map(\.host.displayName))
        let occupiedNames = joinedList(occupied.map(\.host.displayName))

        switch (fixable.isEmpty, occupied.isEmpty) {
        case (true, true):
            return nil
        case (false, true):
            return "rv setup    Wire \(fixNames)"
        case (true, false):
            return "rv setup --force    Replace occupied \(occupiedNames)"
        case (false, false):
            return "rv setup --force    Wire \(fixNames); replace occupied \(occupiedNames)"
        }
    }

    private func hostNeedsSetup(_ state: DoctorHostState) -> Bool {
        switch state {
        case .missing, .absentFile, .broken:
            true
        case .wired, .occupied:
            false
        }
    }

    private func serviceStateText(_ state: DoctorServiceState) -> String {
        switch state {
        case .running:
            "running"
        case .down:
            "down"
        case .skew:
            "skew"
        case .notInstalled:
            "not installed"
        }
    }

    private func serviceMark(_ state: DoctorServiceState) -> String {
        state == .running ? "•" : "◦"
    }

    private func serviceInk(_ state: DoctorServiceState, palette: Palette) -> String {
        switch state {
        case .running:
            palette.allow.isEmpty ? palette.heading : palette.allow
        case .down, .skew:
            palette.deny
        case .notInstalled:
            palette.mark
        }
    }

    private func hostInk(_ state: DoctorHostState, palette: Palette) -> String {
        switch state {
        case .wired:
            palette.allow.isEmpty ? palette.heading : palette.allow
        case .occupied, .missing, .absentFile:
            palette.mark
        case .broken:
            palette.deny
        }
    }

    private func serviceMeta(_ service: DoctorServiceView) -> String {
        switch service.state {
        case .running:
            "\(service.serviceSemver ?? "unknown") · \(service.protocolName)"
        case .skew:
            service.serviceSemver.map { "\($0) · \(service.protocolName)" } ?? service.protocolName
        case .down, .notInstalled:
            service.serviceSemver.map { "\($0) · unavailable" } ?? "unavailable"
        }
    }

    private func serviceDetail(_ service: DoctorServiceView) -> String {
        "\(service.label) · launch-agent \(service.launchAgent.rawValue) · fallback \(service.fallback.rawValue)"
    }

    private func joinedList(_ names: [String]) -> String {
        switch names.count {
        case 0:
            return ""
        case 1:
            return names[0]
        case 2:
            return names.joined(separator: " and ")
        default:
            let head = names.dropLast().joined(separator: ", ")
            return "\(head), and \(names[names.count - 1])"
        }
    }
}
