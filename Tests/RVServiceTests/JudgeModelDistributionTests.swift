import Foundation
import Testing
@testable import RVService

/// Contract for Hugging Face weight distribution
/// (docs/plans/laya-hf-distribution.md). The manifest is the single source
/// of truth the fetch script verifies against; these tests keep it parsable,
/// well-formed, and consistent with the bundle layout JudgeRuntime validates.
@Suite("Judge model distribution manifest")
struct JudgeModelDistributionTests {
    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent() // RVServiceTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
    }

    static var manifestURL: URL {
        repoRoot
            .appendingPathComponent("Scripts/laya/distribution-manifest.json", isDirectory: false)
    }

    static func manifest() throws -> [String: Any] {
        let data = try Data(contentsOf: manifestURL)
        let root = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any],
            "manifest must be a JSON object"
        )
        return root
    }

    static func engines(_ root: [String: Any]) throws -> [String: [String: Any]] {
        try #require(
            root["engines"] as? [String: [String: Any]],
            "manifest must have an engines object"
        )
    }

    @Test("manifest parses and pins the production bundle dir")
    func productionBundleDir() throws {
        let root = try Self.manifest()
        let engines = try Self.engines(root)
        let ft = try #require(engines["ft"], "manifest must have an ft engine")
        #expect(ft["bundle_dir"] as? String == JudgeRuntime.ftBundleName)
        #expect(ft["bundle_dir"] as? String == "laya-ft-v2-coreml")
    }

    @Test("every pinned file is well-formed with a real hash and size")
    func fileEntriesWellFormed() throws {
        let root = try Self.manifest()
        let engines = try Self.engines(root)
        #expect(!engines.isEmpty)
        for (name, engine) in engines {
            let files = try #require(
                engine["files"] as? [[String: Any]], "\(name) must list files"
            )
            #expect(!files.isEmpty, "\(name) must pin at least one file")
            for file in files {
                let path = try #require(
                    file["path"] as? String, "\(name) file must have a path"
                )
                #expect(!path.isEmpty && !path.hasPrefix("/"), "relative path: \(path)")
                let digest = try #require(
                    file["sha256"] as? String, "\(path) must have a sha256"
                )
                let hex = CharacterSet(charactersIn: "0123456789abcdef")
                #expect(
                    digest.count == 64 && digest.lowercased().unicodeScalars.allSatisfy(hex.contains),
                    "\(path) sha256 must be 64 hex chars"
                )
                let bytes = try #require(
                    file["bytes"] as? Int, "\(path) must have a byte size"
                )
                #expect(bytes > 0, "\(path) byte size must be positive")
            }
            let paths = files.compactMap { $0["path"] as? String }
            #expect(paths.count == Set(paths).count, "\(name) must not list a file twice")
        }
    }

    @Test("ft pins every file the runtime requires")
    func ftCoversRuntimeRequirements() throws {
        let root = try Self.manifest()
        let engines = try Self.engines(root)
        let files = try #require(engines["ft"]?["files"] as? [[String: Any]])
        let paths = Set(files.compactMap { $0["path"] as? String })
        // Mirrors JudgeRuntime.bundleProblems(engine: .ft): model artifact,
        // tokenizer (either layout), and the label config.
        #expect(paths.contains { $0.hasPrefix("model.mlpackage/") })
        #expect(paths.contains("tokenizer.json") || paths.contains("tokenizer/tokenizer.json"))
        #expect(paths.contains("config.json"))
    }

    @Test("repo pins, when present, look like owner/name @ commit")
    func repoPinShape() throws {
        let root = try Self.manifest()
        let engines = try Self.engines(root)
        let hex = CharacterSet(charactersIn: "0123456789abcdef")
        for (name, engine) in engines {
            let repo = engine["hf_repo"] as? String
            let revision = engine["hf_revision"] as? String
            // Null until the owner runs hf-upload.py; a present pin must be shaped right.
            if let repo {
                #expect(repo.contains("/"), "\(name) hf_repo must be owner/name")
            }
            if let revision {
                #expect(
                    revision.count == 40 && revision.lowercased().unicodeScalars.allSatisfy(hex.contains),
                    "\(name) hf_revision must be a 40-char commit SHA"
                )
            }
        }
    }

    @Test("distribution scripts exist and are executable")
    func scriptsPresent() throws {
        for script in ["hf-upload.py", "fetch-models.sh"] {
            let url = Self.repoRoot
                .appendingPathComponent("Scripts/laya/\(script)", isDirectory: false)
            #expect(
                FileManager.default.isExecutableFile(atPath: url.path),
                "\(script) must exist and be executable"
            )
        }
    }
}
