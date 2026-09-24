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

public enum CommandMode: Equatable, Sendable {
    /// The next key is terminal input.
    case terminal
    /// Ctrl-G was pressed. The next key is an RV command or a cancel.
    case prefix
    case help
    case launcher
}

public enum TUICommand: Equatable, Sendable {
    case splitVertical
    case splitHorizontal
    case focus(FocusDirection)
    case closePane
    case newRuntime
    case detach
    case help
    case dismissOverlay
    case launch(RuntimeLaunchChoice)
    case send(Data)
}

/// One offered runtime. The host still performs the launch.
public struct RuntimeLaunchChoice: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    public var executable: String
    public var arguments: [String]
    public var hook: String?

    public init(id: String, title: String, executable: String, arguments: [String], hook: String?) {
        self.id = id
        self.title = title
        self.executable = executable
        self.arguments = arguments
        self.hook = hook
    }
}

public enum CommandPrefix {
    /// Ctrl-G is the RV prefix. It is never forwarded to the runtime.
    public static func route(
        _ key: TUIKey,
        mode: CommandMode,
        launcher: [RuntimeLaunchChoice]
    ) -> (CommandMode, TUICommand?) {
        switch mode {
        case .help:
            return (.terminal, .dismissOverlay)
        case .launcher:
            return routeLauncher(key, launcher: launcher)
        case .prefix:
            return routePrefix(key)
        case .terminal:
            if case .control(let character) = key, character.lowercased() == "g" { return (.prefix, nil) }
            return (.terminal, .send(TerminalInputEncoder.bytes(for: key)))
        }
    }

    private static func routePrefix(_ key: TUIKey) -> (CommandMode, TUICommand?) {
        guard case .character(let rawCharacter) = key,
              let character = String(rawCharacter).lowercased().first else {
            return (.terminal, nil)
        }
        switch character {
        case "v": return (.terminal, .splitVertical)
        case "s": return (.terminal, .splitHorizontal)
        case "h": return (.terminal, .focus(.left))
        case "j": return (.terminal, .focus(.down))
        case "k": return (.terminal, .focus(.up))
        case "l": return (.terminal, .focus(.right))
        case "x": return (.terminal, .closePane)
        case "n": return (.launcher, .newRuntime)
        case "d": return (.terminal, .detach)
        case "?": return (.help, .help)
        default: return (.terminal, nil)
        }
    }

    private static func routeLauncher(
        _ key: TUIKey,
        launcher: [RuntimeLaunchChoice]
    ) -> (CommandMode, TUICommand?) {
        switch key {
        case .escape:
            return (.terminal, .dismissOverlay)
        case .character(let character):
            guard let index = Int(String(character)), index >= 1, index <= launcher.count else {
                return (.terminal, nil)
            }
            return (.terminal, .launch(launcher[index - 1]))
        default:
            return (.terminal, nil)
        }
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
