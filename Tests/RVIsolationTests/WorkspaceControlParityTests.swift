import Foundation
import Testing
@testable import RVIsolation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// `ProtectedWorkspacePaths` is the one catalog of workspace control and
/// run-later paths. Each backend turns it into its own form: Seatbelt rules
/// (also the macOS guest's), the micro-VM placeholder tree, and the
/// transfer's refusal check. These tests read each form back and require it
/// to cover every catalog path, pinned directory and case variant, so a
/// form that drops one fails here. The Linux guest's mount tree has the
/// same test in `Packages/rv-microvm` (`WorkspaceControlLayoutParityTests`).
@Suite("Workspace control path parity")
struct WorkspaceControlParityTests {
    private typealias Catalog = ProtectedWorkspacePaths
    private let workspace = "/Users/dev/project"

    // MARK: - Case variants

    /// Spellings of `path` a case-insensitive APFS volume opens as `path`,
    /// built without the catalog's own rule: as listed, upper case, each
    /// component capitalized, and `s`/`k` swapped for U+017F / U+212A.
    static func caseVariants(_ path: String) -> [String] {
        let capitalized = path.split(separator: "/").map { component in
            let letters = Array(component)
            guard let index = letters.firstIndex(where: \.isLetter) else { return String(component) }
            return String(letters[..<index]) + letters[index].uppercased() + String(letters[(index + 1)...])
        }.joined(separator: "/")
        let folded = path.replacingOccurrences(of: "s", with: "\u{017F}").replacingOccurrences(of: "k", with: "\u{212A}")
        let upperFolded = path.uppercased().replacingOccurrences(of: "K", with: "\u{212A}")
        var variants: [String] = []
        for variant in [path, path.uppercased(), capitalized, folded, upperFolded] where variants.contains(variant) == false {
            variants.append(variant)
        }
        return variants
    }

    @Test("the case-variant helper produces non-ASCII folds")
    func caseVariantHelper() {
        #expect(Self.caseVariants(".mcp.json").contains(".mcp.j\u{017F}on"))
        #expect(Self.caseVariants(".git/hooks").contains(".GIT/HOO\u{212A}S"))
        #expect(Self.caseVariants(".claude/settings.json").contains(".Claude/Settings.json"))
    }

    // MARK: - Seatbelt rules, read back

    /// One SBPL filter from a `(deny ops ...)` block.
    struct Rule: Equatable {
        let operations: Set<String>
        let filter: String
        let argument: String
    }

    /// The deny filters in a profile rendered as rv renders it: a
    /// `(deny ops` line opens a block, each following `(filter "arg")` line
    /// belongs to it. SBPL string escapes (`\\`, `\"`) are undone.
    static func denyRules(_ profile: String) -> [Rule] {
        var rules: [Rule] = []
        var operations: Set<String> = []
        for line in profile.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("(deny ") {
                let body = text.dropFirst("(deny ".count)
                operations = body.hasSuffix(")") ? [] : Set(body.split(separator: " ").map(String.init))
                continue
            }
            guard operations.isEmpty == false, text.hasPrefix("("),
                  let space = text.firstIndex(of: " "),
                  let open = text.firstIndex(of: "\"") else { continue }
            let filter = String(text[text.index(after: text.startIndex)..<space])
            var argument = ""
            var escaped = false
            for character in text[text.index(after: open)...] {
                if escaped {
                    argument.append(character)
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    break
                } else {
                    argument.append(character)
                }
            }
            rules.append(Rule(operations: operations, filter: filter, argument: argument))
        }
        return rules
    }

    /// POSIX extended-regex match, the dialect Seatbelt `regex` filters use.
    static func regexMatches(_ pattern: String, _ path: String) -> Bool {
        var compiled = regex_t()
        guard regcomp(&compiled, pattern, REG_EXTENDED | REG_NOSUB) == 0 else {
            Issue.record("pattern does not compile: \(pattern)")
            return false
        }
        defer { regfree(&compiled) }
        return regexec(&compiled, path, 0, nil, 0) == 0
    }

    /// Whether some rule denies `operation` on the absolute `path`.
    static func denies(_ rules: [Rule], _ operation: String, _ path: String) -> Bool {
        rules.contains { rule in
            guard rule.operations.contains(operation) || rule.operations.contains("file-write*") else { return false }
            switch rule.filter {
            case "literal": return path == rule.argument
            case "subpath": return path == rule.argument || path.hasPrefix(rule.argument + "/")
            case "regex": return regexMatches(rule.argument, path)
            default: return false
            }
        }
    }

    @Test("the rule reader sees the filters and operations rv renders")
    func ruleReader() {
        let rules = Self.denyRules("""
            (version 1)
            (deny file-link)
            (deny file-write*
                (subpath "/w/a\\"b")
                (regex "^/w/[xX]$"))
            (deny file-write-unlink file-write-create
                (literal "/w/c"))
            """)
        #expect(rules == [
            Rule(operations: ["file-write*"], filter: "subpath", argument: "/w/a\"b"),
            Rule(operations: ["file-write*"], filter: "regex", argument: "^/w/[xX]$"),
            Rule(operations: ["file-write-unlink", "file-write-create"], filter: "literal", argument: "/w/c"),
        ])
        #expect(Self.denies(rules, "file-write-data", "/w/a\"b/deep"))
        #expect(Self.denies(rules, "file-write-data", "/w/X"))
        #expect(Self.denies(rules, "file-write-create", "/w/c"))
        #expect(Self.denies(rules, "file-write-data", "/w/c") == false)
        #expect(Self.denies(rules, "file-write-data", "/w/y") == false)
    }

    /// Seatbelt's rules and the macOS guest's profile, which reuses them.
    private var seatbeltForms: [(name: String, rules: [Rule])] {
        [
            ("Seatbelt", Self.denyRules(workspaceControlDenies(workspacePath: workspace))),
            ("macOS guest", Self.denyRules(macOSGuestSandboxProfile(workspacePath: workspace))),
        ]
    }

    @Test("Seatbelt denies writing every catalog path in every spelling")
    func seatbeltCoversEveryPath() {
        for form in seatbeltForms {
            for path in Catalog.paths {
                let isTree = Catalog.trees.contains(path)
                for variant in Self.caseVariants(path) {
                    let targets = isTree ? [variant, variant + "/x", variant + "/deep/x"] : [variant]
                    for target in targets {
                        for operation in ["file-write-data", "file-write-create", "file-write-unlink"] {
                            #expect(
                                Self.denies(form.rules, operation, "\(workspace)/\(target)"),
                                "\(form.name) does not deny \(operation) on \(target)"
                            )
                        }
                    }
                }
            }
        }
    }

    @Test("Seatbelt pins every catalog directory in every spelling")
    func seatbeltPinsEveryDirectory() {
        for form in seatbeltForms {
            for directory in Catalog.controlPinned + Catalog.runLaterPinned {
                for variant in Self.caseVariants(directory) {
                    for operation in ["file-write-create", "file-write-unlink"] {
                        #expect(
                            Self.denies(form.rules, operation, "\(workspace)/\(variant)"),
                            "\(form.name) does not pin \(variant) against \(operation)"
                        )
                    }
                }
            }
            // A worktree `.git` is a file whose `gitdir:` line the host follows.
            for variant in Self.caseVariants(Catalog.gitDirectory) {
                #expect(Self.denies(form.rules, "file-write-data", "\(workspace)/\(variant)"), "\(form.name): \(variant)")
            }
            // Pinning is the entry only: git must still write objects and refs.
            #expect(Self.denies(form.rules, "file-write-data", "\(workspace)/.git/objects/ab") == false)
            #expect(Self.denies(form.rules, "file-write-data", "\(workspace)/.claude/agents/a.md") == false)
        }
    }

    // MARK: - Transfer check

    @Test("the transfer refuses every catalog path in every spelling, and anything under .git")
    func transferCoversEveryPath() {
        for path in [Catalog.gitDirectory] + Catalog.paths {
            for variant in Self.caseVariants(path) {
                let components = variant.split(separator: "/").map(String.init)
                #expect(WorkspaceTransfer.isProtectedWorkspacePath(components), "transfer allows \(variant)")
                #expect(WorkspaceTransfer.isProtectedWorkspacePath(components + ["x"]), "transfer allows \(variant)/x")
            }
        }
        #expect(WorkspaceTransfer.isProtectedWorkspacePath([".git", "objects", "ab"]))
        #expect(WorkspaceTransfer.isProtectedWorkspacePath([".vscode", "launch.json"]) == false)
    }

    // MARK: - Micro-VM placeholder tree

    /// The protected leaves (files and trees) and pinned directories of a
    /// placeholder tree, as workspace-relative paths.
    static func flatten(_ nodes: [MicroVMControlLayout.Node], under prefix: String = "")
        -> (files: Set<String>, trees: Set<String>, pinned: Set<String>) {
        var files = Set<String>(), trees = Set<String>(), pinned = Set<String>()
        for node in nodes {
            let path = prefix.isEmpty ? node.name : "\(prefix)/\(node.name)"
            switch node {
            case .file: files.insert(path)
            case .tree: trees.insert(path)
            case .pinned(_, let children):
                pinned.insert(path)
                let inner = flatten(children, under: path)
                files.formUnion(inner.files)
                trees.formUnion(inner.trees)
                pinned.formUnion(inner.pinned)
            }
        }
        return (files, trees, pinned)
    }

    @Test("the placeholder tree holds every catalog path and pins every catalog directory")
    func placeholderTreeCoversEveryPath() {
        // Exact names only: a micro-VM can only mount over a name that exists.
        let tree = Self.flatten(MicroVMControlLayout.roots)
        #expect(tree.files == Set(Catalog.controlFiles + Catalog.runLaterFiles))
        #expect(tree.trees == Set(Catalog.trees))
        #expect(tree.pinned == Set(Catalog.controlPinned + Catalog.runLaterPinned))
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

    // MARK: - The catalog itself

    @Test("every directory on the way to a protected path is pinned")
    func everyAncestorIsPinned() {
        let pinned = Set(Catalog.controlPinned + Catalog.runLaterPinned)
        for path in Catalog.paths {
            var ancestors = path.split(separator: "/").dropLast()
            while ancestors.isEmpty == false {
                let directory = ancestors.joined(separator: "/")
                #expect(pinned.contains(directory), "\(directory) on the way to \(path) is not pinned")
                ancestors = ancestors.dropLast()
            }
        }
        #expect(Catalog.runLaterPinned.contains(".gemini/config"))
    }

    @Test("the catalog's spellings and fold agree on every variant")
    func spellingsAndFoldAgree() {
        #expect(Catalog.spellings(of: "s") == ["s", "S", "\u{017F}"])
        #expect(Catalog.spellings(of: "K") == ["k", "K", "\u{212A}"])
        #expect(Catalog.spellings(of: "a") == ["a", "A"])
        #expect(Catalog.spellings(of: ".") == ["."])
        for path in Catalog.paths + Catalog.controlPinned + Catalog.runLaterPinned {
            for variant in Self.caseVariants(path) {
                #expect(Catalog.folded(variant) == Catalog.folded(path), "\(variant) does not fold to \(path)")
                #expect(Catalog.folded(variant) == path, "catalog path \(path) is not in folded form")
            }
        }
    }

    @Test("the micro-VM guest compiles this same catalog file")
    func guestSharesTheCatalogFile() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let shared = root.appendingPathComponent("Sources/RVIsolation/ProtectedWorkspacePaths.swift")
        let guest = root.appendingPathComponent("Packages/rv-microvm/Sources/RVMicroVMCore/ProtectedWorkspacePaths.swift")
        // A symlink, so the guest cannot drift into a hand-kept copy.
        let destination = try FileManager.default.destinationOfSymbolicLink(atPath: guest.path)
        #expect(destination == "../../../../Sources/RVIsolation/ProtectedWorkspacePaths.swift")
        #expect(guest.resolvingSymlinksInPath().path == shared.resolvingSymlinksInPath().path)
    }
}
