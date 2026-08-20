import Foundation
import RVIPC
import RVPresentation
import RVTUI

struct DoctorEnvironment {
    var home: String
    var pathEntries: [String]
    var fileManager: FileManager
    var launchAgentLoaded: Bool

    static func live(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> DoctorEnvironment? {
        guard let home = environment["HOME"], home.isEmpty == false else { return nil }
        return DoctorEnvironment(
            home: home,
            pathEntries: (environment["PATH"] ?? "").split(separator: ":").map(String.init),
            fileManager: .default,
            launchAgentLoaded: LaunchAgentProbe.isLoaded(label: SetupRun.launchAgentLabel)
        )
    }
}

struct DoctorOutcome: Equatable, Sendable {
    var stdout: String
    var stderr: String
    var exitCode: Int32
}

enum DoctorRun {
    static func run(
        environment: DoctorEnvironment,
        diagnostics: ServiceDiagnosticResult,
        appearance: CLIAppearance
    ) -> DoctorOutcome {
        let model: DoctorViewModel
        do {
            model = try inspect(environment: environment, diagnostics: diagnostics)
        } catch {
            return DoctorOutcome(
                stdout: "",
                stderr: "rv doctor failed: unable to inspect Host adapters\n",
                exitCode: 1
            )
        }
        do {
            let stdout: String
            switch appearance {
            case .robot:
                stdout = try robotText(model) + "\n"
            case .pretty(let palette):
                stdout = PrettyWriter.join(DoctorRenderer().render(model, palette: palette))
            }
            return DoctorOutcome(
                stdout: stdout,
                stderr: "",
                exitCode: model.isHealthy ? 0 : 1
            )
        } catch {
            return DoctorOutcome(
                stdout: "",
                stderr: "rv doctor failed\n",
                exitCode: 1
            )
        }
    }

    private static func inspect(
        environment: DoctorEnvironment,
        diagnostics: ServiceDiagnosticResult
    ) throws -> DoctorViewModel {
        let paths = OwnedPaths(home: environment.home)
        let installations = try HostAdapterInstallation.inspect(
            paths: paths,
            pathEntries: environment.pathEntries,
            fileManager: environment.fileManager
        )
        let health = ServiceHealth.inspect(
            diagnostics,
            launchAgentInstalled: environment.fileManager.fileExists(atPath: paths.launchAgent),
            launchAgentLoaded: environment.launchAgentLoaded
        )
        return DoctorViewModel(
            service: health.service,
            packs: health.packs,
            hosts: SetupHostKind.allCases.map { host in
                DoctorHostView(host: host, state: installations.state(for: host))
            },
            config: configState(path: paths.configDirectory, fileManager: environment.fileManager)
        )
    }

    private static func configState(
        path: String,
        fileManager: FileManager
    ) -> DoctorConfigState {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .readable
        }
        guard isDirectory.boolValue, fileManager.isReadableFile(atPath: path) else {
            return .unreadable
        }
        return .readable
    }

    private static func robotText(_ model: DoctorViewModel) throws -> String {
        let robot = DoctorRobot(
            schema: "rv.doctor.v1",
            service: DoctorRobot.Service(
                state: model.service.state.rawValue,
                protocolName: model.service.protocolName,
                serviceSemver: model.service.serviceSemver,
                fallbackReady: model.service.fallback == .ready,
                launchAgent: model.service.launchAgent.rawValue,
                warning: model.service.warning
            ),
            packs: DoctorRobot.Packs(
                registry: model.packs.registry.rawValue,
                dayOneReady: model.packs.areDayOnePacksReady,
                enabled: model.packs.enabled.map(\.rawValue),
                extrasEnabled: model.packs.extrasEnabled.map(\.rawValue)
            ),
            hosts: Dictionary(
                uniqueKeysWithValues: model.hosts.map { ($0.host.robotName, $0.state.rawValue) }
            ),
            config: model.config.rawValue,
            grade: model.grade.rawValue,
            ok: model.isHealthy
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(robot), as: UTF8.self)
    }
}

private struct DoctorRobot: Encodable {
    struct Service: Encodable {
        var state: String
        var protocolName: String
        var serviceSemver: String?
        var fallbackReady: Bool
        var launchAgent: String
        var warning: String?

        enum CodingKeys: String, CodingKey {
            case state
            case protocolName = "protocol"
            case serviceSemver = "service_semver"
            case fallbackReady = "fallback_ready"
            case launchAgent = "launch_agent"
            case warning
        }
    }

    struct Packs: Encodable {
        var registry: String
        var dayOneReady: Bool
        var enabled: [String]
        var extrasEnabled: [String]

        enum CodingKeys: String, CodingKey {
            case registry
            case dayOneReady = "day_one_ready"
            case enabled
            case extrasEnabled = "extras_enabled"
        }
    }

    var schema: String
    var service: Service
    var packs: Packs
    var hosts: [String: String]
    var config: String
    var grade: String
    var ok: Bool
}

private extension SetupHostKind {
    var robotName: String {
        switch self {
        case .grok:
            "grok"
        case .pi:
            "pi"
        case .openCode:
            "opencode"
        }
    }
}

extension ServiceHealth {
    var service: DoctorServiceView {
        switch self {
        case .reachable(let facts):
            DoctorServiceView(
                state: serviceState(facts.snapshot.state),
                protocolName: facts.snapshot.protocolName,
                serviceSemver: facts.snapshot.serviceSemver,
                label: facts.snapshot.label,
                fallback: facts.localCorePacksReady ? .ready : .unavailable,
                launchAgent: facts.launchAgent,
                warning: facts.snapshot.lastError == nil ? nil : "service reported an error"
            )
        case .down(let local):
            localService(state: .down, local: local, warning: nil)
        case .notInstalled(let local):
            localService(state: .notInstalled, local: local, warning: nil)
        case .skew(let reason, let local):
            localService(state: .skew, local: local, warning: reason.statusMessage)
        case .requestFailed(let failure, let local):
            localService(state: .down, local: local, warning: failure.statusMessage)
        }
    }

    var packs: DoctorPacksView {
        DoctorPacksView(
            enabled: enabledPacks,
            registry: packCheckReady ? .ready : .broken
        )
    }

    private func serviceState(_ state: ServiceState) -> DoctorServiceState {
        switch state {
        case .running, .idleExitArmed:
            .running
        case .down:
            .down
        case .skew:
            .skew
        }
    }

    private func localService(
        state: DoctorServiceState,
        local: Local,
        warning: String?
    ) -> DoctorServiceView {
        DoctorServiceView(
            state: state,
            protocolName: ProtocolVersion.name,
            serviceSemver: local.serviceSemver,
            label: SetupRun.launchAgentLabel,
            fallback: local.corePacksReady ? .ready : .unavailable,
            launchAgent: local.launchAgent,
            warning: warning
        )
    }
}
