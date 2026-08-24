import Foundation
import RVHooks
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
        let stdout: String
        switch appearance {
        case .robot:
            stdout = robotText(model) + "\n"
        case .pretty(let palette):
            stdout = PrettyWriter.join(DoctorRenderer().render(model, palette: palette))
        }
        return DoctorOutcome(
            stdout: stdout,
            stderr: "",
            exitCode: model.isHealthy ? 0 : 1
        )
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
                DoctorHostView(
                    host: host,
                    state: doctorHostState(
                        installations.installation(for: host),
                        fileManager: environment.fileManager
                    )
                )
            },
            config: configState(path: paths.configDirectory, fileManager: environment.fileManager)
        )
    }

    /// Miss path needs sibling `rv-cli`. Missing or non-exec is `.broken`, not `.wired`.
    private static func doctorHostState(
        _ installation: HostAdapterInstallation,
        fileManager: FileManager
    ) -> DoctorHostState {
        switch installation {
        case .wired(let owned, let data):
            guard let text = String(data: data, encoding: .utf8),
                  let adapter = try? HostAdapterResources.load(for: owned.hookHost),
                  let bakedRvPath = adapter.bakedRvPath(in: text),
                  isExecutableRvCli(nextTo: bakedRvPath, fileManager: fileManager)
            else {
                return .broken
            }
            return .wired
        case .missing, .absentFile, .occupied, .broken:
            return installation.state
        }
    }

    private static func isExecutableRvCli(
        nextTo rvPath: String,
        fileManager: FileManager
    ) -> Bool {
        let sibling = (rvPath as NSString).deletingLastPathComponent + "/rv-cli"
        return fileManager.isExecutableFile(atPath: sibling)
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

    private static func robotText(_ model: DoctorViewModel) -> String {
        RobotDocument.doctor(doctorRobotPayload(from: model)).render()
    }
}

extension ServiceHealth {
    var service: DoctorServiceView {
        switch self {
        case .reachable(let facts):
            xpcService(state: .running, facts: facts)
        case .down(let source):
            serviceView(state: .down, source: source, localWarning: nil)
        case .notInstalled(let local):
            localService(state: .notInstalled, local: local, warning: nil)
        case .skew(let reason, let source):
            serviceView(state: .skew, source: source, localWarning: reason?.statusMessage)
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

    private func serviceView(
        state: DoctorServiceState,
        source: Source,
        localWarning: String?
    ) -> DoctorServiceView {
        switch source {
        case .xpc(let facts):
            // XPC snapshots have no typed skew reason; keep the generic lastError warning.
            xpcService(state: state, facts: facts)
        case .local(let local):
            localService(state: state, local: local, warning: localWarning)
        }
    }

    private func xpcService(
        state: DoctorServiceState,
        facts: Reachable
    ) -> DoctorServiceView {
        DoctorServiceView(
            state: state,
            protocolName: facts.snapshot.protocolName,
            serviceSemver: facts.snapshot.serviceSemver,
            label: facts.snapshot.label,
            fallback: facts.localCorePacksReady ? .ready : .unavailable,
            launchAgent: facts.launchAgent,
            warning: launchAgentWarning(facts.launchAgent)
                ?? (facts.snapshot.lastError == nil ? nil : "service reported an error")
        )
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
            warning: launchAgentWarning(local.launchAgent) ?? warning
        )
    }

    private func launchAgentWarning(_ agent: DoctorLaunchAgentState) -> String? {
        agent == .installed ? "LaunchAgent not loaded. Run rv setup." : nil
    }
}
