import Foundation
import RVDomain
import Testing
@testable import RVCLI

/// L3: every way `rv box` can fail to start is one line why and one fix.
@Suite("rv box start failures read as one line and one fix")
struct BoxStartFailureTests {
    /// The workspace host's own words for each start failure, as
    /// `WorkspaceCommandRun` writes them on macOS (copied here so the
    /// mapping is checked on every platform; `BoxStartFailureMacTests`
    /// walks the real enums on the Mac).
    static let hostMessages = [
        "the workspace host was refused: the installed workspace host is not pinned to this build; any host this start launched was stopped; run 'rv doctor', and 'rv workspace leftovers' for anything it left",
        "the workspace host did not answer within 15 s; any host this start launched was stopped; run 'rv doctor', and 'rv workspace leftovers' for anything it left",
        "workspace host did not become ready in time; the host this start launched was stopped; run 'rv doctor', and 'rv workspace leftovers' for anything it left",
        "workspace host did not become ready in time; run 'rv workspace status' to check it, or 'rv doctor' if it persists",
        "the workspace host this start launched is still mounting or recovering; it keeps running in the background — run 'rv workspace status' to see when it is ready, then 'rv workspace start' again to attach",
        "the workspace host is still mounting or recovering",
        "workspace path is unusable",
        "home directory cannot be a workspace root; pass --workspace <project directory>",
        "workspace host executable is missing",
        "workspace host failed to start",
        "workspace host endpoint is unavailable",
        "workspace host did not become ready",
        "workspace host did not become ready and was stopped",
        "workspace host failed",
        "workspace host is not reachable; run 'rv workspace status' to check its state, or 'rv doctor' if it stays unreachable",
        "stale endpoint: the saved endpoint could not be used; this check did not change the volume or saved tree — run 'rv workspace status' to re-check, or 'rv doctor' if it persists",
        "recovery blocked: publicationConflict: run 'rv workspace status' for state, or 'rv workspace abandon' to restore the saved tree and keep the volume as a detached disk image",
        "recovery blocked: missingVolume: the volume is already absent (for example after a logout or reboot) and the saved tree is untouched; its disk image can still hold unpublished work: run 'rv workspace abandon' to restore the saved tree and keep that image (it prints the image path and the hdiutil command to copy files out), or 'rv workspace status' for state",
        "recovery blocked: tornLog: abandon will refuse; run 'rv workspace status' and 'rv doctor' for state",
        "workspace recovery is required: run 'rv workspace status' for state; run 'rv workspace abandon' only when that status is publicationConflict or missingVolume",
        "runtime resource profile 'claude-app' is unavailable for this project",
        "runtime resource profile 'claude-app' staging failed: ~/.claude.json is unusable",
        "runtime resource profile is unavailable",
        "runtime resource staging failed: ~/.claude.json is unusable",
        "incompatible workspace protocol; close the workspace and retry (rv workspace close)",
        "unauthorized workspace client",
        "workspace is closing",
        "workspace is closed",
        "workspace runtime limit reached",
        "workspace host client queue is overloaded",
        "workspace host timed out",
        "workspace host disconnected",
        "workspace host rejected the request",
        "invalid workspace request",
        "command exceeds the workspace control limit (256 arguments, 4096 bytes each, 65536 bytes total)",
        "operator permits not yet available",
        "runtime teardown failed",
        "runtime not found",
        "runtime has no terminal",
        "terminal input is owned by another client",
        "terminal subscriber limit reached",
        "terminal input was partially written",
        "terminal client fell behind",
        "terminal output closed",
        "terminal size is out of range",
        "contained workspace host is unavailable on this platform; run 'rv doctor' to check the installation",
        ContainedRuntimeRefusal.message,
        WorkspaceCommandRun.hostNotReachableText,
    ]

    /// Each known message has its own entry (never the fallback), and
    /// every refusal is exactly two lines: `✕` or `◐` why, `→` fix.
    @Test(arguments: hostMessages)
    func eachKnownFailureIsOneLineAndOneFix(_ message: String) {
        let refusal = BoxStartFailure.refusal(message)
        #expect(BoxStartFailure.entries.contains { message.hasPrefix($0.prefix) }, "no entry for: \(message)")
        Self.expectOneLineOneFix(refusal)
    }

    /// The plain words the v4 frame asks for: no host jargon on the why.
    @Test(arguments: hostMessages)
    func noInternalWordsReachTheWhy(_ message: String) {
        let why = BoxStartFailure.refusal(message).why.lowercased()
        for word in ["endpoint", "peer-trust", "publicationconflict", "missingvolume", "runtime", "workspace host", "uuid"] {
            #expect(why.contains(word) == false, "\(word) in: \(why)")
        }
    }

    @Test func thePeerTrustRefusalIsTheV4Frame() {
        let refusal = BoxStartFailure.refusal(Self.hostMessages[0])
        #expect(refusal.text == """
            ✕ Boxes can't open on this Mac: the box helper's trust pin doesn't match this rv.
              → see the fix (it needs an administrator): rv doctor

            """)
    }

    @Test func aStillStartingBoxIsASetupStepNotAStop() {
        let refusal = BoxStartFailure.refusal(Self.hostMessages[4])
        #expect(refusal.text == """
            ◐ The box is still starting in the background.
              → run rv box again once it is ready: rv workspace status

            """)
    }

    /// A message no entry knows: its first clause and the first rv
    /// command it names, still one line each.
    @Test func anUnknownMessageStillGetsOneLineAndOneFix() {
        let named = BoxStartFailure.refusal("the moon is in the way; run 'rv box list' and then\nsomething else")
        #expect(named.text == "✕ The moon is in the way.\n  → rv box list\n")
        let bare = BoxStartFailure.refusal("weird — nothing else")
        #expect(bare.text == "✕ Weird.\n  → rv doctor\n")
        Self.expectOneLineOneFix(BoxStartFailure.refusal(""))
        Self.expectOneLineOneFix(BoxStartFailure.refusal("line one\nline two; 'rv x\ny'"))
    }

    /// `BoxPlan.hostRefusal` is the same catalog, so L1's callers changed
    /// nothing.
    @Test func hostRefusalUsesTheCatalog() {
        for message in Self.hostMessages {
            #expect(BoxPlan.hostRefusal(message) == BoxStartFailure.refusal(message))
        }
    }

    /// Every refusal the box front door itself can give, too.
    @Test func everyBoxRefusalIsOneLineAndOneFix() {
        var refusals: [BoxRefusal] = [
            BoxPlan.missingFolder, BoxPlan.noHome, BoxPlan.linuxHostRefusal, BoxPlan.shellNeedsTerminal,
        ]
        refusals += BoxStartFailure.entries.map(\.refusal)
        for refusal in refusals { Self.expectOneLineOneFix(refusal) }
    }

    static func expectOneLineOneFix(_ refusal: BoxRefusal, sourceLocation: SourceLocation = #_sourceLocation) {
        let lines = refusal.text.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count == 3 && lines[2].isEmpty, "\(refusal.text)", sourceLocation: sourceLocation)
        #expect(lines.first.map { $0.hasPrefix("✕ ") || $0.hasPrefix("◐ ") } == true, sourceLocation: sourceLocation)
        #expect(lines.dropFirst().first?.hasPrefix("  → ") == true, sourceLocation: sourceLocation)
        #expect(refusal.why.contains(";") == false, "two ideas: \(refusal.why)", sourceLocation: sourceLocation)
        let fix = refusal.fix ?? ""
        let command = fix.components(separatedBy: ": ").last ?? fix
        #expect(command.hasPrefix("rv ") || command.hasPrefix("cd ") || command.hasPrefix("reinstall rv")
                    || command.hasPrefix("guard agents"), "fix must end in a command: \(fix)",
                sourceLocation: sourceLocation)
    }
}
