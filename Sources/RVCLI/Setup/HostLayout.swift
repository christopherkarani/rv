import Foundation

struct HostLayout: Equatable, Sendable {
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
    var localRvd: String { home + "/.local/bin/rvd" }
}
