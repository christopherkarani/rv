import Testing
import RVDomain
import RVEngine
import RVPacks

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

extension SafePatternSpanTests {
    /// Rules whose `.*`/`\s` only incidentally crosses a separator stay
    /// suppressed by the safe match: these chains are pin-allowed on main.
    @Test(
        "incidental cross-segment match stays suppressed",
        arguments: [
            "rm --recursive --force /tmp/x && ! false && rm --recursive --force /tmp/x",
            "rm -rf /tmp/x && shred --help && rm -rf /tmp/x",
            "rm -rf /tmp/x; $HOME/bin/tool \"$1\"; rm -rf /tmp/x",
            "git push origin HEAD\nsed -f script.sed f | git restore --staged a.txt",
            "mv build/out dist\nperl -pi -e 's/a/b/' ~/.bashrc || rm --recursive --force /tmp/x",
        ]
    )
    func incidentalSpanStaysAllowed(_ command: String) throws {
        let harness = try StressHarness.dayOne()
        #expect(describeDecision(harness.pin(command)) == "allow", "\(command)")
    }
}

extension SafePatternSpanTests {
    @Test func dayOneCrossSegmentRulesAreTheIntendedOnes() throws {
        let packs = try PackRegistry.loadDayOne()
        let compiled = try CompiledPacks<ICUCompiledPattern>.compile(
            packs: packs,
            using: ICUPatternEngine()
        )
        let spanning = Set(compiled.packs.flatMap { pack in
            pack.destructive.filter(\.spansSegments).map { "\(pack.snapshot.id.rawValue):\($0.rule.name)" }
        })
        #expect(spanning == [
            "core.filesystem:fork-bomb",
            "core.filesystem:cp-sensitive-then-delete",
            "core.filesystem:ln-symlink-sensitive-then-delete",
            "core.filesystem:rsync-sensitive-then-delete",
            "core.filesystem:redirect-truncate-root-home",
            "core.filesystem:redirect-truncate-dynamic-path",
        ])
    }
}

private extension Decision {
    var isDeny: Bool {
        if case .deny = self { return true }
        return false
    }
}
