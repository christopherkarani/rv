import RVPresentation
import RVTheme

/// Renders doctor health as one plain-text fact per line.
public struct DoctorRenderer: FrameRenderer {
    /// Creates a doctor renderer.
    public init() {}

    /// Renders the supplied doctor model without terminal chrome.
    public func render(_ model: DoctorViewModel, palette _: Palette) -> [String] {
        var lines = [
            "service: \(serviceStateText(model.service.state))",
            "protocol: \(model.service.protocolName)",
            "service-version: \(serviceVersionText(model.service))",
            "service-label: \(model.service.label)",
            "fallback: \(model.service.fallback.rawValue)",
            "launch-agent: \(model.service.launchAgent.rawValue)",
            packsLine(model.packs),
        ]
        if let warning = model.service.warning {
            lines.append("service-warning: \(warning)")
        }
        lines.append(contentsOf: model.hosts.map(hostLine))
        lines.append("config: \(model.config.rawValue)")
        lines.append("grade: \(model.grade.rawValue)")
        return lines
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

    private func serviceVersionText(_ service: DoctorServiceView) -> String {
        switch service.state {
        case .running:
            "\(service.serviceSemver ?? "unknown") (compatible)"
        case .skew:
            service.serviceSemver.map { "\($0) (skew)" } ?? "skew"
        case .down, .notInstalled:
            service.serviceSemver.map { "\($0) (unavailable)" } ?? "unavailable"
        }
    }

    private func packsLine(_ packs: DoctorPacksView) -> String {
        guard packs.registry == .ready else {
            return "packs: broken"
        }
        if packs.areDayOnePacksReady {
            let enabled = joinedIDs(packs.enabled.map(\.rawValue))
            let extras = packs.extrasEnabled.isEmpty
                ? "extras off"
                : "extras \(joinedIDs(packs.extrasEnabled.map(\.rawValue))) enabled"
            return "packs: \(enabled) enabled; \(extras)"
        }
        return "packs: missing \(joinedIDs(packs.missingDayOne.map(\.rawValue)))"
    }

    private func joinedIDs(_ ids: [String]) -> String {
        let values = ids.sorted()
        if values.count == 2 {
            return values.joined(separator: " and ")
        }
        return values.joined(separator: ", ")
    }

    private func hostLine(_ host: DoctorHostView) -> String {
        let action = host.state == .wired ? "" : " — run rv setup"
        return "host \(host.host.displayName): \(host.state.rawValue)\(action)"
    }
}
