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
        sources.refresh(&state)
        let interactive = !once && isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1
        let depth = ColorDepth(environment: CLIProcess.environment(), stdoutIsTTY: isatty(STDOUT_FILENO) == 1)
        guard interactive else {
            let size = TermTerminal.size() ?? (columns: 80, rows: 24)
            let frame = TermScreen.render(state, width: size.columns, height: size.rows)
            FileHandle.standardOutput.write(Data(TermPaint.frame(frame, depth: depth, raw: false).utf8))
            return
        }
        try await TermLoop.run(state: state, sources: sources, depth: depth)
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

    func mode() -> TermMode {
        GuardConfig.read(home: home).machineMode == .observe ? .watching : .guarding
    }

    /// Reads whatever is new since the last call into `state`.
    mutating func refresh(_ state: inout TermState) {
        let now = Date()
        state.mode = mode()
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
            return TermAsk(agent: item.host.rawValue, summary: "\(item.actionKind) in \(item.folder)", since: record.createdAt)
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

    static func run(state initial: TermState, sources initialSources: TermSources, depth: ColorDepth) async throws {
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
        draw(state, depth: depth)
        for await input in inputs {
            switch input {
            case .tick:
                sources.refresh(&state)
            case .resize:
                break
            case .key(let key):
                switch key {
                case .quit:
                    return
                case .navigation(let navigation):
                    if state.showingKeys, navigation == .escape {
                        state.showingKeys = false
                    } else if !state.navigation.handle(navigation), navigation == .escape {
                        return
                    }
                case .filter:
                    if state.navigation.current != .stream { state.navigation.open(.stream) }
                    state.wouldStopsOnly.toggle()
                case .keys:
                    state.showingKeys.toggle()
                case .other:
                    continue
                }
            }
            draw(state, depth: depth)
        }
    }

    static func draw(_ state: TermState, depth: ColorDepth) {
        let size = TermTerminal.size() ?? (columns: 80, rows: 24)
        let frame = TermScreen.render(state, width: size.columns, height: size.rows)
        TermTerminal.write("\u{1B}[H" + TermPaint.frame(frame, depth: depth, raw: true))
    }
}

/// A key rv term understands.
enum TermKey: Equatable, Sendable {
    case navigation(TermNavigationKey)
    case filter
    case keys
    case quit
    case other

    /// Decodes one read's bytes. A lone ESC is Esc; `ESC [ Z` is Shift-Tab;
    /// other escape sequences (arrows, mouse) are ignored.
    static func decode(_ bytes: [UInt8]) -> [TermKey] {
        guard let first = bytes.first else { return [] }
        if first == 0x1B {
            if bytes.count == 1 { return [.navigation(.escape)] }
            if bytes == [0x1B, 0x5B, 0x5A] { return [.navigation(.backTab)] }
            return [.other]
        }
        return bytes.map { byte in
            switch byte {
            case UInt8(ascii: "1"), UInt8(ascii: "2"), UInt8(ascii: "3"):
                return .navigation(.digit(Int(byte - UInt8(ascii: "0"))))
            case UInt8(ascii: " "): return .navigation(.space)
            case 0x09: return .navigation(.tab)
            case UInt8(ascii: "f"): return .filter
            case UInt8(ascii: "?"): return .keys
            case UInt8(ascii: "q"), 0x03, 0x04: return .quit
            default: return .other
            }
        }
    }
}

/// Paints rendered lines as terminal text.
enum TermPaint {
    static func ink(_ ink: TermInk) -> (sgr: String?, color: TerminalInk?) {
        switch ink {
        case .plain: return (nil, nil)
        case .soft: return (nil, nil)
        case .dim: return ("2", nil)
        case .strong: return ("1", nil)
        case .ok: return (nil, TerminalInk(rgb: RGB24(hex: 0x30D158), ansi16: 2))
        case .watch: return (nil, TerminalInk(rgb: RGB24(hex: 0xFF9F0A), ansi16: 3))
        case .stop: return (nil, TerminalInk(rgb: RGB24(hex: 0xFF453A), ansi16: 1))
        case .agent: return (nil, TerminalInk(rgb: RGB24(hex: 0x64A8FF), ansi16: 4))
        case .accent: return ("1", TerminalInk(rgb: RGB24(hex: 0xBF5AF2), ansi16: 5))
        }
    }

    /// The whole frame. `raw` ends lines with CR LF and clears each line's
    /// tail (the terminal is in raw mode and the old frame is underneath).
    static func frame(_ lines: [TermLine], depth: ColorDepth, raw: Bool) -> String {
        var out = ""
        for (index, line) in lines.enumerated() {
            for span in line {
                let painted = ink(span.ink)
                var codes: [String] = []
                if depth != .none {
                    if let sgr = painted.sgr { codes.append(sgr) }
                    if let color = painted.color?.foreground(depth) { codes.append(color) }
                }
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
                    deliver(.quit)
                    return
                }
                for key in TermKey.decode(Array(buffer[0..<count])) { deliver(key) }
            }
        }
        thread.start()
    }
}
