import ArgumentParser
import Foundation
import RVDomain
import RVPolicy
import RVPresentation

/// What rvd said about its typed-policy load, or why it said nothing.
enum PolicyStatusObservation: Sendable, Equatable {
    case rvd(PolicyLoadStatus)
    /// Operator-facing reason, with no peer-supplied detail.
    case unavailable(String)
}

/// One status request for `cwd`, bounded by the given timeout.
typealias PolicyStatusSource = @Sendable (WorkingDirectory?, Duration) async -> PolicyStatusObservation

/// `rv policy status [--json]`: whether rvd loads the current machine and
/// repo policy, and which revisions. rvd answers from its own load (the
/// one hooks run), so a CLI with another HOME, binary or file access
/// cannot report a load rvd does not have. When rvd cannot answer, the
/// CLI runs the same load itself and says so.
struct PolicyStatusCommand: AsyncParsableCommand, CommandUsage {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Show whether rvd loads the current machine and repo policy."
    )

    static let usage = [
        HelpRow(name: "rv policy status [--json]"),
    ]

    @OptionGroup
    var format: FormatFlags

    func run() async throws {
        let ctx = CommandContext.current(command: "policy status", format: format)
        let home = try ctx.requireHome()
        let workspace = URL(fileURLWithPath: CLIProcess.workspacePath(), isDirectory: true)
        let session = PolicyWorkspace(home: home, workspace: workspace)
        let observation = await PolicyStatusRun.source()(
            WorkingDirectory(validating: workspace.path), PolicyStatusRun.callTimeout)
        let report = PolicyStatusRun.report(observation, session: session)
        if ctx.explicitRobot {
            do {
                ctx.writeStdout(try RobotJSON.encode(report) + "\n")
            } catch {
                try ctx.fail("rv policy status: encode failed\n")
            }
        } else {
            ctx.writeStdout(PolicyStatusRun.pretty(report))
        }
        if let code = PolicyStatusRun.exitCode(report) {
            throw ExitCode(code)
        }
    }
}

/// `rv policy status` robot document.
struct PolicyStatusReport: Sendable, Equatable, Codable {
    enum Source: String, Sendable, Equatable, Codable {
        /// rvd's own load: what hooks enforce.
        case rvd
        /// rvd could not answer; this CLI ran the same load from its HOME.
        case local
    }

    struct Layer: Sendable, Equatable, Codable {
        var hash: String
        var rules: Int
        var exceedsCeiling: Bool
        /// Newest logged revision with this document's hash; nil when the
        /// live file matches none (a hand edit) or the layer has no log.
        var revision: Int?
        var head: Int?
        /// Why the revision log could not be read; it does not affect loading.
        var logError: String?
    }

    var source: Source
    var rvdUnavailable: String?
    var state: PolicyLoadStatus.State
    var failure: PolicyLoadStatus.Failure?
    var problem: PolicyLoadStatus.Problem?
    var reason: String?
    var machine: Layer?
    var repo: Layer?
    var ceilingRules: Int?
    var effectiveRules: Int?
    var configDirectory: String?
    var workspace: String?
    /// This CLI's config directory when it differs from the one rvd read.
    var cliConfigDirectory: String?
}

enum PolicyStatusRun {
    /// One request's bound: a containment check over a large repo layer
    /// can take seconds.
    static let callTimeout: Duration = .milliseconds(ServiceClient.policyStatusTimeoutMs)

    /// Exit 3 when rvd did not answer: the report is this CLI's own load
    /// and nothing confirms rvd enforces it, so `rv policy status && …`
    /// must not pass. Otherwise exit 1 when the load fails.
    static let rvdUnavailableExitCode: Int32 = 3

    static func exitCode(_ report: PolicyStatusReport) -> Int32? {
        if report.source == .local { return rvdUnavailableExitCode }
        return report.state == .failed ? 1 : nil
    }

    /// rvd's answer. An installed CLI context (tests) never reaches the
    /// live daemon: its seam, or "unavailable".
    static func source() -> PolicyStatusSource {
        if let context = CLIProcess.context {
            return context.policyStatusSource ?? { _, _ in .unavailable("rvd is not reachable from this context") }
        }
        let client = ServiceClient.probing(home: CLIProcess.home())
        return { cwd, timeout in await client.policyStatus(cwd: cwd, timeout: timeout) }
    }

    static func report(_ observation: PolicyStatusObservation, session: PolicyWorkspace) -> PolicyStatusReport {
        let status: PolicyLoadStatus
        let source: PolicyStatusReport.Source
        var unavailable: String?
        switch observation {
        case .rvd(let answered):
            status = answered
            source = .rvd
        case .unavailable(let why):
            status = session.loadStatus()
            source = .local
            unavailable = why
        }
        let cliConfig = session.home.map { RVPolicyPaths.configDirectory(home: $0).path }
        return PolicyStatusReport(
            source: source,
            rvdUnavailable: unavailable,
            state: status.state,
            failure: status.failure,
            problem: status.problem,
            reason: reason(status),
            machine: status.machine.map { layer($0, .machine, session) },
            repo: status.repo.map { layer($0, .repo, session) },
            ceilingRules: status.ceilingRuleCount,
            effectiveRules: status.effectiveRuleCount,
            configDirectory: status.configDirectory,
            workspace: status.workspace,
            cliConfigDirectory: cliConfig == status.configDirectory ? nil : cliConfig
        )
    }

    /// The failing step and, when known, why its file was refused.
    static func reason(_ status: PolicyLoadStatus) -> String? {
        guard let failure = status.failure else { return nil }
        let base = reason(failure)
        guard let problem = status.problem else { return base }
        return "\(base): \(detail(problem, failure))"
    }

    static func reason(_ failure: PolicyLoadStatus.Failure) -> String {
        switch failure {
        case .machineInvalid: "machine policy.toml cannot be read or parsed"
        case .repoInvalid: "repo .rv/policy.toml cannot be read or parsed"
        case .ceilingInvalid: "the policy ceiling (ceiling.toml) cannot be read or parsed"
        }
    }

    private static func detail(_ problem: PolicyLoadStatus.Problem, _ failure: PolicyLoadStatus.Failure) -> String {
        switch problem {
        case .notRegularFile: "not a regular file"
        case .symlink: "a symlink, which is never followed for the ceiling"
        case .tooLarge: failure == .ceilingInvalid ? "larger than 256 KiB" : "larger than 1 MiB"
        case .notUTF8: "not UTF-8"
        case .unreadable: "unreadable"
        case .unparseable: "not a valid policy document"
        }
    }

    /// Maps the loaded hash onto this CLI's revision log. A log failure is
    /// reported beside the load, never as one: evaluation does not read it.
    private static func layer(
        _ loaded: PolicyLoadStatus.Layer, _ which: PolicyDocumentLayer, _ session: PolicyWorkspace
    ) -> PolicyStatusReport.Layer {
        var layer = PolicyStatusReport.Layer(
            hash: loaded.hash, rules: loaded.ruleCount, exceedsCeiling: loaded.exceedsCeiling)
        do {
            let revisions = try session.listRevisions(layer: which)
            layer.head = revisions.last?.revision
            layer.revision = revisions.last { $0.hash == loaded.hash }?.revision
        } catch TypedRuleStoreError.logCorrupted {
            layer.logError = "revision log failed verification"
        } catch TypedRuleStoreError.logMissing {
            layer.logError = "revision log is missing"
        } catch {
            layer.logError = "revision log unreadable"
        }
        return layer
    }

    static func pretty(_ report: PolicyStatusReport) -> String {
        var lines: [String] = []
        let view = switch report.source {
        case .rvd: "as rvd evaluates it"
        case .local: "this CLI's view; rvd unavailable: \(report.rvdUnavailable ?? "unknown")"
        }
        lines.append("policy: \(report.state.rawValue) (\(view))")
        if let reason = report.reason {
            lines.append("reason: \(reason)")
            lines.append(
                "Every evaluation denies (typed-rules-invalid) until it is fixed;"
                    + " rv does not fall back to an earlier policy.")
        }
        if let machine = report.machine { lines.append("machine: \(describe(machine))") }
        if let repo = report.repo { lines.append("repo:    \(describe(repo))") }
        if report.state == .loaded {
            lines.append("ceiling: \(report.ceilingRules.map(rules) ?? "none")")
            if let effective = report.effectiveRules { lines.append("effective rules: \(effective)") }
        }
        if let cli = report.cliConfigDirectory {
            lines.append(
                "note: rvd reads \(DisplayedText.field(report.configDirectory ?? "no config directory"));"
                    + " this shell's HOME gives \(DisplayedText.field(cli))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func rules(_ count: Int) -> String {
        "\(count) rule\(count == 1 ? "" : "s")"
    }

    private static func describe(_ layer: PolicyStatusReport.Layer) -> String {
        var text: String
        switch (layer.revision, layer.head) {
        case (let revision?, let head?) where revision == head:
            text = "r\(revision)"
        case (let revision?, let head?):
            text = "r\(revision) (head r\(head))"
        case (nil, let head?):
            text = "unrecorded edit sha256:\(layer.hash.prefix(12)) (head r\(head))"
        default:
            text = layer.rules == 0 ? "empty" : "sha256:\(layer.hash.prefix(12)) (no revisions)"
        }
        text += ", \(rules(layer.rules))"
        if layer.exceedsCeiling {
            text += "; exceeds the ceiling, whose verdict holds at evaluation"
        }
        if let logError = layer.logError {
            text += "; \(logError)"
        }
        return text
    }
}

/// `--wait` / `--wait-timeout` for policy saves.
struct PolicyWaitFlags: ParsableArguments {
    @Flag(name: .customLong("wait"), help: "With --save: wait until rvd evaluates with the saved policy.")
    var wait = false

    @Option(name: .customLong("wait-timeout"), help: "Seconds --wait waits for rvd (1-300, default 10).")
    var waitTimeout: Int?

    static let defaultTimeoutSeconds = 10

    func check(save: Bool) throws {
        if wait, save == false {
            throw ValidationError("--wait applies only with --save")
        }
        if let waitTimeout {
            guard wait else { throw ValidationError("--wait-timeout applies only with --wait") }
            guard (1...300).contains(waitTimeout) else {
                throw ValidationError("--wait-timeout must be 1 to 300 seconds")
            }
        }
    }

    var timeout: Duration { .seconds(waitTimeout ?? Self.defaultTimeoutSeconds) }
}

/// Polls rvd until it loads the saved layer document. rvd re-reads policy
/// on every evaluation, so this normally returns on the first answer; it
/// waits only while rvd is unreachable or still reports another document.
enum PolicyLoadWait {
    enum Outcome: Sendable, Equatable {
        /// rvd loads `hash` for the layer: the next evaluation enforces it.
        case loaded
        /// rvd reached a load that fails: every evaluation denies.
        case failed(PolicyLoadStatus)
        /// The deadline passed; the last observation says why.
        case timedOut(PolicyStatusObservation?)
    }

    /// `clock` measures the deadline and paces polls; tests pass one that
    /// moves only when the wait sleeps.
    static func run<C: Clock<Duration>>(
        layer: PolicyDocumentLayer,
        hash: String,
        cwd: WorkingDirectory?,
        timeout: Duration,
        pollInterval: Duration = .milliseconds(200),
        callTimeout: Duration = PolicyStatusRun.callTimeout,
        clock: C = ContinuousClock(),
        observe: PolicyStatusSource
    ) async -> Outcome {
        let deadline = clock.now.advanced(by: timeout)
        var last: PolicyStatusObservation?
        while true {
            // Each call gets only what is left, so a slow answer cannot
            // carry the wait past --wait-timeout. No call starts at the
            // deadline: it could only fail and hide the last real answer.
            let remaining = clock.now.duration(to: deadline)
            guard remaining > .zero else { return .timedOut(last) }
            let observation = await observe(cwd, min(callTimeout, remaining))
            last = observation
            if case .rvd(let status) = observation {
                if status.state == .failed {
                    return .failed(status)
                }
                let loaded = layer == .machine ? status.machine : status.repo
                if loaded?.hash == hash {
                    return .loaded
                }
            }
            try? await Task.sleep(until: min(clock.now.advanced(by: pollInterval), deadline), clock: clock)
        }
    }

    /// Runs the wait after a save and reports it: one stdout line when rvd
    /// loads it (none in robot mode), else exit 1. The save stands either way.
    static func confirm(
        command: String,
        layer: PolicyDocumentLayer,
        hash: String,
        flags: PolicyWaitFlags,
        robot: Bool
    ) async throws {
        guard flags.wait else { return }
        let outcome = await run(
            layer: layer,
            hash: hash,
            cwd: WorkingDirectory(validating: URL(fileURLWithPath: CLIProcess.workspacePath(), isDirectory: true).path),
            timeout: flags.timeout,
            observe: PolicyStatusRun.source()
        )
        let name = layer == .machine ? "machine" : "repo"
        switch outcome {
        case .loaded:
            if robot == false {
                CommandContext.writeStdout("rvd loaded the saved \(name) policy\n")
            }
        case .failed(let status):
            let reason = PolicyStatusRun.reason(status) ?? "load failed"
            try CommandContext.fail(
                "rv \(command): saved, but rvd cannot load policy: \(reason);"
                    + " every evaluation denies until it is fixed\n")
        case .timedOut(let last):
            let detail: String = switch last {
            case .unavailable(let why)?: why
            case .rvd?: "rvd still reports another \(name) policy"
            case nil: "no answer"
            }
            let seconds = flags.waitTimeout ?? PolicyWaitFlags.defaultTimeoutSeconds
            try CommandContext.fail(
                "rv \(command): saved, but rvd did not confirm it within \(seconds)s (\(detail))\n")
        }
    }
}
