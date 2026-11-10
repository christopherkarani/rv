import Testing
import RVDomain
import RVEngine

private func isDenied(_ result: EvaluationResult) -> Bool {
    if case .deny = result.decision { return true }
    return false
}

/// Git and shell aliases are wrappers: their body is the command that runs.
/// Every deny row here was allowed on main by both the pin and the door.
@Suite("Git alias bypasses")
struct GitAliasBypassTests {
    @Test(
        "an alias whose body is destructive denies where the body is visible",
        arguments: [
            #"git -c alias.z="reset --hard" z"#,
            #"git -c alias.z="clean -fdx" z"#,
            #"git config alias.z "reset --hard" && git z"#,
            "alias g=git; g reset --hard",
            "git config alias.oops 'reset --hard'",
            "git config --global alias.rh 'reset --hard'",
            "git config set alias.rh 'reset --hard'",
            #"git -c ALIAS.Z="reset --hard" z"#,
            #"sudo git -c alias.z="reset --hard" z"#,
            #"git -c alias.a=b -c alias.b="reset --hard" a"#,
            "git -c alias.z='!rm -rf src' z",
            "alias g='git reset'; g --hard",
            "alias s='sudo ' g=git; s g reset --hard",
            #"git -c alias.z="$CMD" z"#,
            "alias g=$TOOL; g reset --hard",
            #"git --config-env=alias.z=CMD z"#,
        ]
    )
    func destructiveAliasDenies(_ command: String) throws {
        let harness = try StressHarness.dayOne()
        for result in [harness.pin(command), harness.door(command)] {
            #expect(isDenied(result), "\(command): \(describeDecision(result))")
        }
    }

    /// The pin is pack-only; a remote push is a door (semantic) deny.
    @Test func aliasedPushDeniesAtTheDoor() throws {
        let harness = try StressHarness.dayOne()
        let result = harness.door("git -c alias.p=push p origin main")
        #expect(isDenied(result), "\(describeDecision(result))")
    }

    @Test(
        "benign aliases and alias reads stay allowed",
        arguments: [
            "git config alias.st status",
            "git config --global alias.co checkout",
            "git st",
            "git -c alias.st=status st",
            "alias ll='ls -la'; ll",
            "git config --get alias.z",
            "git config --unset alias.z",
            "git config --list",
            "grep -rn alias src",
            "git log --grep alias",
        ]
    )
    func benignAliasAllows(_ command: String) throws {
        let harness = try StressHarness.dayOne()
        for result in [harness.pin(command), harness.door(command)] {
            #expect(result.decision == .allow, "\(command): \(describeDecision(result))")
        }
    }

    @Test func unverifiableAliasNamesItsRule() throws {
        let harness = try StressHarness.dayOne()
        guard case .deny(let deny) = harness.pin(#"git -c alias.z="$CMD" z"#).decision else {
            Issue.record("must deny")
            return
        }
        #expect(deny.ruleID.rawValue == "core.git:git-alias-semantic-unverified")
    }

    @Test func aliasFanOutIsBounded() throws {
        let harness = try StressHarness.dayOne()
        let command = "alias a='b;b;b;b;b;b;b;b' b='c;c;c;c;c;c;c;c' c='d;d;d;d;d;d;d;d' d=ls; a"
        let started = ContinuousClock.now
        let result = harness.pin(command)
        #expect(ContinuousClock.now - started < .seconds(1))
        #expect(result.decision != .allow, "\(describeDecision(result))")
    }
}
