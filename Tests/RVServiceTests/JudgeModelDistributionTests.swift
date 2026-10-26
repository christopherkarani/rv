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

    @Test("manifest version is 1 (the only version the fetch script reads)")
    func manifestVersion() throws {
        let root = try Self.manifest()
        #expect(root["version"] as? Int == 1)
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
                #expect(
                    path.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
                    "no whitespace (fetch-models.sh does not URL-encode): \(path)"
                )
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

/// fetch-models.sh runs for real against a local file tree (the script's
/// HF_BASE_URL hook) with a fixture manifest, so the download, verify, and
/// atomic-swap paths are executed — not just pinned by the tests above.
@Suite("fetch-models.sh execution")
struct FetchModelsScriptTests {
    /// Tiny ft-shaped payloads (rel path, v2 bytes).
    static let payloads: [(String, Data)] = [
        ("model.mlpackage/Manifest.json", Data(#"{"test":true}"#.utf8)),
        ("model.mlpackage/Data/com.apple.CoreML/weights/weight.bin", Data(repeating: 0x5A, count: 4096)),
        ("tokenizer.json", Data(#"{"tok":"v2"}"#.utf8)),
        ("config.json", Data(#"{"cfg":"v2"}"#.utf8)),
    ]

    static func sha256Hex(of url: URL) throws -> String {
        let fm = FileManager.default
        let (exe, args): (String, [String]) =
            fm.isExecutableFile(atPath: "/usr/bin/sha256sum")
            ? ("/usr/bin/sha256sum", [url.path])
            : ("/usr/bin/shasum", ["-a", "256", url.path])
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.environment = ["PATH": "/usr/bin:/bin"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        process.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let hex = text.split(separator: " ").first.map(String.init) ?? ""
        return try #require(hex.count == 64 ? hex : nil, "hash tool must return 64 hex chars")
    }

    /// Copies the production script next to a fixture manifest (the script
    /// resolves its manifest from its own directory) and serves `payloads`
    /// from a stub HF tree. `corruptRel` is served with wrong bytes after
    /// its manifest entry is hashed, simulating a mid-fetch failure.
    static func writeFixture(work: URL, corruptRel: String? = nil) throws -> (script: URL, stub: URL, dest: URL) {
        let fm = FileManager.default
        let scriptDir = work.appendingPathComponent("script", isDirectory: true)
        let stub = work.appendingPathComponent("stub", isDirectory: true)
        let dest = work.appendingPathComponent("dest/laya-test", isDirectory: true)
        try fm.createDirectory(at: scriptDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: stub, withIntermediateDirectories: true)

        let repo = "testowner/testrepo"
        let rev = String(repeating: "a", count: 40)
        var manifestFiles: [[String: Any]] = []
        for (rel, data) in payloads {
            let url = stub.appendingPathComponent("\(repo)/resolve/\(rev)/\(rel)")
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            manifestFiles.append([
                "path": rel,
                "sha256": try sha256Hex(of: url),
                "bytes": data.count,
            ])
            if corruptRel == rel {
                try Data("corrupted".utf8).write(to: url)
            }
        }
        let manifest: [String: Any] = [
            "version": 1,
            "note": "test fixture",
            "engines": ["ft": [
                "description": "fixture",
                "bundle_dir": "laya-test",
                "hf_repo": repo,
                "hf_revision": rev,
                "files": manifestFiles,
            ]],
        ]
        let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        try manifestData.write(to: scriptDir.appendingPathComponent("distribution-manifest.json"))
        let script = scriptDir.appendingPathComponent("fetch-models.sh")
        try fm.copyItem(
            at: JudgeModelDistributionTests.repoRoot.appendingPathComponent("Scripts/laya/fetch-models.sh"),
            to: script
        )
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, stub, dest)
    }

    static func runFetch(script: URL, stub: URL, dest: URL) throws -> (status: Int32, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [script.path, "--engine", "ft", "--dest", dest.path]
        process.environment = [
            "PATH": "/usr/bin:/bin:/usr/local/bin",
            "HF_BASE_URL": "file://" + stub.path,
            "TMPDIR": NSTemporaryDirectory(),
        ]
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        try process.run()
        process.waitUntilExit()
        let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return (process.terminationStatus, text)
    }

    static func freshWorkDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    @Test("fetch-models installs a verified bundle from a stub tree")
    func installsFromStub() throws {
        let fm = FileManager.default
        let work = Self.freshWorkDir()
        defer { try? fm.removeItem(at: work) }
        let (script, stub, dest) = try Self.writeFixture(work: work)

        let (status, err) = try Self.runFetch(script: script, stub: stub, dest: dest)
        #expect(status == 0, "stderr: \(err)")

        for (rel, data) in Self.payloads {
            #expect(try Data(contentsOf: dest.appendingPathComponent(rel)) == data, "\(rel)")
        }
        let parentNames = try fm.contentsOfDirectory(atPath: dest.deletingLastPathComponent().path)
        #expect(parentNames == ["laya-test"], "no staging leftovers beside the bundle")
    }

    @Test("a failing re-fetch leaves the installed bundle untouched")
    func failingRefetchIsAtomic() throws {
        let fm = FileManager.default
        let work = Self.freshWorkDir()
        defer { try? fm.removeItem(at: work) }
        // A v1 bundle is already installed; the v2 re-fetch fails on the
        // third file (earlier files download fine), like an interrupted
        // re-fetch after a manifest bump.
        let v1 = Self.payloads.map { ($0.0, Data("v1".utf8)) }
        let (script, stub, dest) = try Self.writeFixture(work: work, corruptRel: "tokenizer.json")
        for (rel, data) in v1 {
            let url = dest.appendingPathComponent(rel)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }

        let (status, _) = try Self.runFetch(script: script, stub: stub, dest: dest)
        #expect(status != 0, "hash mismatch must refuse")

        for (rel, data) in v1 {
            #expect(try Data(contentsOf: dest.appendingPathComponent(rel)) == data, "still v1: \(rel)")
        }
        let strays = try fm.subpathsOfDirectory(atPath: dest.path).filter {
            $0.hasSuffix(".tmp") || $0.contains(".rv-fetch.")
        }
        #expect(strays.isEmpty, "no staging strays inside the bundle: \(strays)")
    }
}
