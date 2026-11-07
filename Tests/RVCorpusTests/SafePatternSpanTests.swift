import Testing
import RVDomain
import RVEngine

/// A safe pattern that matches the whole multi-segment view (the `rm-*-tmp`
/// family's `^(?:\S+\s+)*rm …` prefix spans `;`, `&&`, newlines) must not
/// suppress a same-pack destructive rule that only matches across segments.
/// The segment pass cannot see a cross-segment match, so the full-view pass
/// is its only chance.
@Suite("Safe pattern span")
struct SafePatternSpanTests {
    @Test(
        "cross-segment destructive match beats a spanning safe match",
        arguments: [
            ":(){ :|:& };:\nrm -rf /tmp/x",
            ":(){ :|:& };: && rm -rf /tmp/x",
            ":(){ :|:& };:\nset -euo p\"x && rm -rf /tmp/x",
            ":(){ :|:& };: ; rm -fr /tmp/x",
            ":(){ :|:& };: && sudo rm -r -f /tmp/x",
            ":(){ :|:& };: && rm --recursive --force /tmp/x",
            "rm -rf /tmp/x && :(){ :|:& };:",
        ]
    )
    func forkBombStaysDenied(_ command: String) throws {
        let harness = try StressHarness.dayOne()
        for result in [harness.pin(command), harness.door(command)] {
            #expect(describeDecision(result) == "deny core.filesystem:fork-bomb", "\(command)")
        }
    }

    @Test(
        "copy-then-delete chain behind a safe /tmp cleanup stays denied",
        arguments: [
            "rm -rf /tmp/x && /bin/cp -a /etc /tmp/s && rm -rf /tmp/s",
        ]
    )
    func copyThenDeleteStaysDenied(_ command: String) throws {
        let harness = try StressHarness.dayOne()
        for result in [harness.pin(command), harness.door(command)] {
            #expect(result.decision.isDeny, "\(command): \(describeDecision(result))")
        }
    }
}

private extension Decision {
    var isDeny: Bool {
        if case .deny = self { return true }
        return false
    }
}
