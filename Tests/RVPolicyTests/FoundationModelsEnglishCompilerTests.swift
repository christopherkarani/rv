import Foundation
import Testing
import RVDomain
@testable import RVPolicy

@Suite("FoundationModelsEnglishCompiler")
struct FoundationModelsEnglishCompilerTests {
    @Test func constructsOnThisHost() {
        let compiler = FoundationModelsEnglishCompiler()
        #expect(compiler.timeout == FoundationModelsEnglishCompiler.defaultTimeout)
        #expect(compiler.usesSystemModel)
        let _: any EnglishCompiler = compiler
    }

    @Test(arguments: [
        "never force-push main",
        "never allow force-push to main",
    ])
    func injectedFake_compilesKnownDenyWithoutLiveApple(_ english: String) async throws {
        let compiler = FoundationModelsEnglishCompiler(
            usesSystemModel: true,
            compiler: FakeEnglishCompiler()
        )
        let result = try await compiler.compile(english)
        guard case .preview(let preview) = result else {
            Issue.record("expected preview from injected fake, got \(result)")
            return
        }
        #expect(preview.draft.predicate == .gitPush(force: .force, branch: "main"))
        #expect(preview.draft.verdict == .deny)
        #expect(preview.draft.origin == .machine)
        #expect(preview.allowedToSave == true)
        #expect(preview.sentence == "Always block force-push to main.")
        #expect(preview.draft.id == RuleID(pack: .coreGit, pattern: "force-push-main"))
    }

    @Test func injectedFake_refusesUnknownWithoutLiveApple() async throws {
        let compiler = FoundationModelsEnglishCompiler(
            usesSystemModel: true,
            compiler: FakeEnglishCompiler()
        )
        let result = try await compiler.compile("be careful in prod")
        #expect(result == .refuse(.uncompilable))
    }

    @Test func disabledSystemModel_throwsUnavailableWithoutLiveApple() async {
        let compiler = FoundationModelsEnglishCompiler(usesSystemModel: false)
        #expect(compiler.usesSystemModel == false)
        await #expect(throws: EnglishCompilerError.unavailable) {
            _ = try await compiler.compile("never allow force-push to main")
        }
    }

    @Test func emptyEnglish_refusesEmptyWithoutLiveApple() async throws {
        let compiler = FoundationModelsEnglishCompiler(usesSystemModel: false)
        let result = try await compiler.compile("")
        #expect(result == .refuse(.empty))
    }

    @Test func injectedCompiler_propagatesCancellation() async {
        let compiler = FoundationModelsEnglishCompiler(
            usesSystemModel: true,
            compiler: CancelledEnglishCompiler()
        )
        await #expect(throws: CancellationError.self) {
            _ = try await compiler.compile("never allow force-push to main")
        }
    }

    @Test func mapping_forceMainDeny_matchesKnownFakeForm() throws {
        let result = FoundationModelsEnglishCompileMapping.preview(
            force: .force,
            branch: "main",
            verdict: .deny,
            sentence: "Always block force-push to main."
        )
        guard case .preview(let preview) = result else {
            Issue.record("expected preview from mapping, got \(result)")
            return
        }
        #expect(preview.draft.predicate == .gitPush(force: .force, branch: "main"))
        #expect(preview.draft.verdict == .deny)
        #expect(preview.draft.origin == .machine)
        #expect(preview.allowedToSave == true)
        #expect(preview.sentence == "Always block force-push to main.")
        #expect(preview.draft.id == RuleID(pack: .coreGit, pattern: "force-push-main"))
        let json = try #require(String(data: JSONEncoder().encode(preview), encoding: .utf8))
        #expect(json.contains("english") == false)
        #expect(json.contains("never allow") == false)
        #expect(json.contains("gitPush"))
    }

    @Test func domainSourcesDoNotImportFoundationModels() throws {
        let domain = repoRoot().appendingPathComponent("Sources/RVDomain", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: domain,
            includingPropertiesForKeys: nil
        )
        #expect(files.contains { $0.pathExtension == "swift" })
        for file in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(
                text.contains("import FoundationModels") == false,
                "\(file.lastPathComponent) must not import FoundationModels"
            )
        }
    }

    @Test func adapterSourceGatesAppleImport() throws {
        let url = repoRoot().appendingPathComponent(
            "Sources/RVPolicy/FoundationModelsEnglishCompiler.swift"
        )
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("#if canImport(FoundationModels)"))
        #expect(text.contains("import FoundationModels"))
        #expect(text.contains("struct FoundationModelsEnglishCompiler"))
        #expect(text.contains("EnglishCompiler"))
        #expect(text.contains("class ") == false)
        #expect(text.contains("try!") == false)
    }

    #if !canImport(FoundationModels)
    @Test func linuxHost_compilerDegradesToUnavailable() async {
        let compiler = FoundationModelsEnglishCompiler()
        await #expect(throws: EnglishCompilerError.unavailable) {
            _ = try await compiler.compile("never allow force-push to main")
        }
    }
    #endif
}

private struct CancelledEnglishCompiler: EnglishCompiler {
    func compile(_: String) async throws -> EnglishCompileResult {
        throw CancellationError()
    }
}

private func repoRoot() -> URL {
    URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
}
