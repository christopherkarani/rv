/// The workspace paths no backend lets a runtime write: rv and git control
/// paths, and the run-later paths a host tool runs or trusts later, outside
/// any cage. Also the directories pinned on the way to them, and how a name
/// matches one on a case-insensitive volume.
///
/// Each backend turns this one catalog into its own form: Seatbelt rules
/// (`workspaceControlDenies`, which the macOS guest reuses), the micro-VM
/// placeholder and mount tree (`MicroVMControlLayout`, and
/// `WorkspaceControlLayout` in `Packages/rv-microvm`), and the transfer's
/// refusal check (`WorkspaceTransfer.isProtectedWorkspacePath`). A path
/// added here is protected everywhere; `WorkspaceControlParityTests` checks
/// that each form covers every path and spelling.
///
/// This file is compiled into two modules. `Packages/rv-microvm` cannot
/// import RVIsolation, so `RVMicroVMCore/ProtectedWorkspacePaths.swift`
/// there is a symlink to this file. Keep it pure: no imports, no I/O.
package enum ProtectedWorkspacePaths {
    // MARK: - Control paths

    /// The git directory. Its entry is pinned, and its contents also
    /// matter: a worktree `.git` is a file whose `gitdir:` line points the
    /// host at another tree.
    package static let gitDirectory = ".git"

    /// rv and git control files. `.git/config` is a file, not a tree:
    /// `core.hooksPath`, `core.fsmonitor` and `core.sshCommand` plant a hook
    /// the host later runs, while the rest of `.git` (index, objects, refs)
    /// must stay writable for git to work.
    package static let controlFiles = [".git/config"]

    /// rv and git control directories protected with everything beneath.
    package static let controlTrees = [".git/hooks", ".rv", ".config/rv"]

    /// Control directories whose own entry may not be created or removed,
    /// so a cage cannot rename one aside and swap in a replacement.
    package static let controlPinnedDirectories = [gitDirectory, ".config"]

    // MARK: - Run-later paths

    /// Agent, editor and shell config a host tool executes or trusts on its
    /// own. A caged agent that writes a hook into `.claude/settings.json`, a
    /// server into `.mcp.json`, or a task into `.vscode/tasks.json` gets that
    /// code run unsandboxed the next time the developer uses the tool.
    ///
    /// Instruction files (`CLAUDE.md`, `AGENTS.md`) and skill folders are not
    /// listed: agents edit them as normal work, and they carry instructions
    /// rather than code the host runs on its own. Changes to them belong in
    /// the review shown before publish. Config in nested directories (for a
    /// tool started in a subfolder) is not covered either.
    package static let runLaterFiles = [
        ".claude/settings.json",
        ".claude/settings.local.json",
        ".mcp.json",
        ".codex/config.toml",
        ".codex/hooks.json",
        ".cursor/hooks.json",
        ".cursor/mcp.json",
        ".gemini/settings.json",
        ".gemini/config/hooks.json",
        ".vscode/tasks.json",
        ".vscode/settings.json",
        "opencode.json",
        "opencode.jsonc",
        ".envrc",
    ]

    /// Directories whose whole contents are protected: scripts the settings
    /// above call by path.
    package static let runLaterTrees = [
        ".claude/hooks",
        ".cursor/hooks",
        ".codex/hooks",
    ]

    /// Parent directories of run-later paths whose own entry may not be
    /// created or removed. Same reason as `controlPinnedDirectories`.
    package static let runLaterPinnedDirectories = [".claude", ".codex", ".cursor", ".gemini", ".vscode"]

    // MARK: - Derived sets

    /// Every protected control path, trees first.
    package static let controlPaths = controlTrees + controlFiles

    /// Every protected run-later path, files first.
    package static let runLaterPaths = runLaterFiles + runLaterTrees

    /// Every protected path, in mount order.
    package static let paths = controlPaths + runLaterPaths

    /// Every protected directory (protected with everything beneath).
    package static let trees = controlTrees + runLaterTrees

    /// Pinned control directories, with any directory between a pinned root
    /// and a protected path.
    package static let controlPinned = pinned(roots: controlPinnedDirectories, protecting: controlPaths)

    /// Pinned run-later directories, with every directory between a pinned
    /// root and a protected path (`.gemini/config` for
    /// `.gemini/config/hooks.json`): the path is matched by name, so
    /// renaming a directory above it aside would bypass the protection.
    package static let runLaterPinned = pinned(roots: runLaterPinnedDirectories, protecting: runLaterPaths)

    /// `roots`, then each intermediate directory of a path at least three
    /// components deep, in first-seen order.
    static func pinned(roots: [String], protecting paths: [String]) -> [String] {
        var pinned = roots
        for path in paths {
            let components = path.split(separator: "/").map(String.init)
            guard components.count > 2 else { continue }
            for depth in 2..<components.count {
                let intermediate = components[..<depth].joined(separator: "/")
                if pinned.contains(intermediate) == false { pinned.append(intermediate) }
            }
        }
        return pinned
    }

    // MARK: - Matching

    /// Non-ASCII characters whose Unicode case folding is a single ASCII
    /// letter (CaseFolding.txt, status C): U+017F LATIN SMALL LETTER LONG S
    /// folds to `s`, U+212A KELVIN SIGN to `k`. A case-insensitive APFS
    /// volume opens `.mcp.j\u{017F}on` as `.mcp.json`.
    package static let nonASCIIFolds: [Character: Character] = ["\u{017F}": "s", "\u{212A}": "k"]

    /// Every spelling a case-insensitive volume treats as `character`:
    /// lower case, upper case, then any non-ASCII letter that folds onto it.
    /// One spelling for anything that is not an ASCII letter.
    package static func spellings(of character: Character) -> [Character] {
        guard character.isASCII, character.isLetter else { return [character] }
        let lower = Character(character.lowercased())
        let upper = Character(character.uppercased())
        let folds = nonASCIIFolds.filter { $0.value == lower }.map(\.key).sorted()
        return [lower, upper] + folds
    }

    /// `name` as a case-insensitive volume compares it: lower-cased, with
    /// the non-ASCII folds above mapped onto ASCII.
    package static func folded(_ name: String) -> String {
        var folded = ""
        for character in name.lowercased() {
            folded.append(nonASCIIFolds[character] ?? character)
        }
        return folded
    }

    // MARK: - Tree

    /// One protected path in the tree the micro-VM placeholders and mounts
    /// follow.
    package indirect enum Node: Equatable, Sendable {
        /// A protected file.
        case file(String)
        /// A protected directory, with everything beneath.
        case tree(String)
        /// A pinned directory with its protected children inside.
        case pinned(String, [Node])

        package var name: String {
            switch self {
            case .file(let name), .tree(let name), .pinned(let name, _): name
            }
        }
    }

    /// Workspace-root nodes in mount order: rv and git control paths first,
    /// then agent and editor config, then top-level run-later files.
    package static let roots: [Node] = tree(
        protected: paths,
        trees: Set(trees),
        pinnedRoots: controlPinnedDirectories + runLaterPinnedDirectories,
        order: topLevelNames(controlPaths) + runLaterPinnedDirectories
    )

    /// First component of each path, in first-seen order.
    static func topLevelNames(_ paths: [String]) -> [String] {
        var names: [String] = []
        for path in paths {
            let name = String(path.split(separator: "/", maxSplits: 1).first ?? Substring(path))
            if names.contains(name) == false { names.append(name) }
        }
        return names
    }

    /// Builds the tree from flat workspace-relative paths. A path under a
    /// pinned root goes inside it; an intermediate directory on the way to
    /// a deeper path (`.gemini/config`) is pinned too, so it cannot be
    /// renamed aside either. `trees` marks which leaves are directories.
    static func tree(protected: [String], trees: Set<String>, pinnedRoots: [String], order: [String]) -> [Node] {
        func leaf(_ path: String) -> Node {
            let name = String(path.split(separator: "/").last ?? Substring(path))
            return trees.contains(path) ? .tree(name) : .file(name)
        }
        func children(of prefix: String) -> [Node] {
            var names: [String] = []
            var deeper: [String: Bool] = [:]
            for path in protected where path.hasPrefix(prefix + "/") {
                let rest = path.dropFirst(prefix.count + 1)
                let first = String(rest.split(separator: "/", maxSplits: 1)[0])
                if deeper[first] == nil { names.append(first) }
                deeper[first] = (deeper[first] ?? false) || rest.contains("/")
            }
            return names.map { name in
                deeper[name] == true ? .pinned(name, children(of: "\(prefix)/\(name)")) : leaf("\(prefix)/\(name)")
            }
        }
        var roots: [Node] = []
        var seen = Set<String>()
        func add(_ name: String) {
            guard seen.insert(name).inserted else { return }
            roots.append(pinnedRoots.contains(name) ? .pinned(name, children(of: name)) : leaf(name))
        }
        for name in order { add(name) }
        for path in protected where path.contains("/") == false { add(path) }
        return roots
    }
}
