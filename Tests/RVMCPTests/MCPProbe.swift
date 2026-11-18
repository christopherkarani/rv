import Foundation
import Testing

private struct MissingProbe: Error {}

/// The built test probe `name` (Sources/<name>), next to the test bundle
/// or in `.build`.
func builtProbe(_ name: String) throws -> URL {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var candidates = [
        root.appendingPathComponent(".build/out/Products/Debug/\(name)"),
        root.appendingPathComponent(".build/debug/\(name)"),
        root.appendingPathComponent(".build/arm64-apple-macosx/debug/\(name)"),
    ]
    var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    for _ in 0..<8 {
        candidates.append(directory.appendingPathComponent(name))
        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path { break }
        directory = parent
    }
    if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) { return found }
    Issue.record("missing built product \(name)")
    throw MissingProbe()
}

#if os(macOS)
/// The built `rv-mcp-probe` (macOS only).
func mcpProbe() throws -> URL {
    try builtProbe("rv-mcp-probe")
}
#endif

/// The built `rv-mcp-signal-probe`, on macOS and Linux.
func mcpSignalProbe() throws -> URL {
    try builtProbe("rv-mcp-signal-probe")
}
