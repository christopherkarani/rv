import Foundation
import Testing
@testable import RVIsolation

/// Token-shaped fixtures are assembled at runtime so this file never holds a
/// literal that another scanner (or rv itself) would flag.
private enum Fake {
    static let base62 = "a8Kf93jLq0Zx7Wm2Np4Rt6Yv1Bc5Dh8Gs3Jk7Mn2Pq9Tu4Wx6Ze0Hi1Lo5Rb"
    static func body(_ count: Int) -> String {
        String(repeating: base62, count: count / base62.count + 1).prefix(count).description
    }
    static let aws = "AK" + "IA" + "Q3MZ7XK2LP5VN4RT"
    static let github = "gh" + "p_" + body(36)
    static let githubFineGrained = "github" + "_pat_" + body(82)
    static let slack = "xo" + "xb-" + "1234567890-" + body(24)
    static let stripe = "sk" + "_live_" + body(24)
    static let openAI = "sk" + "-proj-" + body(48)
    static let anthropic = "sk" + "-ant-api03-" + body(93)
    static let google = "AI" + "za" + body(35)
    static let jwt = "ey" + "J" + body(20) + ".ey" + "J" + body(30) + "." + body(24)
    static let pem = "-----BEGIN " + "RSA PRIVATE KEY-----\n" + body(64) + "\n" + body(64) + "\n-----END RSA PRIVATE KEY-----\n"
}

@Suite("Secret leak scanner")
struct SecretLeakScannerTests {
    private func scan(_ text: String, path: String = "f.txt", secrets: [(name: String, value: SecretValue)] = [],
        ignore: SecretLeakIgnore = SecretLeakIgnore(text: "")) -> [SecretLeakFinding]
    {
        SecretLeakScanner.scan(files: [(path, Array(text.utf8))], secrets: secrets, ignore: ignore)
    }

    @Test(arguments: [
        ("aws-access-key-id", Fake.aws),
        ("github-token", Fake.github),
        ("github-token", Fake.githubFineGrained),
        ("slack-token", Fake.slack),
        ("stripe-secret-key", Fake.stripe),
        ("openai-api-key", Fake.openAI),
        ("anthropic-api-key", Fake.anthropic),
        ("google-api-key", Fake.google),
        ("jwt", Fake.jwt),
    ])
    func builtInRuleFiresWithLineAndNeverTheValue(rule: String, token: String) {
        let findings = scan("first line\nvalue: '\(token)'\n")
        #expect(findings == [SecretLeakFinding(path: "f.txt", line: 2, secret: rule)])
        #expect("\(findings)".contains(token) == false)
    }

    @Test func privateKeyHeaderNeedsKeyMaterial() {
        #expect(scan("x\n" + Fake.pem) == [SecretLeakFinding(path: "f.txt", line: 2, secret: "private-key")])
        #expect(scan("let header = \"-----BEGIN " + "PRIVATE KEY-----\"\n").isEmpty)
    }

    @Test func genericAssignmentNeedsEntropyAndIsNotAPlaceholder() {
        let random = Fake.body(28)
        #expect(scan("API_TOKEN = \"\(random)\"\n") == [SecretLeakFinding(path: "f.txt", line: 1, secret: "generic-secret")])
        #expect(scan("db_password: \(random)\n") == [SecretLeakFinding(path: "f.txt", line: 1, secret: "generic-secret")])
        for benign in [
            "SECRET_KEY=aaaaaaaaaaaaaaaa1111",
            "password = \"correct-horse-battery-staple-2024\"",
            "secretKey = \"MySuperSecretPassword2024\"",
            "token = process.env.API_TOKEN",
            "API_KEY=your-api-key-goes-here-123",
            "API_KEY=changeme-0000000000000",
            "API_KEY=xxxxxxxxxxxxxxxxxxxxxxxx1",
            "OPENAI_API_KEY=sk-rvph_0123456789abcdef0123456789abcdef",
            "AWS_ACCESS_KEY_ID=AKIA" + "IOSFODNN7EXAMPLE",
            "monkey = getToken(\(random))",
        ] {
            #expect(scan(benign + "\n").isEmpty, "\(benign)")
        }
    }

    @Test func specificRuleWinsOverGenericOnTheSameLine() {
        #expect(scan("GITHUB_TOKEN=\(Fake.github)\n") == [SecretLeakFinding(path: "f.txt", line: 1, secret: "github-token")])
    }

    @Test func exactValuesMatchInMemoryAndWinOverPatterns() throws {
        let value = try #require(SecretValue(Fake.github))
        let findings = scan("a\nb\nGH=\(Fake.github)\n", secrets: [("GH_TOKEN", value)])
        #expect(findings == [SecretLeakFinding(path: "f.txt", line: 3, secret: "GH_TOKEN")])
    }

    @Test func inlineAllowAndIgnoreFileSuppressPatternsButNotExactValues() throws {
        #expect(scan("key: \(Fake.aws) # rv-secrets:allow\n").isEmpty)
        let ignore = SecretLeakIgnore(text: "# reviewed\nconfig/a.yml:aws-access-key-id:2\n\n")
        #expect(scan("x\nkey: \(Fake.aws)\n", path: "config/a.yml", ignore: ignore).isEmpty)
        #expect(scan("key: \(Fake.aws)\n", path: "config/a.yml", ignore: ignore).count == 1)
        let value = try #require(SecretValue("resolved-secret-value"))
        let exact = scan("v=resolved-secret-value # rv-secrets:allow\n", secrets: [("TOKEN", value)])
        #expect(exact == [SecretLeakFinding(path: "f.txt", line: 1, secret: "TOKEN")])
    }

    @Test func binaryBuffersSkipPatternRulesButNotExactValues() throws {
        let value = try #require(SecretValue("resolved-secret-value"))
        var bytes: [UInt8] = [0, 1, 2]
        bytes += Array("\n\(Fake.aws)\nresolved-secret-value".utf8)
        let findings = SecretLeakScanner.scan(
            files: [("blob.bin", bytes)], secrets: [("TOKEN", value)], ignore: SecretLeakIgnore(text: ""))
        #expect(findings == [SecretLeakFinding(path: "blob.bin", line: 3, secret: "TOKEN")])
    }

    @Test func treeScanReportsOversizedFilesInsteadOfSkippingSilently() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("rv-scan-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let big = root.appendingPathComponent("big.log")
        #expect(FileManager.default.createFile(atPath: big.path, contents: nil))
        let handle = try FileHandle(forWritingTo: big)
        try handle.truncate(atOffset: UInt64(SecretLeakScanner.maximumFileBytes + 1))
        try handle.close()
        try Data("x\nsecret: \(Fake.aws)\n".utf8).write(to: root.appendingPathComponent("a.env"))
        try Data("a.env:aws-access-key-id:9\n".utf8).write(to: root.appendingPathComponent(SecretLeakIgnore.fileName))
        let report = SecretLeakScanner.scan(root: root, secrets: [])
        #expect(report.tooLarge == ["big.log"])
        #expect(report.findings == [SecretLeakFinding(path: "a.env", line: 2, secret: "aws-access-key-id")])
    }

    @Test func shannonEntropy() {
        #expect(SecretPatternRules.entropy("aaaa") == 0)
        #expect(abs(SecretPatternRules.entropy("abcd") - 2) < 0.0001)
    }
}
