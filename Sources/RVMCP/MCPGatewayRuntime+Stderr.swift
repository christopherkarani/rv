import Foundation

extension MCPGatewayRuntime {
    /// rv's one stderr writer for `rv mcp`: the runtime's locked `write(2)`
    /// loop, so lines from serve, its upstream relays and its audit fallback
    /// never interleave, a partial or interrupted write is finished, and a
    /// closed stderr fails the write instead of raising. With SIGPIPE at its
    /// default disposition a closed stderr still ends the process, as any
    /// write does.
    public static func writeStderrLine(_ text: String) {
        writeStderr(Data(text.utf8))
    }
}
