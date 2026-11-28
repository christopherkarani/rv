import Foundation
import RVDomain

/// Every way a box can fail to start after `BoxPlan` resolved it, as one
/// line why and one fix (v4 Contained, "When it can't start, one line says
/// why"). The workspace host speaks `rv workspace`'s words; this reads
/// them by their opening clause and says the same thing plainly. A message
/// no entry knows gets a generic line and `rv doctor`: the host's own text
/// (which can carry paths and internal names) is shown only with
/// `rv box --verbose`, on a line of its own (`detail`).
///
/// Pure and cross-platform: the macOS shell (`BoxRun.runLaunch`) catches
/// the host's refusal and hands its text here.
enum BoxStartFailure {
    struct Entry: Sendable {
        /// The host message's opening words.
        var prefix: String
        var refusal: BoxRefusal
    }

    static let doctor = "rv doctor"
    private static let leftovers = "clear what it left: rv box tidy"
    private static let status = "rv workspace status"

    /// The trust-pin refusal (v4 Contained). `rv repair` does not exist
    /// yet, so the fix is `rv doctor`, which names the root-owned step.
    static let trustPin = BoxRefusal(
        why: "Boxes can't open on this Mac: the box helper's trust pin doesn't match this rv.",
        fix: "see the fix (it needs an administrator): rv doctor")

    /// Messages a stale trust pin can also cause: a host this rv refuses
    /// to talk to looks unreachable from here. With a trust reason in
    /// hand (the installed helper fails its peer-trust check), they read
    /// as the trust pin, not as an unreachable helper.
    static let trustSensitivePrefixes = [
        "workspace host is not reachable",
        "unauthorized workspace client",
        "the workspace host was refused",
    ]

    static func mayBeTrust(_ message: String) -> Bool {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trustSensitivePrefixes.contains { trimmed.hasPrefix($0) }
    }

    /// Longest prefixes first, so a specific message wins over a general
    /// one that starts the same way.
    static let entries: [Entry] = [
        // Ensure (`WorkspaceCommandRun.ensureFailureText`).
        Entry(prefix: "the workspace host was refused", refusal: trustPin),
        Entry(prefix: "the workspace host this start launched is still mounting or recovering", refusal: BoxRefusal(
            mark: .setup, why: "The box is still starting in the background.",
            fix: "run rv box again once it is ready: rv workspace status")),
        Entry(prefix: "the workspace host is still mounting or recovering", refusal: BoxRefusal(
            mark: .setup, why: "The box is still starting in the background.",
            fix: "run rv box again once it is ready: rv workspace status")),
        Entry(prefix: "the workspace host did not answer", refusal: BoxRefusal(
            why: "The box helper started but never answered, so rv stopped it.", fix: leftovers)),
        Entry(prefix: "workspace host did not become ready and was stopped", refusal: BoxRefusal(
            why: "The box took too long to start, so rv stopped it.", fix: leftovers)),
        Entry(prefix: "workspace host did not become ready in time; the host this start launched was stopped",
              refusal: BoxRefusal(why: "The box took too long to start, so rv stopped it.", fix: leftovers)),
        Entry(prefix: "workspace host did not become ready", refusal: BoxRefusal(
            why: "The box is taking longer than usual to start.", fix: "check on it: rv workspace status")),
        Entry(prefix: "workspace host executable is missing", refusal: BoxRefusal(
            why: "The box helper (rv-workspace-host) is missing from this install.", fix: "reinstall rv, then: rv doctor")),
        Entry(prefix: "workspace host failed to start", refusal: BoxRefusal(
            why: "The box helper could not start.", fix: doctor)),
        Entry(prefix: "workspace host endpoint is unavailable", refusal: BoxRefusal(
            why: "rv can't find where the box helper listens.", fix: doctor)),
        Entry(prefix: "workspace host failed", refusal: BoxRefusal(
            why: "The box helper quit while the box was starting.", fix: leftovers)),
        Entry(prefix: "workspace path is unusable", refusal: BoxRefusal(
            why: "This project folder can't hold a box.", fix: BoxPlan.elsewhere)),
        Entry(prefix: "home directory cannot be a workspace root", refusal: BoxRefusal(
            why: "Your home folder can't be a box: the box could read all of it.", fix: BoxPlan.elsewhere)),
        Entry(prefix: "workspace host is not reachable", refusal: BoxRefusal(
            why: "The box helper started but rv can't reach it.", fix: "check on it: rv workspace status")),
        Entry(prefix: "stale endpoint", refusal: BoxRefusal(
            why: "The box helper's address is out of date.", fix: "check again: rv workspace status")),

        // Recovery the box needs before it can open again.
        Entry(prefix: "recovery blocked: publicationConflict", refusal: BoxRefusal(
            why: "This box's last changes clash with the project and were kept apart.",
            fix: "see both copies: rv workspace status")),
        Entry(prefix: "recovery blocked: missingVolume", refusal: BoxRefusal(
            why: "This box's volume is gone after a logout or restart, but its last changes are kept in a disk image.",
            fix: "restore the project and keep that image: rv workspace abandon")),
        Entry(prefix: "recovery blocked", refusal: BoxRefusal(
            why: "This box's last session can't be recovered safely, so rv left both copies alone.",
            fix: "see why: rv workspace status")),
        Entry(prefix: "workspace recovery is required", refusal: BoxRefusal(
            why: "This box's last session never finished and must be recovered first.",
            fix: "see what it needs: rv workspace status")),

        // Launch (`WorkspaceCommandRun.text(WorkspaceClientFailure)`).
        Entry(prefix: "runtime resource profile '", refusal: BoxRefusal(
            why: "The profile for this box doesn't serve this project.",
            fix: "write one for this project: rv init")),
        Entry(prefix: "runtime resource profile is unavailable", refusal: BoxRefusal(
            why: "The profile for this box doesn't serve this project.",
            fix: "write one for this project: rv init")),
        Entry(prefix: "runtime resource staging failed", refusal: BoxRefusal(
            why: "A key or file the profile stages could not be copied into the box.",
            fix: "check the profile's keys: rv secrets list")),
        Entry(prefix: "incompatible workspace protocol", refusal: BoxRefusal(
            why: "The running box helper is from another rv version.",
            fix: "close it, then run rv box again: rv workspace close")),
        Entry(prefix: "unauthorized workspace client", refusal: trustPin),
        Entry(prefix: "workspace is closing", refusal: BoxRefusal(
            mark: .setup, why: "This box is closing.", fix: "run rv box again in a moment: rv workspace status")),
        Entry(prefix: "workspace is closed", refusal: BoxRefusal(
            mark: .setup, why: "This box just closed.", fix: "run rv box again in a moment: rv workspace status")),
        Entry(prefix: "workspace runtime limit reached", refusal: BoxRefusal(
            why: "This box already runs as many agents as it can.", fix: "see what runs there: rv box list")),
        Entry(prefix: "workspace host client queue is overloaded", refusal: BoxRefusal(
            why: "The box helper is too busy to take this start.", fix: "run rv box again in a moment: rv workspace status")),
        Entry(prefix: "workspace host timed out", refusal: BoxRefusal(
            why: "The box helper did not answer in time.", fix: "check on it: rv workspace status")),
        Entry(prefix: "workspace host disconnected", refusal: BoxRefusal(
            why: "The box helper hung up while the box was starting.", fix: "check on it: rv workspace status")),
        Entry(prefix: "workspace host rejected the request", refusal: BoxRefusal(
            why: "The box helper did not understand this start.", fix: doctor)),
        Entry(prefix: "invalid workspace request", refusal: BoxRefusal(
            why: "The box helper did not understand this start.", fix: doctor)),
        Entry(prefix: "command exceeds the workspace control limit", refusal: BoxRefusal(
            why: "That command line is too long for a box.", fix: "shorten it, or put it in a script: rv box -- ./script.sh",
            exitCode: 64)),
        Entry(prefix: "operator permits not yet available", refusal: BoxRefusal(
            why: "That kind of start is not available yet.", fix: "rv box --help")),
        Entry(prefix: "runtime teardown failed", refusal: BoxRefusal(
            why: "An earlier agent in this box did not stop cleanly.", fix: "check on it: rv workspace status")),
        Entry(prefix: "runtime not found", refusal: BoxRefusal(
            why: "The agent quit before its terminal opened.", fix: "run rv box again; if it repeats: rv doctor")),
        Entry(prefix: "runtime has no terminal", refusal: BoxRefusal(
            why: "The agent started without a terminal.", fix: "run rv box again; if it repeats: rv doctor")),
        Entry(prefix: "terminal input is owned by another client", refusal: BoxRefusal(
            why: "Another window is already typing into this box.", fix: "use that window, or close it: rv workspace close")),
        Entry(prefix: "terminal subscriber limit reached", refusal: BoxRefusal(
            why: "Too many windows are watching this box.", fix: "close one, then run rv box again: rv box list")),
        Entry(prefix: "terminal input was partially written", refusal: BoxRefusal(
            why: "The box stopped mid-keystroke.", fix: "run rv box again; if it repeats: rv doctor")),
        Entry(prefix: "terminal client fell behind", refusal: BoxRefusal(
            why: "This window could not keep up with the box's output.", fix: "run rv box again; if it repeats: rv doctor")),
        Entry(prefix: "terminal output closed", refusal: BoxRefusal(
            why: "The box's terminal closed before the agent started.", fix: "run rv box again; if it repeats: rv doctor")),
        Entry(prefix: "terminal size is out of range", refusal: BoxRefusal(
            why: "This window is too small or too large for a box.", fix: "resize it, then run rv box again: rv box")),
        Entry(prefix: "contained workspace host is unavailable", refusal: BoxPlan.linuxHostRefusal),
        Entry(prefix: "contained runtime is macOS-only today", refusal: BoxPlan.linuxHostRefusal),
    ].sorted { $0.prefix.count > $1.prefix.count }

    /// The refusal for a host message. `hostTrustReason`: why the
    /// installed box helper fails its peer-trust check, when it does
    /// (`WorkspaceCommandRun.currentHostTrustReason`).
    static func refusal(_ message: String, hostTrustReason: String? = nil) -> BoxRefusal {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        if hostTrustReason != nil, mayBeTrust(trimmed) { return trustPin }
        if let entry = entries.first(where: { trimmed.hasPrefix($0.prefix) }) { return entry.refusal }
        return fallback
    }

    /// A message no entry knows: never its text, which can carry paths,
    /// ids and commands meant for `rv workspace`.
    static let fallback = BoxRefusal(why: "The box could not start.", fix: doctor)

    /// `rv box --verbose`: the host's own words, on one line, with control
    /// characters made visible.
    static func detail(_ message: String) -> String {
        let oneLine = message.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline).joined(separator: " ")
        return "  host said: \(DisplayedText.field(oneLine))\n"
    }
}
