import RVDomain
import RVPolicy

struct OwnedHostAdapterPath: Equatable, Sendable {
    var host: HookHost
    var detectionDirectory: String
    var executableName: String
    var destination: String
}

struct OwnedPaths: Equatable, Sendable {
    var home: HomeDirectory

    var configDirectory: String { home.rawValue + "/.config/rv" }
    var grokDirectory: String { home.rawValue + "/.grok" }
    var grokHook: String { home.rawValue + "/.grok/hooks/rv.json" }
    var piDirectory: String { home.rawValue + "/.pi" }
    var piExtension: String { home.rawValue + "/.pi/agent/extensions/rv-guard.ts" }
    var openCodeDirectory: String { home.rawValue + "/.config/opencode" }
    var openCodePlugin: String { home.rawValue + "/.config/opencode/plugins/rv-guard.js" }
    var openCodeTuiPlugin: String { home.rawValue + "/.config/opencode/plugins/rv-guard-tui.js" }
    var openCodeTuiAskPackage: String { home.rawValue + "/.config/opencode/rv-guard-tui-ask" }
    var openCodeConfig: String { home.rawValue + "/.config/opencode/opencode.json" }
    var openCodeTuiConfig: String { home.rawValue + "/.config/opencode/tui.json" }
    var claudeDirectory: String { home.rawValue + "/.claude" }
    var claudeSettings: String { home.rawValue + "/.claude/settings.json" }
    var openClawDirectory: String { home.rawValue + "/.openclaw" }
    var openClawPlugin: String { home.rawValue + "/.openclaw/extensions/rv-guard/index.js" }
    var hermesDirectory: String { home.rawValue + "/.hermes" }
    var hermesPlugin: String { home.rawValue + "/.hermes/plugins/rv-guard/__init__.py" }
    var launchAgent: String { home.rawValue + "/Library/LaunchAgents/dev.rv.evaluate.plist" }
    var systemdUserUnit: String { home.rawValue + "/.config/systemd/user/dev.rv.evaluate.service" }
    var localRv: String { home.rawValue + "/.local/bin/rv" }
    var localRvCli: String { home.rawValue + "/.local/bin/rv-cli" }
    var localRvd: String { home.rawValue + "/.local/bin/rvd" }

    var hostAdapters: [OwnedHostAdapterPath] {
        HookHost.setupSlotOrder.map(hostAdapter)
    }

    func hostAdapter(for host: HookHost) -> OwnedHostAdapterPath {
        switch host {
        case .grok:
            OwnedHostAdapterPath(
                host: .grok,
                detectionDirectory: grokDirectory,
                executableName: "grok",
                destination: grokHook
            )
        case .pi:
            OwnedHostAdapterPath(
                host: .pi,
                detectionDirectory: piDirectory,
                executableName: "pi",
                destination: piExtension
            )
        case .opencode:
            OwnedHostAdapterPath(
                host: .opencode,
                detectionDirectory: openCodeDirectory,
                executableName: "opencode",
                destination: openCodePlugin
            )
        case .claude:
            OwnedHostAdapterPath(
                host: .claude,
                detectionDirectory: claudeDirectory,
                executableName: "claude",
                destination: claudeSettings
            )
        case .openclaw:
            OwnedHostAdapterPath(
                host: .openclaw,
                detectionDirectory: openClawDirectory,
                executableName: "openclaw",
                destination: openClawPlugin
            )
        case .hermes:
            OwnedHostAdapterPath(
                host: .hermes,
                detectionDirectory: hermesDirectory,
                executableName: "hermes",
                destination: hermesPlugin
            )
        }
    }
}
