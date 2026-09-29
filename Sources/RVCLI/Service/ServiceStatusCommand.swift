import RVIPC

public struct ServiceStatusReport: Sendable, Equatable {
    public var state: String
    public var protocolName: String
    public var label: String
    public var fallback: String
    public var keepAlive: Bool
    public var lastError: String?

    public init(
        state: String,
        protocolName: String = ProtocolVersion.name,
        label: String = "dev.rv.evaluate",
        fallback: String,
        keepAlive: Bool = false,
        lastError: String? = nil
    ) {
        self.state = state
        self.protocolName = protocolName
        self.label = label
        self.fallback = fallback
        self.keepAlive = keepAlive
        self.lastError = lastError
    }

    public var plainLines: [String] {
        var lines = [
            "state \(state)",
            "protocol \(protocolName)",
            "label \(label)",
            "fallback \(fallback)",
            "keepAlive \(keepAlive)",
        ]
        if let lastError {
            lines.append("lastError \(lastError)")
        }
        return lines
    }
}

public enum ServiceStatusCommand {
    /// Robot rendering for a status report. The `.serviceStatus` arm is a
    /// pure string join and cannot fail today; `throws` is deliberate
    /// uniformity so every robot render shares one honest path (and one
    /// public error, `RobotRenderError`) instead of trapping.
    public static func robotText(_ report: ServiceStatusReport) throws -> String {
        try RobotDocument.serviceStatus(report).render()
    }

    public static func plainText(_ report: ServiceStatusReport) -> String {
        report.plainLines.joined(separator: "\n")
    }

    static func text(_ report: ServiceStatusReport, appearance: CLIAppearance) throws -> String {
        switch appearance {
        case .robot:
            return try robotText(report)
        case .pretty:
            return plainText(report)
        }
    }
}

extension ServiceHealth {
    var statusReport: ServiceStatusReport {
        switch self {
        case .reachable(let facts):
            ServiceStatusReport(
                state: "running",
                protocolName: facts.snapshot.protocolName,
                label: facts.snapshot.label,
                fallback: "inactive",
                keepAlive: facts.snapshot.keepAlive,
                lastError: facts.snapshot.lastError
            )
        case .down, .notInstalled:
            ServiceStatusReport(state: "down", fallback: "down")
        case .skew(let reason, _):
            ServiceStatusReport(
                state: "skew",
                fallback: "skew",
                lastError: reason?.statusMessage
            )
        case .requestFailed(let failure, _):
            ServiceStatusReport(
                state: "down",
                fallback: "down",
                lastError: failure.statusMessage
            )
        }
    }
}
