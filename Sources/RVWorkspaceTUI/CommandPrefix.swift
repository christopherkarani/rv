import Foundation

/// Keys the workspace shell understands before they are encoded for a runtime.
public indirect enum TUIKey: Equatable, Sendable {
    case character(Character)
    case control(Character)
    case alt(TUIKey)
    case enter
    case backspace
    case tab
    case escape
    case arrow(FocusDirection)
    case home
    case end
    case insert
    case delete
    case pageUp
    case pageDown
    case functionKey(Int)
}

public struct PrefixTarget: Equatable, Sendable {
    public let pane: PaneID
    public let generation: UInt64?

    public init(pane: PaneID, generation: UInt64?) {
        self.pane = pane
        self.generation = generation
    }
}

public enum CommandMode: Equatable, Sendable {
    /// The next key is terminal input.
    case terminal
    /// Ctrl-B was pressed. The next key is an RV command or a cancel.
    /// A nil target is an intentionally empty view: targetless commands
    /// (new tab, navigator, launcher, help, detach) still work while
    /// pane-scoped commands report unavailable.
    case prefix(PrefixTarget?)
    case help
    case launcher
    case runCommand(input: String, error: String?)
    case resize
    case scroll(pane: PaneID)
    case navigator(index: Int)
    case confirmCancel(pane: PaneID)
}

public enum TUICommand: Equatable, Sendable {
    case detach
    case help
    case dismissOverlay
    case launch(RuntimeLaunchChoice)
    case openLauncher
    case split(SplitAxis)
    case focus(FocusDirection)
    case newTab
    case switchTab(Int)
    case closePane
    case toggleZoom
    case sendKey(TUIKey)
    case send(Data)
    case submitRunCommand(String)
    case invalidPrefix
    case enterResize
    case enterScroll
    case enterNavigator
    case enterConfirmCancel
    case resizeStep(axis: SplitAxis, cells: Int)
    case finishResize
    /// Positive lines move away from live output; the reducer clamps to history.
    case scrollDelta(lines: Int)
    case scrollTop
    case scrollBottom
    case exitScroll
    case navigatorMove(delta: Int)
    case navigatorActivate
    case exitNavigator
    case confirmCancel
    case dismissConfirm
    case acquireInput
    case releaseInput
    case relaunchShell
}

/// Arrow-key direction, shared by terminal input and spatial pane focus.
public enum FocusDirection: String, Sendable, Equatable {
    case left
    case right
    case up
    case down
}

/// One offered runtime. The host still performs the launch.
public struct RuntimeLaunchChoice: Equatable, Sendable, Identifiable {
    /// Launcher id of the built-in default shell row.
    public static let shellID = "shell"
    /// Launcher id of the run-prompt row. The unresolved row carries an
    /// empty executable until the typed command resolves to a real one;
    /// dispatch keys off this id, never the executable.
    public static let runPromptID = "run"

    public var id: String
    public var title: String
    public var executable: String
    public var arguments: [String]
    public var hook: String?
    public var resourceProfileID: String?

    public init(
        id: String, title: String, executable: String,
        arguments: [String], hook: String?, resourceProfileID: String? = nil
    ) {
        self.id = id
        self.title = title
        self.executable = executable
        self.arguments = arguments
        self.hook = hook
        self.resourceProfileID = resourceProfileID
    }
}

public enum CommandPrefix {
    private static let bindings: [(key: TUIKey, command: TUICommand)] = [
        (.character("v"), .split(.vertical)),
        (.character("-"), .split(.horizontal)),
        (.character("h"), .focus(.left)),
        (.character("j"), .focus(.down)),
        (.character("k"), .focus(.up)),
        (.character("l"), .focus(.right)),
        (.character("c"), .newTab),
        (.character("n"), .switchTab(1)),
        (.character("p"), .switchTab(-1)),
        (.character("x"), .closePane),
        (.character("z"), .toggleZoom),
        (.character("a"), .openLauncher),
        (.character("q"), .detach),
        (.character("?"), .help),
        (.character("r"), .enterResize),
        (.character("["), .enterScroll),
        (.character("w"), .enterNavigator),
        (.character("!"), .enterConfirmCancel),
    ]

    /// Ctrl-B is the RV prefix. It is never forwarded to the runtime.
    public static func route(
        _ key: TUIKey,
        mode: CommandMode,
        launcher: [RuntimeLaunchChoice],
        directLauncherSelection: Bool = false,
        target: PrefixTarget? = nil
    ) -> (CommandMode, TUICommand?) {
        switch mode {
        case .help:
            return (.terminal, .dismissOverlay)
        case .launcher:
            return routeLauncher(key, launcher: launcher)
        case .runCommand(let input, _):
            switch key {
            case .escape: return (.launcher, .dismissOverlay)
            case .enter: return (.runCommand(input: input, error: nil), .submitRunCommand(input))
            case .backspace:
                return (.runCommand(input: String(input.dropLast()), error: nil), nil)
            case .character(let character):
                return (.runCommand(input: input + String(character), error: nil), nil)
            case .tab:
                return (.runCommand(input: input + "\t", error: nil), nil)
            default: return (.runCommand(input: input, error: nil), nil)
            }
        case .resize:
            return routeResize(key)
        case .scroll(let pane):
            return routeScroll(key, pane: pane)
        case .navigator(let index):
            return routeNavigator(key, index: index)
        case .confirmCancel(let pane):
            return routeConfirmCancel(key, pane: pane)
        case .prefix(let prefixTarget):
            return routePrefix(key, target: prefixTarget)
        case .terminal:
            if directLauncherSelection, case .character(let character) = key {
                if let index = Int(String(character)), index > 0, index <= launcher.count {
                    return (.terminal, .launch(launcher[index - 1]))
                }
            }
            if key == .control("b") { return (.prefix(target), nil) }
            return (.terminal, .sendKey(key))
        }
    }

    /// Fallback page step for scroll mode; the reducer clamps to the live viewport.
    public static let scrollPageLines = 24

    private static func routePrefix(_ key: TUIKey, target: PrefixTarget?) -> (CommandMode, TUICommand?) {
        if key == .escape { return (.terminal, nil) }
        if key == .control("b") { return (.terminal, .send(Data([0x02]))) }
        guard let command = bindings.first(where: { $0.key == key })?.command else {
            return (.terminal, .invalidPrefix)
        }
        switch command {
        case .help: return (.help, command)
        case .enterResize: return (.resize, command)
        case .enterScroll:
            guard let target else { return (.terminal, .invalidPrefix) }
            return (.scroll(pane: target.pane), command)
        case .enterNavigator: return (.navigator(index: 0), command)
        case .enterConfirmCancel:
            guard let target else { return (.terminal, .invalidPrefix) }
            return (.confirmCancel(pane: target.pane), command)
        default: return (.terminal, command)
        }
    }

    private static func routeResize(_ key: TUIKey) -> (CommandMode, TUICommand?) {
        switch key {
        case .character("h"): return (.resize, .resizeStep(axis: .vertical, cells: -1))
        case .character("l"): return (.resize, .resizeStep(axis: .vertical, cells: 1))
        case .character("k"): return (.resize, .resizeStep(axis: .horizontal, cells: -1))
        case .character("j"): return (.resize, .resizeStep(axis: .horizontal, cells: 1))
        case .enter, .escape: return (.terminal, .finishResize)
        default: return (.resize, nil)
        }
    }

    private static func routeScroll(_ key: TUIKey, pane: PaneID) -> (CommandMode, TUICommand?) {
        // Like less/tmux copy mode: j moves toward live output, k away from it.
        let mode = CommandMode.scroll(pane: pane)
        switch key {
        case .character("j"), .arrow(.down): return (mode, .scrollDelta(lines: -1))
        case .character("k"), .arrow(.up): return (mode, .scrollDelta(lines: 1))
        case .pageDown: return (mode, .scrollDelta(lines: -scrollPageLines))
        case .pageUp: return (mode, .scrollDelta(lines: scrollPageLines))
        case .character("g"): return (mode, .scrollTop)
        case .character("G"): return (mode, .scrollBottom)
        case .escape, .character("q"): return (.terminal, .exitScroll)
        default: return (mode, nil)
        }
    }

    private static func routeNavigator(_ key: TUIKey, index: Int) -> (CommandMode, TUICommand?) {
        switch key {
        case .character("j"), .arrow(.down):
            return (.navigator(index: index + 1), .navigatorMove(delta: 1))
        case .character("k"), .arrow(.up):
            return (.navigator(index: index - 1), .navigatorMove(delta: -1))
        case .enter: return (.terminal, .navigatorActivate)
        case .escape, .character("w"): return (.terminal, .exitNavigator)
        default: return (.navigator(index: index), nil)
        }
    }

    private static func routeConfirmCancel(_ key: TUIKey, pane: PaneID) -> (CommandMode, TUICommand?) {
        let mode = CommandMode.confirmCancel(pane: pane)
        switch key {
        case .enter, .character("y"): return (.terminal, .confirmCancel)
        case .escape, .character("n"): return (.terminal, .dismissConfirm)
        default: return (mode, nil)
        }
    }

    private static func routeLauncher(
        _ key: TUIKey,
        launcher: [RuntimeLaunchChoice]
    ) -> (CommandMode, TUICommand?) {
        switch key {
        case .escape:
            return (.terminal, .dismissOverlay)
        case .enter:
            // Enter on a dead pane starts a new default shell; on a live pane
            // the reducer treats this as a plain dismiss.
            return (.terminal, .relaunchShell)
        case .character(let character):
            guard let index = Int(String(character)), index >= 1, index <= launcher.count else {
                return (.terminal, nil)
            }
            let choice = launcher[index - 1]
            return choice.id == RuntimeLaunchChoice.runPromptID
                ? (.runCommand(input: "", error: nil), nil) : (.terminal, .launch(choice))
        default:
            return (.terminal, nil)
        }
    }
}

public enum RunCommandSelection {
    /// A profile is explicit UI metadata, never inferred from the executable.
    /// Example: `profile:docs python3 script.py`.
    public static func splitProfile(_ input: String) -> (profileID: String?, command: String)? {
        guard input.hasPrefix("profile:") else { return (nil, input) }
        let tail = input.dropFirst("profile:".count)
        guard let separator = tail.firstIndex(where: \.isWhitespace) else { return nil }
        let id = String(tail[..<separator])
        guard !id.isEmpty, id.utf8.count <= 64,
              id.utf8.allSatisfy({ byte in
                  (65...90).contains(byte) || (97...122).contains(byte)
                      || (48...57).contains(byte) || byte == 45 || byte == 46 || byte == 95
              }) else { return nil }
        return (id, String(tail[separator...]).trimmingCharacters(in: .whitespaces))
    }
}

public enum TerminalInputEncoder {
    public static func bytes(for key: TUIKey) -> Data {
        switch key {
        case .alt(let modified):
            var encoded = Data([0x1b])
            encoded.append(bytes(for: modified))
            return encoded
        case .character(let character):
            return Data(String(character).utf8)
        case .control(let character):
            return Data([controlByte(character)])
        case .enter:
            return Data([0x0d])
        case .backspace:
            return Data([0x7f])
        case .tab:
            return Data([0x09])
        case .escape:
            return Data([0x1b])
        case .arrow(.up):
            return Data([0x1b, 0x5b, 0x41])
        case .arrow(.down):
            return Data([0x1b, 0x5b, 0x42])
        case .arrow(.right):
            return Data([0x1b, 0x5b, 0x43])
        case .arrow(.left):
            return Data([0x1b, 0x5b, 0x44])
        case .home:
            return Data([0x1b, 0x5b, 0x48])
        case .end:
            return Data([0x1b, 0x5b, 0x46])
        case .insert:
            return Data([0x1b, 0x5b, 0x32, 0x7e])
        case .delete:
            return Data([0x1b, 0x5b, 0x33, 0x7e])
        case .pageUp:
            return Data([0x1b, 0x5b, 0x35, 0x7e])
        case .pageDown:
            return Data([0x1b, 0x5b, 0x36, 0x7e])
        case .functionKey(let number):
            return functionKeyBytes(number)
        }
    }

    private static func functionKeyBytes(_ number: Int) -> Data {
        switch number {
        case 1: Data([0x1b, 0x4f, 0x50])
        case 2: Data([0x1b, 0x4f, 0x51])
        case 3: Data([0x1b, 0x4f, 0x52])
        case 4: Data([0x1b, 0x4f, 0x53])
        case 5: Data("\u{1b}[15~".utf8)
        case 6: Data("\u{1b}[17~".utf8)
        case 7: Data("\u{1b}[18~".utf8)
        case 8: Data("\u{1b}[19~".utf8)
        case 9: Data("\u{1b}[20~".utf8)
        case 10: Data("\u{1b}[21~".utf8)
        case 11: Data("\u{1b}[23~".utf8)
        case 12: Data("\u{1b}[24~".utf8)
        default: Data()
        }
    }

    private static func controlByte(_ character: Character) -> UInt8 {
        guard let ascii = character.asciiValue else { return 0 }
        let upper = ascii >= 97 && ascii <= 122 ? ascii - 32 : ascii
        guard upper >= 64 && upper <= 95 else { return ascii }
        return upper & 0x1f
    }
}
