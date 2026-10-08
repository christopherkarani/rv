import Testing
@testable import RVEngine

/// P10e8 (C-F3): static `cd`/`pushd`/`popd` tracking across chain segments.
@Suite("CdTracking")
struct CdTrackingTests {
    private func tracked(
        _ segments: [String],
        from working: String? = "/repo",
        home: String? = "/home/u"
    ) -> String? {
        var tracker = DirectoryTracker(working: working, home: home)
        for segment in segments {
            tracker.apply(tokens: tokenizeFilesystemWords(segment))
        }
        return tracker.working
    }

    @Test func cdAbsoluteAndRelative() {
        #expect(tracked(["cd /tmp"]) == "/tmp")
        #expect(tracked(["cd sub"]) == "/repo/sub")
        #expect(tracked(["cd sub", "cd .."]) == "/repo")
        #expect(tracked(["cd /", "cd .."]) == "/")
        #expect(tracked(["cd sub/dir"]) == "/repo/sub/dir")
        #expect(tracked(["cd \"a b\""]) == "/repo/a b")
    }

    @Test func cdFlagsAndForms() {
        #expect(tracked(["cd -L sub"]) == "/repo/sub")
        #expect(tracked(["cd -- -x"]) == "/repo/-x")
        #expect(tracked(["cd -"]) == nil)
        #expect(tracked(["cd -P /tmp"]) == nil)
        #expect(tracked(["cd -LP /tmp"]) == nil)
        #expect(tracked(["cd --weird sub"]) == nil)
        #expect(tracked(["cd a b"]) == nil)
    }

    @Test func cdDynamicAndHome() {
        #expect(tracked(["cd $X"]) == nil)
        #expect(tracked(["cd $X", "cd /repo"]) == "/repo")
        #expect(tracked(["cd $X", "cd sub"]) == nil)
        #expect(tracked(["cd"]) == "/home/u")
        #expect(tracked(["cd"], home: nil) == nil)
        #expect(tracked(["cd ~/x"]) == "/home/u/x")
        #expect(tracked(["cd $HOME/x"]) == "/home/u/x")
        #expect(tracked(["cd ~other/x"]) == nil)
    }

    @Test func cdIgnoresRedirectsAndNonCd() {
        #expect(tracked(["cd /tmp > f"]) == "/tmp")
        #expect(tracked(["touch f"]) == "/repo")
        #expect(tracked(["sudo cd /tmp"]) == "/repo")
        #expect(tracked(["env A=1 cd /tmp"]) == "/repo")
    }

    @Test func escapedHeadPoisonsInsteadOfMissing() {
        // `c\d` executes the `cd` builtin; ignoring it would keep a
        // stale inside cwd while the runtime moved outside (fail-open).
        // The decoded token lost the quote positions needed to decide,
        // so poison (nil) fails closed instead.
        #expect(tracked(["c\\d /tmp"]) == nil)
        #expect(tracked(["\\cd /tmp"]) == nil)
        #expect(tracked(["push\\d /tmp"]) == nil)
        // Poison is recoverable: absolute operands do not need the cwd.
        #expect(tracked(["c\\d /tmp", "cd /repo"]) == "/repo")
        #expect(tracked(["c\\d /tmp", "cd sub"]) == nil)
    }

    @Test func caseAndPathHeadsDoNotTrack() {
        // Builtin lookup is case-sensitive (`CD` never cds) and a slash
        // means external execution in a child (parent cwd unchanged).
        #expect(tracked(["CD /tmp"]) == "/repo")
        #expect(tracked(["/bin/cd /tmp"]) == "/repo")
        #expect(tracked(["./cd /tmp"]) == "/repo")
        #expect(tracked(["command /bin/cd /tmp"]) == "/repo")
        #expect(tracked(["command CD /tmp"]) == "/repo")
    }

    @Test func opaqueHeadsPoison() {
        // Substitution, ANSI-C, eval, and source heads can change the
        // parent cwd opaquely; ignoring them would miss the move.
        #expect(tracked(["$(echo cd) /tmp"]) == nil)
        #expect(tracked(["`echo cd` /tmp"]) == nil)
        #expect(tracked(["$'cd' /tmp"]) == nil)
        #expect(tracked(["eval 'cd /tmp'"]) == nil)
        #expect(tracked(["source setup.sh"]) == nil)
        #expect(tracked([". setup.sh"]) == nil)
        #expect(tracked(["command eval 'cd /tmp'"]) == nil)
    }

    @Test func timeAndNegationPrefixesTrack() {
        // `time`/`!` run the verb in the current shell. `time -p` only
        // formats; `!` takes no options. Nested prefixes are bizarre:
        // poison instead of proving arity.
        #expect(tracked(["time cd /tmp"]) == "/tmp")
        #expect(tracked(["time -p cd /tmp"]) == "/tmp")
        #expect(tracked(["! cd /tmp"]) == "/tmp")
        #expect(tracked(["! ! cd /tmp"]) == nil)
        #expect(tracked(["command command cd /tmp"]) == nil)
        #expect(tracked(["time -v cd /tmp"]) == "/repo")
    }

    @Test func globBraceHeadsPoison() {
        // Glob heads can expand to a directory builtin (`[c]d` with
        // ./cd present); comma-braces can too (`{dirs,-c}` clears the
        // stack). Exact `[`/`[[` are the static test builtins, and lone
        // `{x}` is literal (no expansion without a comma): all stay
        // untracked.
        #expect(tracked(["[c]d /tmp"]) == nil)
        #expect(tracked(["pushd /tmp", "{dirs,-c}", "popd"]) == nil)
        #expect(tracked(["{cd} /tmp"]) == "/repo")
        #expect(tracked(["[ -f x ]"]) == "/repo")
        #expect(tracked(["[[ -f x ]]"]) == "/repo")
    }

    @Test func commandBuiltinPrefixes() {
        #expect(tracked(["command cd /tmp"]) == "/tmp")
        #expect(tracked(["builtin cd /tmp"]) == "/tmp")
        #expect(tracked(["command -v cd"]) == "/repo")
        #expect(tracked(["command -V cd"]) == "/repo")
        // M-23: `-p` executes with the default PATH — it is not a query.
        #expect(tracked(["command -p cd /tmp"]) == "/tmp")
        #expect(tracked(["command -p -- cd /tmp"]) == "/tmp")
        #expect(tracked(["command -p -v cd"]) == "/repo")
        #expect(tracked(["command echo hi"]) == "/repo")
    }

    @Test func pushdPopdRoundTrip() {
        var tracker = DirectoryTracker(working: "/repo", home: "/home/u")
        tracker.apply(tokens: tokenizeFilesystemWords("pushd /tmp"))
        #expect(tracker.working == "/tmp")
        tracker.apply(tokens: tokenizeFilesystemWords("popd"))
        #expect(tracker.working == "/repo")
        // Bare pushd swaps; empty-stack popd is a no-op.
        tracker.apply(tokens: tokenizeFilesystemWords("pushd /a"))
        tracker.apply(tokens: tokenizeFilesystemWords("pushd"))
        #expect(tracker.working == "/repo")
        tracker.apply(tokens: tokenizeFilesystemWords("popd"))
        tracker.apply(tokens: tokenizeFilesystemWords("popd"))
        #expect(tracker.working == "/a")
        tracker.apply(tokens: tokenizeFilesystemWords("popd"))
        #expect(tracker.working == "/a")
    }

    @Test func pushdRotationsAndNoCd() {
        #expect(tracked(["pushd /tmp", "pushd +1"]) == "/repo")
        var tracker = DirectoryTracker(working: "/repo", home: "/home/u")
        tracker.apply(tokens: tokenizeFilesystemWords("pushd -n /tmp"))
        #expect(tracker.working == "/repo")
        tracker.apply(tokens: tokenizeFilesystemWords("popd"))
        #expect(tracker.working == "/tmp")
    }

    @Test func popdIndexedAndDirsClear() {
        var tracker = DirectoryTracker(working: "/repo", home: "/home/u")
        tracker.apply(tokens: tokenizeFilesystemWords("pushd /a"))
        tracker.apply(tokens: tokenizeFilesystemWords("pushd /b"))
        tracker.apply(tokens: tokenizeFilesystemWords("popd +1"))
        #expect(tracker.working == "/b")
        tracker.apply(tokens: tokenizeFilesystemWords("popd"))
        #expect(tracker.working == "/repo")
        tracker.apply(tokens: tokenizeFilesystemWords("pushd /tmp"))
        tracker.apply(tokens: tokenizeFilesystemWords("dirs -c"))
        tracker.apply(tokens: tokenizeFilesystemWords("popd"))
        // Stack cleared: popd is a no-op, cwd stays /tmp.
        #expect(tracker.working == "/tmp")
        #expect(tracked(["pushd +9"]) == nil)
    }
}
