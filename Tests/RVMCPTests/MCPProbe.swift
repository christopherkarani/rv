#if os(macOS)
import Foundation
import Testing

private struct MissingProbe: Error {}

/// The built `rv-mcp-probe` (Sources/rv-mcp-probe), next to the test bundle
/// or in `.build`.
func mcpProbe() throws -> URL {
    let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    var candidates = [
        root.appendingPathComponent(".build/out/Products/Debug/rv-mcp-probe"),
        root.appendingPathComponent(".build/debug/rv-mcp-probe"),
        root.appendingPathComponent(".build/arm64-apple-macosx/debug/rv-mcp-probe"),
    ]
    var directory = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
    for _ in 0..<8 {
        candidates.append(directory.appendingPathComponent("rv-mcp-probe"))
        let parent = directory.deletingLastPathComponent()
        if parent.path == directory.path { break }
        directory = parent
    }
    if let found = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) { return found }
    Issue.record("missing built product rv-mcp-probe")
    throw MissingProbe()
}
#endif
