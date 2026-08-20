import Foundation
import RVDomain
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
        let launchAgentInstalled = environment.fileManager.fileExists(atPath: paths.launchAgent)
        let config = configState(path: paths.configDirectory, fileManager: environment.fileManager)
        let projection = project(
            diagnostics,
            launchAgentInstalled: launchAgentInstalled,
            launchAgentLoaded: environment.launchAgentLoaded
        )
        let packs = DoctorPacksView(
            enabled: projection.enabledPacks,
            registry: projection.packCheckReady ? .ready : .broken
        )
        return DoctorViewModel(
            service: projection.service,
            packs: packs,
            hosts: SetupHostKind.allCases.map { host in
                DoctorHostView(host: host, state: installations.state(for: host))
            },
            config: config
        )
    }

    private struct DiagnosticProjection {
        var service: DoctorServiceView
        var enabledPacks: [PackID]
        var packCheckReady: Bool
    }

    private static func project(
        _ diagnostics: ServiceDiagnosticResult,
        launchAgentInstalled: Bool,
        launchAgentLoaded: Bool
    ) -> DiagnosticProjection {
        let launchAgent: DoctorLaunchAgentState
        if launchAgentLoaded {
            launchAgent = .loaded
        } else if launchAgentInstalled {
            launchAgent = .installed
        } else {
            launchAgent = .missing
        }
        switch diagnostics {
        case .xpc(let snapshot, let localCorePacksReady):
            let state: DoctorServiceState
            switch snapshot.state {
            case .running, .idleExitArmed:
                state = .running
            case .down:
                state = .down
            case .skew:
                state = .skew
            }
            let packCheckReady = snapshot.checks.first { $0.id == "packs" }?.status == .ok
            return DiagnosticProjection(
                service: DoctorServiceView(
                    state: state,
                    protocolName: snapshot.protocolName,
                    serviceSemver: snapshot.serviceSemver,
                    label: snapshot.label,
                    fallback: localCorePacksReady ? .ready : .unavailable,
                    launchAgent: launchAgent,
                    warning: snapshot.lastError == nil ? nil : "service reported an error"
                ),
                enabledPacks: snapshot.packsEnabled,
                packCheckReady: packCheckReady
            )
        case .local(let diagnostic):
            let state: DoctorServiceState
            let warning: String?
            switch diagnostic.cause {
            case .down:
                state = launchAgentInstalled || launchAgentLoaded ? .down : .notInstalled
                warning = nil
            case .skew(let reason):
                state = .skew
                warning = reason.statusMessage
            case .requestFailed(let failure):
                state = .down
                warning = failure.statusMessage
            }
            return DiagnosticProjection(
                service: DoctorServiceView(
                    state: state,
                    protocolName: ProtocolVersion.name,
                    serviceSemver: diagnostic.serviceSemver,
                    label: SetupRun.launchAgentLabel,
                    fallback: diagnostic.corePacksReady ? .ready : .unavailable,
                    launchAgent: launchAgent,
                    warning: warning
                ),
                enabledPacks: diagnostic.corePacksReady ? dayOnePackIDs : [],
                packCheckReady: diagnostic.corePacksReady
            )
        }
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
