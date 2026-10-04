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

    @Test func commandBuiltinPrefixes() {
        #expect(tracked(["command cd /tmp"]) == "/tmp")
        #expect(tracked(["builtin cd /tmp"]) == "/tmp")
        #expect(tracked(["command -v cd"]) == "/repo")
        #expect(tracked(["command -V cd"]) == "/repo")
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
