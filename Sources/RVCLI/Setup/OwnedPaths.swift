import RVDomain
import RVPresentation

struct OwnedHostAdapterPath: Equatable, Sendable {
    var host: SetupHostKind
    var hookHost: HookHost
    var detectionDirectory: String
    var executableName: String
    var destination: String
}

struct OwnedPaths: Equatable, Sendable {
    var home: String

    var configDirectory: String { home + "/.config/rv" }
    var grokDirectory: String { home + "/.grok" }
    var grokHook: String { home + "/.grok/hooks/rv.json" }
    var piDirectory: String { home + "/.pi" }
    var piExtension: String { home + "/.pi/agent/extensions/rv-guard.ts" }
    var openCodeDirectory: String { home + "/.config/opencode" }
    var openCodePlugin: String { home + "/.config/opencode/plugins/rv-guard.js" }
    var launchAgent: String { home + "/Library/LaunchAgents/dev.rv.evaluate.plist" }
    var localRv: String { home + "/.local/bin/rv" }
    var localRvCli: String { home + "/.local/bin/rv-cli" }
    var localRvd: String { home + "/.local/bin/rvd" }

    var hostAdapters: [OwnedHostAdapterPath] {
        SetupHostKind.allCases.map(hostAdapter)
    }

    func hostAdapter(for host: SetupHostKind) -> OwnedHostAdapterPath {
        switch host {
        case .grok:
            OwnedHostAdapterPath(
                host: .grok,
                hookHost: .grok,
                detectionDirectory: grokDirectory,
                executableName: "grok",
                destination: grokHook
            )
        case .pi:
            OwnedHostAdapterPath(
                host: .pi,
                hookHost: .pi,
                detectionDirectory: piDirectory,
                executableName: "pi",
                destination: piExtension
            )
        case .openCode:
            OwnedHostAdapterPath(
                host: .openCode,
                hookHost: .opencode,
                detectionDirectory: openCodeDirectory,
                executableName: "opencode",
                destination: openCodePlugin
            )
        }
    }
}
