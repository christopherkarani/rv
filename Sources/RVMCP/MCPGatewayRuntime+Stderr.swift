import Foundation

extension MCPGatewayRuntime {
    /// rv's one stderr writer for `rv mcp` (`StderrWriter`, which the sandbox
    /// proxies share): lines from serve, its upstream relays and its audit
    /// fallback never interleave, a partial or interrupted write is
    /// finished, and a closed stderr fails the write, which returns, with
    /// SIGPIPE ignored or at its default.
    public static func writeStderrLine(_ text: String) {
        writeStderr(Data(text.utf8))
    }
}
