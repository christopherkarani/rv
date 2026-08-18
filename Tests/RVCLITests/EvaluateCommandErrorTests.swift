import Foundation
import Testing
import RVDomain
import RVEngine
import RVPacks
@testable import RVCLI

private enum UnexpectedEvaluationError: Error {
    case boom
}

private func throwFixture(_ kind: String) -> any Error {
    switch kind {
    case "packLoad.missingResource":
        PackLoadError.missingResource("core.git")
    case "packLoad.invalidPackID":
        PackLoadError.invalidPackID("not-a-pack")
    case "packLoad.invalidSeverity":
        PackLoadError.invalidSeverity("not-a-severity")
    case "packLoad.emptyCorePack":
        PackLoadError.emptyCorePack("core.git")
    case "decoding":
        DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "pack json")
        )
    case "patternCompile":
        PatternCompileError.invalidPattern(name: "required", message: "compile failed")
    default:
        UnexpectedEvaluationError.boom
    }
}

@Test(arguments: [
    "packLoad.missingResource",
    "packLoad.invalidPackID",
    "packLoad.invalidSeverity",
    "packLoad.emptyCorePack",
    "decoding",
    "patternCompile",
    "unexpected",
])
func evaluateCommandCatch_throwIsIncompleteNeverAllow(_ kind: String) {
    let result = CommandRun.evaluationResult(catching: {
        throw throwFixture(kind)
    })
    #expect(result.decision == .indeterminate(.corePacksUnavailable), Comment(rawValue: kind))
    if case .allow = result.decision {
        Issue.record("mapped \(kind) must never allow")
    }
    #expect(result.matched == nil, Comment(rawValue: kind))
    #expect(result.matchedSafe == nil, Comment(rawValue: kind))
}

@Test func evaluateCommandCatch_successPassesThrough() {
    let expected = EvaluationResult(decision: .allow, quickRejected: true)
    let result = CommandRun.evaluationResult(catching: { expected })
    #expect(result == expected)
}

@Test func evaluationResultFrom_packAndCompileErrorsAreIncomplete() {
    let errors: [any Error] = [
        PackLoadError.missingResource("core.git"),
        DecodingError.dataCorrupted(
            DecodingError.Context(codingPath: [], debugDescription: "pack json")
        ),
        PatternCompileError.invalidPattern(name: "required", message: "compile failed"),
        UnexpectedEvaluationError.boom,
    ]
    for error in errors {
        let result = CommandRun.evaluationResult(from: error)
        #expect(result.decision == .indeterminate(.corePacksUnavailable))
        if case .allow = result.decision {
            Issue.record("mapper must never allow")
        }
    }
}
