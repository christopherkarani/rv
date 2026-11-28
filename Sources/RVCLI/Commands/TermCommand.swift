#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import ArgumentParser
import Dispatch
import Foundation
import RVDomain
import RVHistory
import RVPolicy
import RVService
import RVTerm
import RVTheme
import Synchronization

/// `rv term`: the full-screen view of what rv is doing (v5c, "the cut").
///
/// Read-only. It reads what rvd and the hook write (the audit log, the
/// local decision log, the pending requests file and the guard mode) and
/// never writes any of them, never talks to rvd, and never answers a
/// request. Glance, Stream and Needs you; keys 1 to 3, space, tab, f, esc,
/// ? and q.
struct Term: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "term",
        abstract: "Watch what rv is doing, full screen."
    )

    @Option(name: .long, help: "Open on glance, stream or needs-you.")
    var view: String?

    @Flag(name: .long, help: "Print one frame and exit (also what a pipe gets).")
    var once = false

    func run() async throws {
        var start = TermView.glance
        if let view {
            guard let named = TermView(deepLinkName: view) else {
                throw ValidationError("rv term: no view named \(view). Try glance, stream or needs-you.")
            }
            start = named
        }
        guard let home = CLIProcess.home() else {
            throw ValidationError("rv term: HOME is not set, so there is no rv folder to read.")
        }
        var sources = TermSources(home: home)
        var state = TermState(now: Date(), mode: sources.mode(), start: start)
        state.pausedUntil = sources.pausedUntil()
        // v5b's Watched lives on as Stream's would-stop filter.
        if view?.lowercased() == "watched" { state.wouldStopsOnly = true }
        sources.refresh(&state)
        let interactive = !once && isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
        let depth = ColorDepth(environment: CLIProcess.environment(), stdoutIsTTY: isatty(STDOUT_FILENO) == 1)
        let palette = TermPaint.Palette(
            depth: depth,
            background: depth == .none
                ? .dark : ThemeProbeFactory.live(jsonFlag: false, robotFlag: false, plainFlag: false, noColorFlag: false).background)
        guard interactive else {
            let size = TermTerminal.size() ?? (columns: 80, rows: 24)
            let frame = TermScreen.render(state, width: size.columns, height: size.rows)
            FileHandle.standardOutput.write(Data(TermPaint.frame(frame, palette: palette, raw: false).utf8))
            return
        }
        try await TermLoop.run(state: state, sources: sources, palette: palette)
    }
}

/// Where rv term's numbers come from, and how far it has read each.
struct TermSources: Sendable {
    let home: HomeDirectory
    let configDirectory: URL
    private var auditCursor = AuditCursor()
    private var decisionCursor: DecisionLogCursor?
    private var sawDecisionLog = false

    init(home: HomeDirectory) {
        self.home = home
        self.configDirectory = RVPolicyPaths.configDirectory(home: home)
    }

    /// Watching while paused, else the stored machine-wide mode.
    func mode(now: Date = Date()) -> TermMode {
        let config = GuardConfig.read(home: home)
        return config.activePause(at: now) != nil || config.machineMode == .observe ? .watching : .guarding
    }

    /// When the owner's `rv pause` ends, while one is open.
    func pausedUntil(now: Date = Date()) -> Date? {
        GuardConfig.read(home: home).activePause(at: now)?.until
    }

    /// Reads whatever is new since the last call into `state`.
    mutating func refresh(_ state: inout TermState) {
        let now = Date()
        state.mode = mode(now: now)
        state.pausedUntil = pausedUntil(now: now)
        let ledger = AuditLedger(configDirectory: configDirectory)
        var audit: [AuditEvent] = []
        while true {
            let (events, next) = ledger.events(after: auditCursor, limit: 5_000)
            auditCursor = next
            audit += events.filter { $0.time >= now.addingTimeInterval(-TermTally.weekWindow) }
            if events.isEmpty { break }
        }
        let log = DecisionLog(configDirectory: configDirectory)
        let read = log.read(after: decisionCursor, now: now)
        decisionCursor = read.cursor
        if !read.records.isEmpty || FileManager.default.fileExists(atPath: log.directory.path) {
            sawDecisionLog = true
        }
        // Decisions first, so a would-stop can mark the command it explains.
        if sawDecisionLog {
            state.absorb(decisions: read.records.filter { $0.time >= now.addingTimeInterval(-TermTally.weekWindow) }, now: now)
        }
        state.absorb(audit: audit, now: now)
        let store = PendingApprovalStore(baseDirectory: configDirectory)
        state.asks = store.awaitingSnapshot(now: now).map { record in
            let item = PendingListProjection.item(from: record)
            return TermAsk(agent: item.host.rawValue, summary: "asks for: \(item.actionKind)", since: record.createdAt,
                           detail: "in \(item.folder)")
        }
    }
}

/// The interactive loop: raw keys in, a full frame out on every key, tick
/// and resize.
enum TermLoop {
    enum Input: Sendable {
        case key(TermKey)
        case tick
        case resize
    }

    static func run(state initial: TermState, sources initialSources: TermSources, palette: TermPaint.Palette) async throws {
        guard TermTerminal.engage() else {
            throw ValidationError("rv term: could not take over this terminal.")
        }
        defer { TermTerminal.restore() }
        var sources = initialSources
        let (inputs, continuation) = AsyncStream.makeStream(of: Input.self)
        TermTerminal.readKeys { continuation.yield(.key($0)) }
        let resize = DispatchSource.makeSignalSource(signal: SIGWINCH, queue: .global())
        signal(SIGWINCH, SIG_IGN)
        resize.setEventHandler { continuation.yield(.resize) }
        resize.resume()
        var stops: [any DispatchSourceSignal] = [resize]
        for number in [SIGTERM, SIGHUP, SIGINT] {
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler {
                TermTerminal.restore()
                exit(0)
            }
            source.resume()
            stops.append(source)
        }
        let ticker = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                continuation.yield(.tick)
            }
        }
        defer {
            ticker.cancel()
            stops.forEach { $0.cancel() }
        }
        var state = initial
        draw(state, palette: palette)
        for await input in inputs {
            switch input {
            case .tick:
                sources.refresh(&state)
            case .resize:
                break
            case .key(.exit):
                return
            case .key(.other):
                continue
            case .key(.input(let key)):
                let width = TermTerminal.size()?.columns ?? 80
                guard state.press(key, width: width) else { return }
            }
            draw(state, palette: palette)
        }
    }

    static func draw(_ state: TermState, palette: TermPaint.Palette) {
        let size = TermTerminal.size() ?? (columns: 80, rows: 24)
        let frame = TermScreen.render(state, width: size.columns, height: size.rows)
        TermTerminal.write("\u{1B}[H" + TermPaint.frame(frame, palette: palette, raw: true))
    }
}

/// A key as rv term reads it.
enum TermKey: Equatable, Sendable {
    case input(TermInput)
    /// Ctrl-C, Ctrl-D, or the end of input: leave now, sheet or not.
    case exit
    case other

    /// Decodes one read's bytes. A lone ESC is Esc; `ESC [ A`...`D` are
    /// the arrows and `ESC [ Z` is Shift-Tab; other escape sequences
    /// (mouse, function keys) are ignored.
    static func decode(_ bytes: [UInt8]) -> [TermKey] {
        guard let first = bytes.first else { return [] }
        if first == 0x1B {
            switch bytes {
            case [0x1B]: return [.input(.navigation(.escape))]
            case [0x1B, 0x5B, 0x41], [0x1B, 0x4F, 0x41]: return [.input(.up)]
            case [0x1B, 0x5B, 0x42], [0x1B, 0x4F, 0x42]: return [.input(.down)]
            case [0x1B, 0x5B, 0x43], [0x1B, 0x4F, 0x43]: return [.input(.right)]
            case [0x1B, 0x5B, 0x44], [0x1B, 0x4F, 0x44]: return [.input(.left)]
            case [0x1B, 0x5B, 0x5A]: return [.input(.navigation(.backTab))]
            default: return [.other]
            }
        }
        return bytes.map { byte in
            switch byte {
            case UInt8(ascii: "1"), UInt8(ascii: "2"), UInt8(ascii: "3"):
                return .input(.navigation(.digit(Int(byte - UInt8(ascii: "0")))))
            case UInt8(ascii: " "): return .input(.navigation(.space))
            case 0x09: return .input(.navigation(.tab))
            case 0x0D, 0x0A: return .input(.enter)
            case UInt8(ascii: "j"): return .input(.down)
            case UInt8(ascii: "k"): return .input(.up)
            case UInt8(ascii: "h"): return .input(.left)
            case UInt8(ascii: "l"): return .input(.right)
            case UInt8(ascii: "f"): return .input(.filter)
            case UInt8(ascii: "?"): return .input(.keys)
            case UInt8(ascii: "G"): return .input(.startGuarding)
            case UInt8(ascii: "a"): return .input(.allow)
            case UInt8(ascii: "d"): return .input(.deny)
            case UInt8(ascii: "q"): return .input(.quit)
            case 0x03, 0x04: return .exit
            default: return .other
            }
        }
    }
}

/// Paints rendered lines as terminal text, in the v5c palette.
enum TermPaint {
    /// The colours for one terminal: its depth and whether it is light or
    /// dark.
    struct Palette: Equatable, Sendable {
        var depth: ColorDepth
        var background: TerminalBackground

        init(depth: ColorDepth, background: TerminalBackground = .dark) {
            self.depth = depth
            self.background = background
        }

        var light: Bool { background == .light }

        /// The mock's page background, which faded text mixes toward.
        var paper: RGB24 { RGB24(hex: light ? 0xFBFBFD : 0x0C0C0F) }

        /// The ink's colour, and the ANSI slot it falls back to at 16
        /// colours (nil: the terminal's own foreground).
        func ink(_ ink: TermInk) -> (rgb: RGB24, ansi16: UInt8?) {
            switch ink {
            case .fg: return (RGB24(hex: light ? 0x1B1B20 : 0xECECF1), nil)
            case .soft: return (RGB24(hex: light ? 0x44444E : 0xB9B9C3), nil)
            case .mute: return (RGB24(hex: light ? 0x6A6A75 : 0x85858F), 8)
            case .ghost: return (RGB24(hex: light ? 0xA2A2AC : 0x50505B), light ? 7 : 8)
            case .hair: return (RGB24(hex: light ? 0xD9D9E0 : 0x2B2B33), light ? 7 : 8)
            case .rv: return (RGB24(hex: light ? 0x5A43DC : 0xB8A9FF), light ? 5 : 13)
            case .stop: return (RGB24(hex: light ? 0xCF222E : 0xFF7A7A), light ? 1 : 9)
            case .watch: return (RGB24(hex: light ? 0x9A6100 : 0xFFCF6B), light ? 3 : 11)
            case .ok: return (RGB24(hex: light ? 0x0E7A50 : 0x6EE7B7), light ? 2 : 10)
            case .go: return (RGB24(hex: light ? 0x0A66C2 : 0x7CC4FF), light ? 4 : 12)
            case .agent: return (RGB24(hex: light ? 0xA3329C : 0xF0A6FF), light ? 6 : 14)
            }
        }

        func fill(_ fill: TermFill) -> RGB24 {
            switch fill {
            case .sel: return RGB24(hex: light ? 0xEBE8FF : 0x1F1D33)
            case .panel: return RGB24(hex: light ? 0xF2F2F6 : 0x131318)
            case .watch: return RGB24(hex: light ? 0xFCF1D8 : 0x362A10)
            case .ok: return RGB24(hex: light ? 0xDFF5EB : 0x0F2F24)
            case .stop: return RGB24(hex: light ? 0xFDE6E7 : 0x3D1619)
            }
        }

        /// The SGR parameters for one span, or none.
        func codes(_ span: TermSpan) -> [String] {
            // No colour (a pipe, NO_COLOR, TERM=dumb) means no escapes at all.
            guard depth != .none else { return [] }
            var codes: [String] = []
            if span.bold { codes.append("1") }
            switch depth {
            case .none:
                break
            case .ansi16:
                let ink = self.ink(span.ink)
                if span.faded {
                    codes.append("2")
                }
                switch span.fill {
                case nil, .panel?:
                    if let slot = ink.ansi16 { codes.append(Self.foreground16(slot)) }
                case .sel?:
                    codes.append("7")
                case .watch?, .ok?, .stop?:
                    if let slot = ink.ansi16 { codes.append(Self.foreground16(slot)) }
                    codes.append("7")
                }
            case .ansi256, .truecolor:
                var color = ink(span.ink).rgb
                var back = span.fill.map(fill)
                if span.faded {
                    color = Self.mix(color, paper, 0.62)
                    back = back.map { Self.mix($0, paper, 0.62) }
                }
                if let code = TerminalInk(rgb: color, ansi16: 7).foreground(depth) { codes.append(code) }
                if let back, let code = TerminalInk(rgb: back, ansi16: 0).background(depth) { codes.append(code) }
            }
            return codes
        }

        static func foreground16(_ slot: UInt8) -> String {
            slot < 8 ? "\(30 + Int(slot))" : "\(90 + Int(slot) - 8)"
        }

        static func mix(_ a: RGB24, _ b: RGB24, _ t: Double) -> RGB24 {
            func channel(_ x: UInt8, _ y: UInt8) -> UInt8 {
                UInt8(max(0, min(255, (Double(x) + (Double(y) - Double(x)) * t).rounded())))
            }
            return RGB24(red: channel(a.red, b.red), green: channel(a.green, b.green), blue: channel(a.blue, b.blue))
        }
    }

    /// The whole frame. `raw` ends lines with CR LF and clears each line's
    /// tail (the terminal is in raw mode and the old frame is underneath).
    static func frame(_ lines: [TermLine], palette: Palette, raw: Bool) -> String {
        var out = ""
        for (index, line) in lines.enumerated() {
            for span in line {
                let codes = palette.codes(span)
                if codes.isEmpty {
                    out += span.text
                } else {
                    out += "\u{1B}[\(codes.joined(separator: ";"))m\(span.text)\u{1B}[0m"
                }
            }
            if raw {
                out += "\u{1B}[K"
                if index < lines.count - 1 { out += "\r\n" }
            } else {
                out += "\n"
            }
        }
        return out
    }
}

/// The terminal rv term takes over: raw mode, the alternate screen, no
/// cursor, and all of it put back on the way out (`restore` is safe to
/// call more than once, from a signal handler's queue too).
enum TermTerminal {
    private struct Saved: @unchecked Sendable {
        var termios: termios
    }

    private static let saved = Mutex<Saved?>(nil)

    static func engage() -> Bool {
        var original = termios()
        guard tcgetattr(STDIN_FILENO, &original) == 0 else { return false }
        var raw = original
        cfmakeraw(&raw)
        guard tcsetattr(STDIN_FILENO, TCSANOW, &raw) == 0 else { return false }
        saved.withLock { $0 = Saved(termios: original) }
        write("\u{1B}[?1049h\u{1B}[?25l\u{1B}[2J")
        return true
    }

    static func restore() {
        guard var taken = saved.withLock({ value -> Saved? in
            defer { value = nil }
            return value
        }) else { return }
        write("\u{1B}[0m\u{1B}[?25h\u{1B}[?1049l")
        _ = tcsetattr(STDIN_FILENO, TCSANOW, &taken.termios)
    }

    static func size() -> (columns: Int, rows: Int)? {
        var window = winsize()
        guard ioctl(STDOUT_FILENO, UInt(TIOCGWINSZ), &window) == 0, window.ws_col > 0, window.ws_row > 0 else {
            return nil
        }
        return (Int(window.ws_col), Int(window.ws_row))
    }

    static func write(_ text: String) {
        let bytes = Array(text.utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return 0 }
                return Foundation.write(STDOUT_FILENO, base + offset, buffer.count - offset)
            }
            if written <= 0 {
                if written < 0, errno == EINTR { continue }
                return
            }
            offset += written
        }
    }

    /// Reads stdin on its own thread, so a blocking read never holds a
    /// Swift concurrency thread.
    static func readKeys(_ deliver: @escaping @Sendable (TermKey) -> Void) {
        let thread = Thread {
            var buffer = [UInt8](repeating: 0, count: 64)
            while true {
                let count = buffer.withUnsafeMutableBytes { read(STDIN_FILENO, $0.baseAddress, $0.count) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else {
                    deliver(.exit)
                    return
                }
                for key in TermKey.decode(Array(buffer[0..<count])) { deliver(key) }
            }
        }
        thread.start()
    }
}
