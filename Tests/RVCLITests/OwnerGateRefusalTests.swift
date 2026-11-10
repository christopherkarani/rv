import ArgumentParser
import Foundation
import Testing
import RVIPC
import RVPolicy
@testable import RVCLI

struct OwnerGateRefusalTests {
    private static let allowOnce: [(AllowOnceError, OwnerGateRefusal?)] = [
        (.ttyRequired, .ttyRequired),
        (.robotRefused, .robotRefused),
        (.redemptionChanged, .changedDuringReview),
        (.lockFailed, .storeUnavailable),
        (.encodeFailed, .storeUnavailable),
        (.collision, .storeUnavailable),
        (.unknownCode, nil),
        (.expired, nil),
        (.alreadySpent, nil),
        (.alreadyPending, nil),
        (.emptyCommand, nil),
        (.notUnlockable, nil),
    ]

    @Test(arguments: allowOnce)
    func allowOnceErrorsClassify(error: AllowOnceError, expected: OwnerGateRefusal?) {
        #expect(OwnerGateRefusal(error) == expected)
    }

    @Test func authErrorsClassify() {
        #expect(OwnerGateRefusal(AllowOnceAuthError.required) == .authRequired)
        #expect(OwnerGateRefusal(AllowOnceAuthError.throttled) == .throttled)
    }

    @Test func egressErrorsClassify() {
        #expect(OwnerGateRefusal(EgressReviewError.storeUnavailable) == .storeUnavailable)
        #expect(OwnerGateRefusal(EgressReviewError.unknownProposal) == nil)
        #expect(OwnerGateRefusal(EgressReviewError.notAwaiting("expired")) == nil)
        #expect(OwnerGateRefusal(EgressReviewError.notNetworkProposal) == nil)
        #expect(OwnerGateRefusal(EgressReviewError.reasonRequired) == nil)
    }

    private static let declined = ConfirmOwnerActionReply(outcome: .declined)

    /// rvd's owner-check refusals for allow-once redeem/mint (#566) are gate
    /// refusals; reachability and caller-identity failures stay site-worded.
    @Test func attestErrorsClassify() {
        #expect(OwnerGateRefusal(AllowOnceAttestError.notApproved(Self.declined)) == .notApproved(Self.declined))
        #expect(OwnerGateRefusal(AllowOnceAttestError.notShowable) == .notShowable)
        #expect(OwnerGateRefusal(AllowOnceAttestError.ownerCheckUnconfirmed) == .ownerCheckUnconfirmed)
        #expect(OwnerGateRefusal(AllowOnceAttestError.notIssuedByService) == .notIssuedByService)
        #expect(OwnerGateRefusal(AllowOnceAttestError.serviceUnavailable) == nil)
        #expect(OwnerGateRefusal(AllowOnceAttestError.serviceDenied) == nil)
    }

    @Test func allowlistLockFailureClassifies() {
        #expect(OwnerGateRefusal(AllowlistStoreError.lockFailed) == .storeUnavailable)
    }

    @Test func foreignErrorsAreNotGateRefusals() {
        #expect(OwnerGateRefusal(ExitCode(1)) == nil)
        #expect(OwnerGateRefusal(ValidationError("x")) == nil)
        #expect(OwnerGateRefusal(CocoaError(.fileNoSuchFile)) == nil)
    }

    private static let golden: [(OwnerGateRefusal, OwnerGateRefusal.Subject, String)] = [
        (.ttyRequired, .grant, "requires an interactive TTY (stdin and stdout)"),
        (.ttyRequired, .proposal, "requires an interactive TTY (stdin and stdout)"),
        (.ttyRequired, .allowlistEntry, "requires an interactive TTY (stdin and stdout)"),
        (.robotRefused, .grant, "--json/--robot refused"),
        (.robotRefused, .proposal, "--json/--robot refused"),
        (.robotRefused, .allowlistEntry, "--json/--robot refused"),
        (.changedDuringReview, .grant, "grant changed during review; retry with a fresh code"),
        (.changedDuringReview, .proposal, "proposal changed during review; retry"),
        (.changedDuringReview, .allowlistEntry, "allowlist entry changed during review; retry"),
        (.authRequired, .grant, "device-owner authentication required"),
        (.authRequired, .proposal, "device-owner authentication required"),
        (.authRequired, .allowlistEntry, "device-owner authentication required"),
        (.throttled, .grant, "too many authentication prompts; wait and retry"),
        (.throttled, .proposal, "too many authentication prompts; wait and retry"),
        (.throttled, .allowlistEntry, "too many authentication prompts; wait and retry"),
        (.storeUnavailable, .grant, "store unavailable"),
        (.storeUnavailable, .proposal, "store unavailable"),
        (.storeUnavailable, .allowlistEntry, "store unavailable"),
        (.storeUnavailable, .newCode, "store unavailable"),
        (.ttyRequired, .newCode, "requires an interactive TTY (stdin and stdout)"),
        (.robotRefused, .newCode, "--json/--robot refused"),
        (.changedDuringReview, .newCode, "grant changed during review; retry with a fresh code"),
        (.authRequired, .newCode, "device-owner authentication required"),
        (.throttled, .newCode, "too many authentication prompts; wait and retry"),
    ] + attestGolden

    /// #566's wording, unchanged: redeem (`.grant`) and mint (`.newCode`)
    /// differ only where #566 worded them differently.
    private static let notShowableText =
        "this command is too long to approve in a prompt (it cannot be shown in full, and nothing is approved from a shortened view); nothing was allowed. Run it yourself in a terminal instead"
    private static let unconfirmedText =
        "rvd did not say it checked the owner (an older rvd still running after an upgrade?); nothing was allowed. Run rv service restart and try again"
    private static let notIssuedText =
        "rvd did not issue this code (rvd restarted since it issued it, or the pending file was edited); rerun the command for a fresh code"
    private static let mintDeniedText =
        "rvd refused to pre-arm a code (it could not identify the caller, or it is older than this rv: restart it); nothing was minted"
    private static let attestGolden: [(OwnerGateRefusal, OwnerGateRefusal.Subject, String)] =
        OwnerGateRefusal.Subject.allCases.flatMap { subject -> [(OwnerGateRefusal, OwnerGateRefusal.Subject, String)] in
            let mint = subject == .newCode
            return [
                (.notShowable, subject, notShowableText),
                (.ownerCheckUnconfirmed, subject, unconfirmedText),
                (.notIssuedByService, subject, mint ? mintDeniedText : notIssuedText),
                (.notApproved(declined), subject, mint
                    ? "not approved (the Touch ID or password prompt was cancelled, failed or timed out); nothing was minted"
                    : "not approved (the Touch ID or password prompt was cancelled, failed or timed out); the code stays live"),
                (.notApproved(ConfirmOwnerActionReply(outcome: .wrongPassword)), subject, mint
                    ? "wrong password; nothing was minted"
                    : "wrong password; nothing was allowed and the code stays live"),
                (.notApproved(ConfirmOwnerActionReply(outcome: .lockedOut, retryAfterSeconds: 120)), subject,
                    "too many failed owner checks; owner approvals are locked. Try again in 3 min."),
            ]
        }

    /// One value per refusal case (payload cases once). `text(subject:)` is
    /// an exhaustive switch, so a new case does not compile until worded;
    /// this list makes the golden table cover it too.
    private static let everyRefusal: [OwnerGateRefusal] = [
        .ttyRequired, .robotRefused, .changedDuringReview, .authRequired, .throttled, .storeUnavailable,
        .notShowable, .ownerCheckUnconfirmed, .notIssuedByService, .notApproved(declined),
    ]

    @Test(arguments: golden)
    func goldenText(refusal: OwnerGateRefusal, subject: OwnerGateRefusal.Subject, text: String) {
        #expect(refusal.text(subject: subject) == text)
        #expect(refusal.message(command: "allow-once mint", subject: subject) == "rv allow-once mint: \(text)\n")
        #expect(OwnerGateRefusal.exitCode == 2)
    }

    @Test func goldenTableCoversEveryRefusalAndSubject() {
        for refusal in Self.everyRefusal {
            for subject in OwnerGateRefusal.Subject.allCases {
                #expect(Self.golden.contains { $0.0 == refusal && $0.1 == subject })
            }
        }
    }

    /// `changedDuringReview` words itself by subject (redeem reads "grant",
    /// egress approve/deny read "proposal", allowlist reads "allowlist entry").
    /// No CLI seam can change a row between the pre-auth read and the re-read,
    /// so a run test cannot reach that text. The site-to-subject wiring is
    /// pinned at the source instead, the way `WorkspaceOwnershipTests` pins
    /// ownership: adding, dropping or re-subjecting a site fails here.
    @Test func everyCeremonySitePassesItsSubject() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/RVCLI", isDirectory: true)
        let call = try NSRegularExpression(
            pattern: #"failOwnerGate\(\s*error,\s*command:\s*"([^"]+)",\s*subject:\s*\.(\w+)\s*\)"#
        )
        var wired: [String] = []
        var calls = 0
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        while let url = files.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let body = try String(contentsOf: url, encoding: .utf8)
            calls += body.components(separatedBy: ".failOwnerGate(").count - 1
            let whole = NSRange(body.startIndex..., in: body)
            for match in call.matches(in: body, range: whole) {
                let command = try #require(Range(match.range(at: 1), in: body))
                let subject = try #require(Range(match.range(at: 2), in: body))
                wired.append("\(body[command]) -> \(body[subject])")
            }
        }
        #expect(calls == wired.count, "a failOwnerGate call does not use the literal (error, command:, subject:) shape")
        #expect(wired.sorted() == [
            "allow-once -> grant",
            "allow-once clear -> grant",
            "allow-once mint -> newCode",
            "allowlist add -> allowlistEntry",
            "allowlist add-command -> allowlistEntry",
            "allowlist remove -> allowlistEntry",
            "egress approve -> proposal",
            "egress deny -> proposal",
            "egress pending -> proposal",
        ])
    }

    @Test func failOwnerGateMapsGateErrorToExit2WithText() throws {
        let out = CLIOutputCapture()
        try withCLIProcess(output: out) {
            let ctx = CommandContext.current(command: "egress approve", json: false, robot: false, plain: false, noColor: false)
            #expect(throws: ExitCode(2)) {
                try ctx.failOwnerGate(AllowOnceAuthError.throttled, command: "egress approve", subject: .proposal)
            }
        }
        #expect(out.stderr == "rv egress approve: too many authentication prompts; wait and retry\n")
    }

    @Test func failOwnerGateRethrowsOtherErrorsUnchanged() throws {
        let out = CLIOutputCapture()
        try withCLIProcess(output: out) {
            let ctx = CommandContext.current(command: "allow-once", json: false, robot: false, plain: false, noColor: false)
            #expect(throws: ExitCode(7)) {
                try ctx.failOwnerGate(ExitCode(7), command: "allow-once", subject: .grant)
            }
            #expect(throws: CocoaError.self) {
                try ctx.failOwnerGate(CocoaError(.fileNoSuchFile), command: "allow-once", subject: .grant)
            }
        }
        #expect(out.stderr.isEmpty)
    }
}
