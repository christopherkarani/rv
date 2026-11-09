import Foundation
import Testing

@testable import RVIsolation

/// The workspace control paths exist in two packages: RVIsolation (the
/// Seatbelt profile and the micro-VM placeholders) and
/// `Packages/rv-microvm` (the guest mounts), which does not import
/// RVIsolation. Drift between them leaves a path a micro-VM guest can
/// plant and a host tool later runs. These tests read the guest package's
/// lists from source and require them to match.
@Suite("Workspace control path parity")
struct WorkspaceControlParityTests {
    private static let mountsSource = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("Packages/rv-microvm/Sources/RVMicroVMCore/WorkspaceControlMounts.swift")

    /// The string literals of `static let <name> = [ ... ]` in the guest package.
    private func guestList(_ name: String) throws -> [String] {
        let source = try String(contentsOf: Self.mountsSource, encoding: .utf8)
        guard let values = Self.listLiterals(name, in: source) else {
            Issue.record("WorkspaceControlLayout.\(name) not found in \(Self.mountsSource.path)")
            return []
        }
        return values
    }

    /// The string literals of `static let <name> = [ ... ]` in `source`,
    /// ignoring `//` line comments (no list entry contains `//`).
    static func listLiterals(_ name: String, in source: String) -> [String]? {
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { line[..<$0.lowerBound] } ?? line }
            .joined(separator: "\n")
        guard let start = code.range(of: "static let \(name) = [") else { return nil }
        guard let end = code[start.upperBound...].firstIndex(of: "]") else { return [] }
        var values: [String] = []
        var rest = code[start.upperBound..<end]
        while let open = rest.firstIndex(of: "\"") {
            let after = rest.index(after: open)
            guard let close = rest[after...].firstIndex(of: "\"") else { break }
            values.append(String(rest[after..<close]))
            rest = rest[rest.index(after: close)...]
        }
        return values
    }

    @Test("the list parser ignores commented-out entries")
    func parserIgnoresComments() {
        let source = """
            // static let files = ["decoy"]
            static let files = [
                ".mcp.json", // trailing note "x"
                // ".envrc",
                "opencode.json",
            ]
            """
        #expect(Self.listLiterals("files", in: source) == [".mcp.json", "opencode.json"])
        #expect(Self.listLiterals("missing", in: source) == nil)
    }

    @Test("guest run-later lists match the Seatbelt profile's")
    func runLater() throws {
        #expect(try guestList("runLaterFiles") == WorkspaceRunLaterPaths.files)
        #expect(try guestList("runLaterTrees") == WorkspaceRunLaterPaths.trees)
        #expect(try guestList("runLaterPinnedDirectories") == WorkspaceRunLaterPaths.pinnedDirectories)
    }

    @Test("guest rv and git control lists match the placeholders'")
    func control() throws {
        #expect(try guestList("controlFiles") == MicroVMControlLayout.controlFiles)
        #expect(try guestList("controlTrees") == MicroVMControlLayout.controlTrees)
        #expect(try guestList("controlPinnedDirectories") == MicroVMControlLayout.controlPinnedDirectories)
    }

    @Test("every rv and git control path is in the Seatbelt control denies")
    func controlInSeatbelt() {
        let denies = workspaceControlDenies(workspacePath: "/w")
        for path in MicroVMControlLayout.controlFiles + MicroVMControlLayout.controlTrees
            + MicroVMControlLayout.controlPinnedDirectories {
            #expect(denies.contains("\"/w/\(path)\""), "\(path) is not denied by the Seatbelt profile")
        }
    }

    @Test("the placeholder tree pins every agent config directory with its protected children")
    func tree() {
        let roots = MicroVMControlLayout.roots
        #expect(roots.map(\.name) == [
            ".git", ".rv", ".config", ".claude", ".codex", ".cursor", ".gemini", ".vscode",
            ".mcp.json", "opencode.json", "opencode.jsonc", ".envrc",
        ])
        // Same child order as the guest's mounts: control trees, then files.
        #expect(roots.first == .pinned(".git", [.tree("hooks"), .file("config")]))
        #expect(roots.contains(.pinned(".claude", [.file("settings.json"), .file("settings.local.json"), .tree("hooks")])))
        #expect(roots.contains(.pinned(".gemini", [.file("settings.json"), .pinned("config", [.file("hooks.json")])])))
        #expect(roots.contains(.file(".envrc")))
    }
}
