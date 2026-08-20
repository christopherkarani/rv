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

    public var robotLines: [String] {
        var lines = [
            "state=\(state)",
            "protocol=\(protocolName)",
            "label=\(label)",
            "fallback=\(fallback)",
            "keepAlive=\(keepAlive)",
        ]
        if let lastError {
            lines.append("lastError=\(lastError)")
        }
        return lines
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
    public static func robotText(_ report: ServiceStatusReport) -> String {
        report.robotLines.joined(separator: "\n")
    }

    public static func plainText(_ report: ServiceStatusReport) -> String {
        report.plainLines.joined(separator: "\n")
    }

    static func text(_ report: ServiceStatusReport, appearance: CLIAppearance) -> String {
        switch appearance {
        case .robot:
            return robotText(report)
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
