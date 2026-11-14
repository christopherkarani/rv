import Foundation
import Testing
import RVDomain
import RVEngine
import RVPresentation
@testable import RVCLI

/// `rv setup` installs one rv-owned SKILL.md per host with a user skill
/// directory. These tests drive the installer against a throwaway HOME.
@Suite("Agent skill installer")
struct AgentSkillInstallerTests {
    private func withSkillHome(_ body: (String, FileOps) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("rv-skill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(root.path + "/.claude/skills/rv/SKILL.md", FileOps(fileManager: .default))
    }

    @Test("a fresh install writes the sealed skill")
    func freshInstallWrites() throws {
        try withSkillHome { path, files in
            #expect(try AgentSkill.install(at: path, files: files) == .wrote)
            let data = try #require(files.readData(path))
            #expect(data == AgentSkill.rendered)
            #expect(String(decoding: data, as: UTF8.self).hasPrefix("---\nname: rv\n"))
            #expect(AgentSkill.ownership(of: data) == .current)
        }
    }

    @Test("a second install of the same skill writes nothing")
    func reinstallIsQuiet() throws {
        try withSkillHome { path, files in
            _ = try AgentSkill.install(at: path, files: files)
            #expect(try AgentSkill.install(at: path, files: files) == .unchanged)
        }
    }

    @Test("an older rv-sealed skill is replaced")
    func staleOwnedIsReplaced() throws {
        try withSkillHome { path, files in
            let older = AgentSkill.sealed("---\nname: rv\ndescription: old\n---\nold text\n")
            #expect(AgentSkill.ownership(of: older) == .ownedStale)
            try files.createDirectory(atPath: (path as NSString).deletingLastPathComponent)
            try older.write(to: URL(fileURLWithPath: path))
            #expect(try AgentSkill.install(at: path, files: files) == .wrote)
            #expect(files.readData(path) == AgentSkill.rendered)
        }
    }

    @Test("a skill edited outside rv is kept, byte for byte")
    func modifiedIsKept() throws {
        try withSkillHome { path, files in
            _ = try AgentSkill.install(at: path, files: files)
            var edited = AgentSkill.rendered
            edited.append(contentsOf: Array("my own note\n".utf8))
            try edited.write(to: URL(fileURLWithPath: path))
            #expect(AgentSkill.ownership(of: edited) == .foreign)
            #expect(try AgentSkill.install(at: path, files: files) == .keptForeign)
            #expect(files.readData(path) == edited)
        }
    }

    @Test("a hand-written skill with no rv seal is kept")
    func unsealedIsKept() throws {
        try withSkillHome { path, files in
            try files.write("---\nname: rv\n---\nmine\n", to: path)
            #expect(try AgentSkill.install(at: path, files: files) == .keptForeign)
            #expect(files.readData(path) == Data("---\nname: rv\n---\nmine\n".utf8))
        }
    }

    @Test("a symlinked skill file or skill directory is never followed")
    func symlinksAreKept() throws {
        try withSkillHome { path, files in
            let directory = (path as NSString).deletingLastPathComponent
            let skills = (directory as NSString).deletingLastPathComponent
            let elsewhere = (skills as NSString).deletingLastPathComponent + "/elsewhere"
            try files.createDirectory(atPath: elsewhere)
            try files.createDirectory(atPath: skills)
            try FileManager.default.createSymbolicLink(atPath: directory, withDestinationPath: elsewhere)
            #expect(try AgentSkill.install(at: path, files: files) == .keptForeign)
            #expect(files.fileExists(elsewhere + "/SKILL.md") == false)

            try FileManager.default.removeItem(atPath: directory)
            try files.createDirectory(atPath: directory)
            try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: elsewhere + "/target.md")
            #expect(try AgentSkill.install(at: path, files: files) == .keptForeign)
            #expect(files.isSymbolicLink(path))
            #expect(files.fileExists(elsewhere + "/target.md") == false)
        }
    }

    @Test("an unreadable skill file is kept, not treated as absent")
    func unreadableIsKept() throws {
        #if os(Linux)
        guard getuid() != 0 else { return } // root reads mode 000 files
        #endif
        try withSkillHome { path, files in
            try files.write("---\nname: rv\n---\nmine\n", to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: path)
            defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path) }
            #expect(try AgentSkill.install(at: path, files: files) == .keptForeign)
        }
    }

    @Test("removal deletes only an rv-sealed skill")
    func removalChecksOwnership() throws {
        try withSkillHome { path, files in
            _ = try AgentSkill.install(at: path, files: files)
            #expect(AgentSkill.isOwned(at: path, files: files))

            try files.write("---\nname: rv\n---\nmine\n", to: path)
            #expect(AgentSkill.isOwned(at: path, files: files) == false)

            files.removeFile(atPath: path)
            #expect(AgentSkill.isOwned(at: path, files: files) == false)
        }
    }
}

@Suite("Agent skill host rows")
struct AgentSkillHostRowTests {
    private let layout = OwnedPaths(home: testHomeDirectory("/Users/me"))

    @Test("only hosts with a documented user skill directory get the skill")
    func skillHosts() {
        #expect(layout.agentSkill(for: .claude) == "/Users/me/.claude/skills/rv/SKILL.md")
        #expect(layout.agentSkill(for: .codex) == "/Users/me/.agents/skills/rv/SKILL.md")
        #expect(layout.agentSkill(for: .opencode) == "/Users/me/.config/opencode/skills/rv/SKILL.md")
        for host in HookHost.setupSlotOrder where [.claude, .codex, .opencode].contains(host) == false {
            #expect(layout.agentSkill(for: host) == nil, "\(host)")
        }
    }

    @Test("attach carries the skill and detach removes it")
    func attachAndDetach() {
        for host in HookHost.setupSlotOrder {
            let skill = layout.agentSkill(for: host)
            let attach = HostArtifacts.attach(host: host, layout: layout, existingData: nil, forceClear: false)
            #expect(attach.agentSkill == skill, "\(host)")
            let detach = HostArtifacts.detach(host: host, layout: layout)
            if let skill {
                #expect(detach.remove.contains(.removeAgentSkill(skill)), "\(host)")
                #expect(detach.leaveOccupied.contains(.removeAgentSkill(skill)), "\(host)")
            } else {
                #expect(detach.remove.allSatisfy { if case .removeAgentSkill = $0 { false } else { true } })
            }
        }
    }

    @Test("every skill path is rv wiring, guarded against agent edits")
    func skillPathsAreWiring() {
        for host in HookHost.setupSlotOrder {
            guard let skill = layout.agentSkill(for: host) else { continue }
            #expect(RVWiringPaths.matches(skill, home: "/Users/me"), "\(skill)")
            let directory = (skill as NSString).deletingLastPathComponent
            #expect(RVWiringPaths.matches(directory + "/extra.md", home: "/Users/me"), "\(directory)")
            let skills = (directory as NSString).deletingLastPathComponent
            #expect(RVWiringPaths.matchesAncestor(skills, home: "/Users/me"), "\(skills)")
            #expect(RVWiringPaths.fixedFiles(home: "/Users/me").contains(skill), "\(skill)")
        }
    }

    @Test("a kept skill is named on stderr with a fix")
    func keptWarning() {
        var report = SetupReport(grok: .skipped, pi: .skipped, openCode: .skipped, wrote: [])
        #expect(SetupRun.agentSkillWarning(report) == "")
        report.agentSkillsKept = ["/Users/me/.claude/skills/rv/SKILL.md"]
        let warning = SetupRun.agentSkillWarning(report)
        #expect(warning.contains("/Users/me/.claude/skills/rv/SKILL.md"))
        #expect(warning.contains("changed outside rv"))
        #expect(warning.hasSuffix("\n"))
    }
}

@Suite("Agent skill wiring through the host lifecycle")
struct AgentSkillLifecycleTests {
    @Test("wiring Claude installs the skill; detaching removes it and its empty directories")
    func claudeAttachDetach() throws {
        try withTempHome { home, layout, launchctl in
            try FileManager.default.createDirectory(atPath: layout.claudeDirectory, withIntermediateDirectories: true)
            let files = FileOps(fileManager: .default)
            let environment = env(home: home, launchctl: launchctl, touchLaunchd: false)
            let write = HostArtifacts.attach(host: .claude, layout: layout, existingData: nil, forceClear: false)
            let outcome = try HostLifecycle.perform(write, env: environment, layout: layout, files: files)
            let skill = try #require(layout.agentSkill(for: .claude))
            #expect(outcome == .wired(wrote: true, keptAgentSkill: nil))
            #expect(files.readData(skill) == AgentSkill.rendered)

            let again = try HostLifecycle.perform(write, env: environment, layout: layout, files: files)
            #expect(again == .wired(wrote: false, keptAgentSkill: nil))

            let installations = try SetupRun.inspectInstallations(layout: layout, env: environment)
            let detached = try HostLifecycle.detach(
                installations: installations, env: environment, layout: layout, files: files, only: [.claude])
            #expect(detached.removedPaths.contains(skill))
            #expect(files.fileExists(skill) == false)
            #expect(files.fileExists(layout.claudeDirectory + "/skills") == false)
        }
    }

    @Test("a skill edited outside rv survives setup and uninstall, and setup reports it")
    func modifiedSkillSurvives() throws {
        try withTempHome { home, layout, launchctl in
            let skill = try #require(layout.agentSkill(for: .claude))
            let files = FileOps(fileManager: .default)
            try files.write("---\nname: rv\n---\nmine\n", to: skill)
            let environment = env(home: home, launchctl: launchctl, touchLaunchd: false)
            let write = HostArtifacts.attach(host: .claude, layout: layout, existingData: nil, forceClear: false)
            let outcome = try HostLifecycle.perform(write, env: environment, layout: layout, files: files)
            #expect(outcome == .wired(wrote: true, keptAgentSkill: skill))

            let installations = try SetupRun.inspectInstallations(layout: layout, env: environment)
            let detached = try HostLifecycle.detach(
                installations: installations, env: environment, layout: layout, files: files, only: [.claude])
            #expect(detached.removedPaths.contains(skill) == false)
            #expect(files.readData(skill) == Data("---\nname: rv\n---\nmine\n".utf8))
        }
    }
}

/// The skill text must stay true: every `rv …` command it names is a real
/// subcommand, the agent is only told to run commands the guard lets it
/// run, and the "never" list names commands the guard really refuses.
@Suite("Agent skill content")
struct AgentSkillContentTests {
    private static let topics: [HelpTopic] = [
        .root, .help, .test, .explain, .service, .serviceStatus, .serviceRestart, .hook, .setup,
        .initialize, .uninstall, .doctor, .allowOnce, .packs, .scan, .policy, .allowlist, .safety,
        .blocks, .host, .audit, .secrets, .mcp, .managed, .report, .opencode, .workspace, .`operator`,
        .egress, .login,
    ]

    private enum Bucket { case agent, human, never }

    private struct NamedCommand {
        var text: String
        var bucket: Bucket
    }

    /// Backticked spans that start with `rv `, with the bucket of the
    /// `## ` section they sit in.
    private static func commands(in text: String) -> [NamedCommand] {
        var bucket = Bucket.agent
        var found: [NamedCommand] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                switch line.dropFirst(3) {
                case "Commands only the human runs": bucket = .human
                case "Never": bucket = .never
                default: bucket = .agent
                }
            }
            let spans = line.split(separator: "`", omittingEmptySubsequences: false)
            for (index, span) in spans.enumerated() where index % 2 == 1 && span.hasPrefix("rv ") {
                found.append(NamedCommand(text: String(span), bucket: bucket))
            }
        }
        return found
    }

    /// `rv …` usage rows from every help page.
    private static var usages: [String] {
        topics.flatMap { HelpCatalog.page($0).sections.flatMap(\.rows).map(\.name) }
            .filter { $0.hasPrefix("rv ") }
    }

    /// Whether `command` is spelled by `usage`: same words in order, an
    /// optional `[--flag]` may be given, `<x>` takes a `<y>` placeholder,
    /// and `<a|b>` takes one of its words.
    static func matches(_ command: String, usage: String) -> Bool {
        var optionalFlags: Set<String> = []
        var required = ""
        var depth = 0
        var group = ""
        for character in usage {
            if character == "[" { depth += 1; continue }
            if character == "]" {
                depth -= 1
                if depth == 0 {
                    optionalFlags.formUnion(group.split(separator: " ").map(String.init).filter { $0.hasPrefix("--") })
                    group = ""
                }
                continue
            }
            if depth > 0 { group.append(character) } else { required.append(character) }
        }
        let wanted = required.split(separator: " ").map(String.init)
        let given = command.split(separator: " ").map(String.init).filter { optionalFlags.contains($0) == false }
        guard wanted.count == given.count else { return false }
        return zip(wanted, given).allSatisfy { want, word in
            guard want.hasPrefix("<"), want.hasSuffix(">") else { return want == word }
            let choices = want.dropFirst().dropLast().split(separator: "|").map(String.init)
            if choices.count > 1 { return choices.contains(word) }
            return word.hasPrefix("<") && word.hasSuffix(">")
        }
    }

    /// Placeholders filled with plausible values so the guard parses a
    /// real command line (a bare `<x>` is a shell redirect).
    private static func concrete(_ command: String) -> String {
        command
            .replacingOccurrences(of: "<code>", with: "a1b2c3")
            .replacingOccurrences(of: "<id>", with: "0F3A9C2E-1B2D-4E5F-8A9B-112233445566")
            .replacingOccurrences(of: "<host>", with: "claude")
            .replacingOccurrences(of: "<pack>", with: "core.git")
            .replacingOccurrences(of: "<rule>", with: "core.git:reset-hard")
            .replacingOccurrences(of: "<command>", with: "ls")
    }

    @Test("the skill is short and starts with skill frontmatter")
    func shape() {
        let text = AgentSkill.text
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).count
        #expect((50...110).contains(lines), "\(lines) lines")
        #expect(text.hasPrefix("---\nname: rv\ndescription: "))
        #expect(text.contains("rv.egress.denied.v1"))
        #expect(text.contains("next_step"))
    }

    @Test("the matcher accepts real spellings and rejects invented ones")
    func matcherSanity() {
        #expect(Self.matches("rv egress denials", usage: "rv egress denials [--limit N] [--json]"))
        #expect(Self.matches("rv setup --observe", usage: "rv setup [--force] [--observe] [--json]"))
        #expect(Self.matches("rv host mode <host> off", usage: "rv host mode <host> <block|observe|off> [--json]"))
        #expect(Self.matches("rv egress grant <id>", usage: "rv egress approve <id>") == false)
        #expect(Self.matches("rv setup --yolo", usage: "rv setup [--force] [--observe]") == false)
        #expect(Self.matches("rv host mode <host> maybe", usage: "rv host mode <host> <block|observe|off>") == false)
    }

    @Test("every rv command the skill names is a real subcommand")
    func commandsExist() {
        let named = Self.commands(in: AgentSkill.text)
        #expect(named.count >= 8)
        let usages = Self.usages
        for command in named {
            #expect(usages.contains { Self.matches(command.text, usage: $0) }, "not a real command: \(command.text)")
        }
    }

    @Test("the agent is only told to run commands the guard lets it run")
    func agentCommandsAreSafe() {
        let named = Self.commands(in: AgentSkill.text)
        let agent = named.filter { $0.bucket == .agent }
        #expect(agent.isEmpty == false)
        for command in agent {
            let line = ShellCommand(rawValue: Self.concrete(command.text))
            #expect(SelfProtectionGuard.weakensPolicy(line) == false, "owner-only outside the human list: \(command.text)")
        }
    }

    @Test("the human list carries the grants and the never list is really refused")
    func humanAndNeverLists() {
        let named = Self.commands(in: AgentSkill.text)
        let human = named.filter { $0.bucket == .human }.map(\.text)
        #expect(human.contains("rv allow-once <code>"))
        #expect(human.contains("rv egress approve <id>"))
        let never = named.filter { $0.bucket == .never }
        #expect(never.count >= 5)
        for command in never {
            let line = ShellCommand(rawValue: Self.concrete(command.text))
            #expect(SelfProtectionGuard.weakensPolicy(line), "never-list command the guard allows: \(command.text)")
        }
    }
}
