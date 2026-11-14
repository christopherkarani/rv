import Foundation
import Testing
@testable import RVIsolation

/// Provider CLIs receive and return secrets, so the caller's PATH must not
/// pick which binary runs. Fixed directories win; PATH is a fallback only
/// for absolute, root-owned directories no one else can write.
@Suite("Secret provider CLI resolution")
struct SecretProviderExecutableTests {
    private func directory(with names: [String]) throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("rv-exe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        for name in names {
            let file = url.appendingPathComponent(name)
            try Data("#!/bin/sh\nexit 0\n".utf8).write(to: file)
            chmod(file.path, 0o755)
        }
        return url.path
    }

    @Test func pathCannotShadowAFixedDirectory() throws {
        let trusted = try directory(with: ["op"])
        let planted = try directory(with: ["op"])
        defer {
            try? FileManager.default.removeItem(atPath: trusted)
            try? FileManager.default.removeItem(atPath: planted)
        }
        let found = SecretCommandProviders.$trustedDirectories.withValue([trusted]) {
            SecretCommandProviders.executable("op", environment: ["PATH": planted])
        }
        #expect(found == trusted + "/op")
    }

    @Test func pathFallbackIgnoresUserOwnedAndRelativeDirectories() throws {
        let planted = try directory(with: ["op"])
        defer { try? FileManager.default.removeItem(atPath: planted) }
        let found = SecretCommandProviders.$trustedDirectories.withValue([]) {
            SecretCommandProviders.executable("op", environment: ["PATH": "\(planted):.:bin:"])
        }
        #expect(found == nil)
        // The real fixed directories are searched first, so a planted PATH
        // entry never wins over them either.
        let plantedEnv = try directory(with: ["env"])
        defer { try? FileManager.default.removeItem(atPath: plantedEnv) }
        let shadowed = try #require(SecretCommandProviders.executable("env", environment: ["PATH": plantedEnv]))
        #expect(shadowed.hasPrefix(plantedEnv) == false)
    }

    @Test func pathFallbackAcceptsARootOwnedLockedDirectory() throws {
        let found = SecretCommandProviders.$trustedDirectories.withValue([]) {
            SecretCommandProviders.executable("sh", environment: ["PATH": "/bin"])
        }
        let resolved = try #require(found)
        #expect(resolved.hasPrefix("/"))
        #expect(resolved.hasSuffix("/sh"))
    }

    @Test func aMissingCLINamesWhereRvLooked() {
        let missing = SecretCommandProviders.$trustedDirectories.withValue(["/nonexistent-rv-a", "/nonexistent-rv-b"]) {
            SecretCommandProviders.bitwarden(
                id: "12345678-1234-1234-1234-123456789abc", environment: ["PATH": "/nonexistent-rv-c"])
        }
        guard case .failure(.providerUnavailable(let message)) = missing else {
            Issue.record("a missing CLI was not refused as unavailable")
            return
        }
        #expect(message.contains("`bws`"))
        #expect(message.contains("/nonexistent-rv-a, /nonexistent-rv-b"))
        #expect(message.contains("root-owned"))
    }
}
