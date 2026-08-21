import Darwin
import Foundation
import RVPresentation
import RVTheme
import RVTUI

/// Help surfaces reachable via `rv`, `rv help …`, or `<cmd> --help`.
public enum HelpTopic: Equatable, Sendable {
    case root
    case help
    case test
    case explain
    case service
    case serviceStatus
    case hook
    case setup
    case uninstall
    case doctor
}

/// Intercepts help argv before ArgumentParser so passthrough commands still get help.
public enum HelpDispatch {
    /// When non-`nil`, the process should print that page and exit 0.
    public static func topic(arguments: [String]) -> HelpTopic? {
        if arguments.isEmpty { return .root }

        if arguments[0] == "help" {
            let path = Array(arguments.dropFirst().filter { isHelpFlag($0) == false })
            if path.isEmpty { return .root }
            if path == ["help"] { return .help }
            return topic(path: path) ?? .root
        }

        if let idx = arguments.firstIndex(where: isHelpFlag) {
            let before = Array(arguments[..<idx])
            if before.isEmpty { return .root }
            return topic(path: before)
        }

        return nil
    }

    public static func text(_ topic: HelpTopic, palette: Palette) -> String {
        PrettyWriter.join(HelpRenderer().render(HelpCatalog.page(topic), palette: palette))
    }

    /// Renders help for the live TTY/color probe. Returns `true` when handled.
    public static func tryEmit(
        arguments: [String],
        environment: [String: String] = ProcessInfo.processInfo.environment,
        stdoutIsTTY: Bool? = nil
    ) -> Bool {
        guard let topic = topic(arguments: arguments) else { return false }
        let ttyOut = stdoutIsTTY ?? (isatty(STDOUT_FILENO) != 0)
        let probe = ThemeProbeFactory.make(
            jsonFlag: false,
            robotFlag: false,
            plainFlag: false,
            noColorFlag: false,
            stdinIsTTY: false,
            stdoutIsTTY: ttyOut,
            environment: environment
        )
        let appearance = CLIAppearance.resolve(probe: probe, requested: .automatic)
        let palette: Palette
        switch appearance {
        case .robot:
            palette = colorOffPalette
        case .pretty(let painted):
            palette = painted
        }
        FileHandle.standardOutput.write(Data(text(topic, palette: palette).utf8))
        return true
    }

    private static func topic(path: [String]) -> HelpTopic? {
        guard let head = path.first else { return .root }
        let rest = Array(path.dropFirst())
        switch head {
        case "test":
            return rest.allSatisfy(isTestFlag) ? .test : nil
        case "explain":
            return rest.allSatisfy(isFormatFlag) ? .explain : nil
        case "service":
            if rest.isEmpty { return .service }
            if rest[0] == "status" {
                return rest.dropFirst().allSatisfy(isFormatFlag) ? .serviceStatus : nil
            }
            return rest.allSatisfy(isFormatFlag) ? .service : nil
        case "hook":
            return isHookPath(rest) ? .hook : nil
        case "setup":
            return rest.allSatisfy(isSetupFlag) ? .setup : nil
        case "uninstall":
            return rest.allSatisfy(isFormatFlag) ? .uninstall : nil
        case "doctor":
            return rest.allSatisfy(isFormatFlag) ? .doctor : nil
        case "help":
            return rest.isEmpty ? .help : nil
        default:
            return nil
        }
    }

    private static func isHelpFlag(_ token: String) -> Bool {
        token == "-h" || token == "--help"
    }

    private static func isFormatFlag(_ token: String) -> Bool {
        switch token {
        case "--json", "--robot", "--plain", "--no-color":
            return true
        default:
            return false
        }
    }

    /// `--force` is setup-only; do not treat it as a shared format flag.
    private static func isSetupFlag(_ token: String) -> Bool {
        token == "--force" || isFormatFlag(token)
    }

    private static func isTestFlag(_ token: String) -> Bool {
        token == "--explain" || isFormatFlag(token)
    }

    private static func isHookPath(_ tokens: [String]) -> Bool {
        var i = tokens.startIndex
        while i < tokens.endIndex {
            let token = tokens[i]
            if token == "--host" {
                let valueIndex = tokens.index(after: i)
                guard valueIndex < tokens.endIndex else { return false }
                i = tokens.index(after: valueIndex)
                continue
            }
            if token.hasPrefix("--host=") {
                i = tokens.index(after: i)
                continue
            }
            return false
        }
        return true
    }
}
