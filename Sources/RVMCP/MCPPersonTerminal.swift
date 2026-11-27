#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import Foundation

/// The terminal `rv mcp serve` runs in, when it has one: a host started in
/// the person's terminal (Claude Code, Codex) leaves serve its controlling
/// terminal, while serve's stdin and stdout are the agent's pipe and its
/// stderr goes to the host's log. A line written here reaches the person's
/// screen and is never read back by the agent through the MCP pipe.
///
/// Best effort, never blocking: no controlling terminal (Cursor, Claude
/// Desktop), a terminal that is not a tty, or a full buffer drops the line;
/// stderr still has it.
public enum MCPPersonTerminal {
    public static let path = "/dev/tty"
    /// A notice longer than this is cut; rv's own lines are far shorter.
    public static let maximumBytes = 1024

    /// The bytes written for one line: on a line of its own, with `\r\n`
    /// so a terminal in raw mode (a TUI) still starts at column 0.
    public static func framed(_ line: String) -> [UInt8] {
        var body: [UInt8] = []
        for scalar in ("◆ rv  " + line).unicodeScalars {
            let bytes = Array(String(scalar).utf8)
            guard body.count + bytes.count <= maximumBytes else { break }
            body += bytes
        }
        return Array("\r\n".utf8) + body + Array("\r\n".utf8)
    }

    /// Writes `line` to the terminal at `path`. False when nothing was
    /// written: no terminal, not a tty, or the write failed or would block.
    @discardableResult
    public static func post(_ line: String, path: String = path) -> Bool {
        // O_NOCTTY: opening a tty here must never make it serve's
        // controlling terminal. O_NONBLOCK: a stopped or flow-controlled
        // terminal never holds up the gateway.
        let fd = open(path, O_WRONLY | O_NOCTTY | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard isatty(fd) == 1 else { return false }
        let bytes = framed(line)
        var offset = 0
        while offset < bytes.count {
            let wrote = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if wrote > 0 {
                offset += wrote
            } else if wrote < 0, errno == EINTR {
                continue
            } else {
                return false
            }
        }
        return true
    }
}
