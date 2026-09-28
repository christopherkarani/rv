import ArgumentParser
import Foundation
#if os(macOS)
import Darwin
import RVDomain
import RVIsolation
import RVPolicy
import RVWorkspaceTUI
#endif

public struct WorkspaceTUI: AsyncParsableCommand {
    public static let configuration = CommandConfiguration(
        commandName: "tui",
        abstract: "Open the workspace shell. Runtimes stay alive after detach."
    )

    @OptionGroup var path: WorkspacePath

    public init() {}

    public func run() async throws {
        try await WorkspaceTUICommand.run(path.workspace)
    }
}

enum WorkspaceTUICommand {
    static func run(_ raw: String?) async throws {
        #if !os(macOS)
        throw ValidationError("contained workspace host is unavailable")
        #else
        guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
            throw ValidationError("workspace shell requires an interactive terminal")
        }
        let project = try WorkspaceCommandRun.requireProject(raw)
        guard let host = WorkspaceHostExecutable.currentSibling() else {
            throw ValidationError("workspace host executable is missing")
        }
        let endpoint: WorkspaceEndpoint
        switch WorkspaceHosts.ensure(project: project, executable: host) {
        case .success(let value):
            endpoint = value
        case .failure(let error):
            throw ValidationError(WorkspaceCommandRun.text(error))
        }
        guard case .success(let session) = LiveWorkspaceTUISession.connect(
            endpoint, project: project, hostExecutable: host
        ) else {
            throw ValidationError("workspace host is not reachable")
        }
        let described: WorkspaceTUISummary
        switch session.inventory() {
        case .success(let inventoried):
            described = inventoried.summary
        case .failure:
            session.close()
            throw ValidationError("workspace host is not reachable")
        }
        let openedLayout: WorkspaceLayoutOpenResult
        do {
            openedLayout = try WorkspaceLayoutStore.open(canonicalOriginalProject: described.project)
        } catch {
            session.close()
            throw ValidationError("workspace layout could not be opened: \(error)")
        }
        let policy = Self.loadResourceProfiles()
        let launcher = Self.applyingResourceProfiles(
            launcherChoices(),
            profiles: policy.profiles,
            project: described.project,
            defaultProfile: policy.defaultProfile
        )
        // The auto-opened shell runs under the operator default when the
        // policy yields that variant; otherwise it stays the plain shell.
        let defaultShellID: String = {
            guard let want = policy.defaultProfile,
                launcher.contains(where: { $0.id == "shell:\(want)" })
            else { return "shell" }
            return "shell:\(want)"
        }()
        let model = WorkspaceTUIModel(
            session: session,
            summary: described,
            launcher: launcher,
            defaultShellID: defaultShellID,
            restoredView: openedLayout.session.revision == 0 ? nil : openedLayout.session.view,
            initialViewID: openedLayout.session.viewID
        )
        switch openedLayout.notice {
        case .corrupt:
            model.reportNotice("Saved layout is damaged; a separate temporary view was opened")
        case .newerVersion(let version):
            model.reportNotice("Saved layout version \(version) is newer; a separate temporary view was opened")
        case nil:
            break
        }
        switch model.connect() {
        case .success:
            model.launchDefaultRuntimeIfEmpty()
        case .failure:
            session.close()
            throw ValidationError("workspace host is not reachable")
        }
        let savePump = WorkspaceLayoutSavePump(model: model, layout: openedLayout.session) { message in
            model.reportNotice(message)
        }
        // Every view-changing reduce wakes the saver immediately, so a
        // crash or SIGKILL cannot strand a binding that was already live
        // on screen. The pump's poll tick remains as a backstop.
        model.setViewChangedHook { [weak savePump] in savePump?.kick() }
        // Bindings and structure commit on the reducing thread itself: any
        // binding visible on screen is already fsync'd to disk, so even a
        // SIGKILL between the reduce and the next frame loses nothing.
        model.setDurableViewChangedHook { [weak savePump] view in savePump?.saveSync(view) }
        savePump.start()
        do {
            try await WorkspaceTUILaunch.run(model)
        } catch {
            model.detachSession()
            if let saveError = savePump.stop() {
                FileHandle.standardError.write(Data((saveError + "\n").utf8))
            }
            throw error
        }
        if let saveError = savePump.stop() {
            throw ValidationError(saveError)
        }
        #endif
    }

    #if os(macOS)
    static func launcherChoices(
        path: String = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin",
        isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }
    ) -> [RuntimeLaunchChoice] {
        // The sandbox cannot see user dotfiles, so zsh starts with default
        // options, including PROMPT_SP (stray `%` lines). Preset it off for
        // the default shell only; a workspace-local .zshrc still overrides.
        // Plain sh has no such option and takes no arguments.
        let zshPath = "/bin/zsh"
        let shellExecutable = isExecutable(zshPath) ? zshPath : "/bin/sh"
        let shellArguments = shellExecutable == zshPath ? ["-o", "NO_PROMPT_SP"] : []
        var choices = [
            RuntimeLaunchChoice(
                id: "shell",
                title: "shell",
                executable: shellExecutable,
                arguments: shellArguments,
                hook: nil
            ),
            RuntimeLaunchChoice(
                id: "run",
                title: "Run command…",
                executable: "",
                arguments: [],
                hook: nil
            ),
        ]
        for name in RuntimeAgentEntries.known {
            guard let executable = executable(named: name, path: path, isExecutable: isExecutable) else {
                continue
            }
            choices.append(RuntimeLaunchChoice(
                id: name,
                title: name,
                executable: executable,
                arguments: [],
                hook: nil
            ))
        }
        return choices
    }

    /// Operator policy for this account. Any failure reads as an empty policy;
    /// the launcher below then stays exactly as without a policy file.
    static func loadResourceProfiles(home: HomeDirectory? = HomeDirectory.process()) -> RuntimeResourcePolicy {
        guard let home else { return .empty }
        switch RuntimeResourcePolicyStore.load(from: RVPolicyPaths.configDirectory(home: home)) {
        case .success(let policy):
            return policy
        case .failure:
            return .empty
        }
    }

    /// Derive launcher choices from resource profiles. The host still enforces:
    /// this only proposes IDs the server re-validates per launch, so a stale
    /// read degrades to the server's "resource profile unavailable" refusal.
    /// A profile claims an agent entry through its `agents` marks, or through
    /// its executable-link names when the marks are empty (legacy). An agent
    /// entry keeps its host-resolved executable unless exactly one eligible
    /// profile claims it; then the choice runs under that profile, using the
    /// profile's link target when one exists, which is what makes
    /// wrapper-based agents work. Marked names with no base entry derive
    /// their own rows, so new agents never need source edits. Profiled
    /// agent rows also carry their id as the hook wire (hook protocol
    /// when the id names a HookHost, staging-only otherwise); the mark
    /// is operator declaration, not executable inference. With a
    /// policy in force the hardcoded agent rows are fallback-only:
    /// unclaimed entries drop, while ambiguous ones stay direct so a
    /// misconfigured overlap never silently removes a row. Shells gain
    /// one variant per eligible profile, sorted by id with the operator
    /// default first; the plain shell and the run box stay profile-less.
    static func applyingResourceProfiles(
        _ choices: [RuntimeLaunchChoice],
        profiles: [RuntimeResourceProfile],
        project: String,
        defaultProfile: String? = nil
    ) -> [RuntimeLaunchChoice] {
        let eligible = profiles.filter { $0.projects.contains(project) }
        guard eligible.isEmpty == false else { return choices }
        var enriched: [RuntimeLaunchChoice] = []
        enriched.reserveCapacity(choices.count)
        for choice in choices {
            guard choice.id != "shell", choice.id != "run" else {
                enriched.append(choice)
                continue
            }
            let matches = eligible.filter { Self.claimsAgent(choice.id, profile: $0) }
            guard matches.count == 1, let match = matches.first else {
                if matches.count > 1 { enriched.append(choice) }
                continue
            }
            var next = choice
            if let link = match.executableLinks.first(where: { $0.name == choice.id }) {
                next.executable = link.target
            }
            next.resourceProfileID = match.id
            next.title = "\(choice.title) · \(match.id)"
            next.hook = next.hook ?? choice.id
            enriched.append(next)
        }
        var candidates: [String: [(profile: RuntimeResourceProfile, target: String)]] = [:]
        for profile in eligible {
            for mark in profile.agents {
                guard mark != "shell", mark != "run",
                    enriched.contains(where: { $0.id == mark }) == false,
                    let link = profile.executableLinks.first(where: { $0.name == mark })
                else { continue }
                candidates[mark, default: []].append((profile, link.target))
            }
        }
        for mark in candidates.keys.sorted() {
            guard let sole = candidates[mark], sole.count == 1 else { continue }
            enriched.append(RuntimeLaunchChoice(
                id: mark,
                title: "\(mark) · \(sole[0].profile.id)",
                executable: sole[0].target,
                arguments: [],
                hook: mark,
                resourceProfileID: sole[0].profile.id
            ))
        }
        guard let shell = enriched.first(where: { $0.id == "shell" }) else { return enriched }
        for profile in eligible.sorted(by: { Self.shellVariantPrecedes($0, $1, defaultProfile: defaultProfile) }) {
            let suffix = profile.id == defaultProfile ? " (default)" : ""
            enriched.append(RuntimeLaunchChoice(
                id: "shell:\(profile.id)",
                title: "\(shell.title) · \(profile.id)\(suffix)",
                executable: shell.executable,
                arguments: shell.arguments,
                hook: shell.hook,
                resourceProfileID: profile.id
            ))
        }
        return enriched
    }

    /// Whether a profile serves an agent launcher entry. Non-empty marks win
    /// over link names; empty marks preserve the legacy link-name behavior.
    private static func claimsAgent(_ entryID: String, profile: RuntimeResourceProfile) -> Bool {
        if profile.agents.isEmpty {
            return profile.executableLinks.contains { $0.name == entryID }
        }
        return profile.agents.contains(entryID)
    }

    /// Shell variants sort by id with the operator default first. An unknown
    /// or ineligible default matches nothing and is ignored silently.
    private static func shellVariantPrecedes(
        _ left: RuntimeResourceProfile, _ right: RuntimeResourceProfile, defaultProfile: String?
    ) -> Bool {
        switch (left.id == defaultProfile, right.id == defaultProfile) {
        case (true, false): true
        case (false, true): false
        default: left.id < right.id
        }
    }

    private static func executable(
        named name: String,
        path: String,
        isExecutable: (String) -> Bool
    ) -> String? {
        for entry in path.split(separator: ":") {
            guard entry.hasPrefix("/") else { continue }
            let candidate = URL(fileURLWithPath: String(entry), isDirectory: true)
                .appendingPathComponent(name).path
            if isExecutable(candidate) { return candidate }
        }
        return nil
    }
    #endif
}
