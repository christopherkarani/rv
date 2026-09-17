import Testing
import RVDomain
import RVEngine

/// Remaining pin over-blocks after FalsePositiveStress / AgentParseStress.
/// A deny here is a data-role false positive. RV-RR-02 comments / unquoted
/// echo are named residuals and stay out of this net.
///
/// Run: `tools/gate.sh --quiet RVCorpusTests --filter PinOverblockStress`
@Suite("Pin over-block stress")
struct PinOverblockStressTests {
    static let residualRVRR02: [String] = [
        "# git reset --hard",
        "echo git reset --hard",
        ": git reset --hard",
        "true git reset --hard",
    ]

    @Test func pinEvaluate_overblockCorpus_doesNotDeny() throws {
        let harness = try StressHarness.dayOne()
        for row in try loadStressCorpus("pin-overblock-stress.json") {
            guard let command = row.command else { continue }
            let result = harness.pin(command)
            if row.expected == "deny" {
                guard case .deny(let deny) = result.decision else {
                    Issue.record("true-positive must deny \(row.id): \(command)")
                    continue
                }
                if let ruleID = row.ruleID {
                    #expect(deny.ruleID.rawValue == ruleID, "\(row.id)")
                }
                continue
            }
            if result.decision != .allow {
                Issue.record("\(row.id) over-block \(describeDecision(result)) on \(command)")
            }
        }
    }

    @Test func pinEvaluate_namedSearchAndGitFormat_doNotDeny() throws {
        let harness = try StressHarness.dayOne()
        let commands = [
            "awk '/rm -rf/'",
            "awk '/git reset --hard/'",
            "sed -n '/git reset --hard/p'",
            "sed -n '/rm -rf/p'",
            "perl -ne 'print if /rm -rf/'",
            #"perl -e "print 'git reset --hard'""#,
            #"php -r "echo 'git reset --hard';""#,
            #"lua -e "print('git reset --hard')""#,
            #"jq -n '"git reset --hard"'"#,
            "fgrep 'rm -rf'",
            "egrep 'rm -rf'",
            "ag 'rm -rf'",
            "git show --pretty=format:'git reset --hard'",
            "git log --pretty='git reset --hard'",
            "git log --format='git reset --hard'",
            "git for-each-ref --format='git reset --hard'",
            "git commit --trailer 'Made-with: git reset --hard'",
            "git interpret-trailers --trailer 'Made-with: git reset --hard'",
            "git config alias.oops 'reset --hard'",
            "git config --global alias.rh 'reset --hard'",
            "git log -S 'rm -rf'",
            "git log -G 'git reset --hard'",
            "git diff -S 'rm -rf'",
            "gh pr create --title 'fix git reset --hard'",
            "mkfs --help",
            "wipefs --help",
        ]
        var overBlocks = 0
        for command in commands {
            let result = harness.pin(command)
            if result.decision != .allow {
                overBlocks += 1
                Issue.record("over-block \(describeDecision(result)) on \(command)")
            }
        }
        #expect(overBlocks == 0)
    }

    @Test func pinEvaluate_heredocWrite_doesNotDeny() throws {
        let harness = try StressHarness.dayOne()
        let reset = """
            cat > /tmp/note.md << 'EOF'
            See git reset --hard
            EOF
            """
        let wipe = """
            cat > /tmp/note.md << 'EOF'
            rm -rf /
            EOF
            """
        #expect(harness.pin(reset).decision == .allow, "heredoc write is not an executing sink")
        #expect(harness.pin(wipe).decision == .allow, "heredoc write is not an executing sink")
    }

    @Test func pinEvaluate_heredocPipeBash_stillDenies() throws {
        let harness = try StressHarness.dayOne()
        let command = """
            cat <<'EOF' | bash
            git reset --hard
            EOF
            """
        let result = harness.pin(command)
        guard case .deny(let deny) = result.decision else {
            Issue.record("pipe-to-bash heredoc must stay a pin true-positive, got \(describeDecision(result))")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:reset-hard")
    }

    @Test func residualRVRR02_isDocumentedNotThisNet() throws {
        let ids = Set(try loadStressCorpus("pin-overblock-stress.json").map(\.id))
        for command in Self.residualRVRR02 {
            #expect(ids.contains(where: { $0.contains("rr-02") }) == false)
            _ = command
        }
        #expect(Self.residualRVRR02.contains("# git reset --hard"))
    }
}
