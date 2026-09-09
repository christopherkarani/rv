import Foundation
import Testing
import RVDomain
@testable import RVPolicy

struct FoundationModelsEnglishCompilerTests {
    @Test func constructsOnThisHost() {
        let compiler = FoundationModelsEnglishCompiler()
        #expect(compiler.timeout == FoundationModelsEnglishCompiler.defaultTimeout)
        #expect(compiler.usesSystemModel)
        let _: any EnglishCompiler = compiler
    }

    @Test func injectedFake_compilesKnownDenyWithoutLiveApple() async throws {
        let compiler = FoundationModelsEnglishCompiler(
            usesSystemModel: true,
            compiler: FakeEnglishCompiler()
        )
        let result = try await compiler.compile("never allow force-push to main")
        guard case .preview(let preview) = result else {
            Issue.record("expected preview from injected fake, got \(result)")
            return
        }
        #expect(preview.rule.predicate == .gitPush(force: .force, branch: "main"))
        #expect(preview.allowedToSave == true)
    }

    @Test func disabledSystemModel_throwsUnavailableWithoutLiveApple() async {
        let compiler = FoundationModelsEnglishCompiler(usesSystemModel: false)
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
