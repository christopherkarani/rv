import Foundation
import Testing
@testable import RVIsolation

/// Known answers for the pure SigV4 signer: AWS's own suite (aws-c-auth,
/// see `Fixtures/aws-sigv4/README.md`) plus S3-mode answers from curl's
/// independent `--aws-sigv4` implementation.
@Suite("SigV4 signer")
struct SecretGatewaySigV4Tests {
    static let suite = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/aws-sigv4", isDirectory: true)

    static var cases: [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: suite.path)) ?? []
        return names.filter { $0 != "README.md" }.sorted()
    }

    /// One vector: `request.txt` parsed the way the suite writes it.
    struct Vector {
        var method: String
        var path: String
        var query: String?
        var headers: [(name: String, value: String)]
        var body: [UInt8]
        var context: [String: Any]

        init(_ name: String) throws {
            let directory = SecretGatewaySigV4Tests.suite.appendingPathComponent(name)
            let raw = try String(contentsOf: directory.appendingPathComponent("request.txt"), encoding: .utf8)
            let lines = raw.components(separatedBy: "\n")
            let requestLine = try #require(lines.first)
            let firstSpace = try #require(requestLine.firstIndex(of: " "))
            let lastSpace = try #require(requestLine.lastIndex(of: " "))
            method = String(requestLine[..<firstSpace])
            let target = String(requestLine[requestLine.index(after: firstSpace)..<lastSpace])
            if let mark = target.firstIndex(of: "?") {
                path = String(target[..<mark])
                query = String(target[target.index(after: mark)...])
            } else {
                path = target
                query = nil
            }
            var headers: [(name: String, value: String)] = []
            var index = 1
            while index < lines.count, lines[index].isEmpty == false {
                let line = lines[index]
                if line.first == " " || line.first == "\t", let last = headers.popLast() {
                    // obs-fold: a continuation line joins the previous value.
                    headers.append((last.name, last.value + " " + line.trimmingCharacters(in: .whitespaces)))
                } else {
                    let colon = try #require(line.firstIndex(of: ":"))
                    headers.append((String(line[..<colon]), String(line[line.index(after: colon)...])))
                }
                index += 1
            }
            self.headers = headers
            body = index + 1 < lines.count ? Array(lines[(index + 1)...].joined(separator: "\n").utf8) : []
            let json = try Data(contentsOf: directory.appendingPathComponent("context.json"))
            context = try #require(try JSONSerialization.jsonObject(with: json) as? [String: Any])
        }
    }

    static func expected(_ name: String, _ file: String) throws -> String {
        let text = try String(
            contentsOf: suite.appendingPathComponent(name).appendingPathComponent(file), encoding: .utf8)
        return text.hasSuffix("\n") ? String(text.dropLast()) : text
    }

    static let suiteDate = Date(timeIntervalSince1970: 1_440_938_160)  // 2015-08-30T12:36:00Z

    @Test func theSuiteIsPresent() {
        #expect(Self.cases.count >= 38)
    }

    @Test(arguments: SecretGatewaySigV4Tests.cases)
    func matchesTheAWSSuite(_ name: String) throws {
        let vector = try Vector(name)
        let credentials = try #require(vector.context["credentials"] as? [String: String])
        #expect(vector.context["timestamp"] as? String == "2015-08-30T12:36:00Z")
        let signBody = vector.context["sign_body"] as? Bool ?? false
        let accessKeyID = try #require(credentials["access_key_id"].flatMap { SecretValue($0) })
        let secretAccessKey = try #require(credentials["secret_access_key"].flatMap { SecretValue($0) })
        let region = try #require(vector.context["region"] as? String)
        let service = try #require(vector.context["service"] as? String)
        let signed = try #require(AWSSigV4.sign(
            AWSSigV4.Request(
                method: vector.method, path: vector.path, query: vector.query, headers: vector.headers,
                payloadHash: AWSSigV4.payloadHash(vector.body)),
            credentials: AWSSigV4.Credentials(
                accessKeyID: accessKeyID, secretAccessKey: secretAccessKey,
                sessionToken: credentials["token"].flatMap { SecretValue($0) }),
            scope: AWSSigV4.Scope(region: region, service: service),
            at: Self.suiteDate,
            options: AWSSigV4.Options(
                normalizePath: vector.context["normalize"] as? Bool ?? true,
                doubleEncodePath: true,
                signSessionToken: (vector.context["omit_session_token"] as? Bool ?? false) == false,
                sendPayloadHash: signBody)))
        #expect(signed.canonicalRequest == (try Self.expected(name, "header-canonical-request.txt")))
        #expect(signed.stringToSign == (try Self.expected(name, "header-string-to-sign.txt")))
        #expect(signed.signature == (try Self.expected(name, "header-signature.txt")))
        let authorization = try Self.expected(name, "header-signed-request.txt")
            .components(separatedBy: "\n").first { $0.hasPrefix("Authorization:") }
        #expect(signed.headers.first { $0.name == "Authorization" }.map { "Authorization:\($0.value)" } == authorization)
    }

    /// curl 8.7.1 `--aws-sigv4 aws:amz:us-east-1:s3` with `X-Amz-Date` and
    /// `x-amz-content-sha256` pinned, against `/photos/my%20photo.jpg?list-type=2&prefix=a%2Fb`.
    @Test(arguments: [
        ("UNSIGNED-PAYLOAD", "f8ae33c42291a55cc48838e826829bf3faa3aa726a49ad2d9e982d070a511128"),
        ("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
         "9ec9b785bf89655d12b9c1a261bb2c25e9f610e0b7a456a8c4fca38ec11a6128"),
    ])
    func s3ModeMatchesCurl(_ payloadHash: String, _ signature: String) throws {
        let signed = try #require(AWSSigV4.sign(
            AWSSigV4.Request(
                method: "GET", path: "/photos/my%20photo.jpg", query: "list-type=2&prefix=a%2Fb",
                headers: [("Host", "examplebucket.s3.amazonaws.com")], payloadHash: payloadHash),
            credentials: Self.example,
            scope: AWSSigV4.Scope(region: "us-east-1", service: "s3"),
            at: Self.suiteDate, options: .s3))
        #expect(signed.signature == signature)
        #expect(signed.canonicalRequest.components(separatedBy: "\n")[1] == "/photos/my%20photo.jpg")
        #expect(signed.canonicalRequest.hasSuffix("\n\(payloadHash)"))
        #expect(signed.headers.first { $0.name == "X-Amz-Content-Sha256" }?.value == payloadHash)
    }

    static let example = AWSSigV4.Credentials(
        accessKeyID: SecretValue("AKIDEXAMPLE")!,
        secretAccessKey: SecretValue("wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")!,
        sessionToken: nil)

    @Test func s3ModeNeitherNormalizesNorDoubleEncodes() throws {
        let signed = try #require(AWSSigV4.sign(
            AWSSigV4.Request(
                method: "GET", path: "//bucket/./a%2Bb/../c d", query: nil,
                headers: [("Host", "s3.us-east-1.amazonaws.com")], payloadHash: AWSSigV4.unsignedPayload),
            credentials: Self.example, scope: AWSSigV4.Scope(region: "us-east-1", service: "s3"),
            at: Self.suiteDate, options: .s3))
        #expect(signed.canonicalRequest.components(separatedBy: "\n")[1] == "//bucket/./a%2Bb/../c%20d")
    }

    @Test func theSignerOwnsItsHeadersAndDropsTheCallersCopies() throws {
        let signed = try #require(AWSSigV4.sign(
            AWSSigV4.Request(
                method: "GET", path: "/", query: nil,
                headers: [
                    ("Host", "example.amazonaws.com"), ("authorization", "AWS4-HMAC-SHA256 Credential=rvph_x/..."),
                    ("X-Amz-Date", "19700101T000000Z"), ("X-Amz-Security-Token", "agent-token"),
                    ("X-Amz-Content-Sha256", "agent-hash"),
                ],
                payloadHash: AWSSigV4.payloadHash([])),
            credentials: AWSSigV4.Credentials(
                accessKeyID: SecretValue("AKIDEXAMPLE")!, secretAccessKey: Self.example.secretAccessKey,
                sessionToken: SecretValue("real-session-token")),
            scope: AWSSigV4.Scope(region: "us-east-1", service: "service"), at: Self.suiteDate,
            options: AWSSigV4.Options()))
        let names = signed.headers.map { $0.name.lowercased() }
        #expect(names.sorted() == ["authorization", "x-amz-content-sha256", "x-amz-date", "x-amz-security-token"])
        #expect(signed.headers.first { $0.name == "X-Amz-Date" }?.value == "20150830T123600Z")
        #expect(signed.headers.first { $0.name == "X-Amz-Security-Token" }?.value == "real-session-token")
        #expect(signed.canonicalRequest.contains("agent") == false)
        #expect(signed.canonicalRequest.contains("rvph_") == false)
    }

    @Test func anUndecodablePathOrQueryIsRefused() {
        for (path, query) in [("/a%zz", nil), ("/a", "k=%G0"), ("/a%", nil)] as [(String, String?)] {
            #expect(AWSSigV4.sign(
                AWSSigV4.Request(
                    method: "GET", path: path, query: query, headers: [("Host", "s3.amazonaws.com")],
                    payloadHash: AWSSigV4.unsignedPayload),
                credentials: Self.example, scope: AWSSigV4.Scope(region: "us-east-1", service: "s3"),
                at: Self.suiteDate, options: .s3) == nil)
        }
    }

    @Test func signedOutputNeverPrintsASecret() throws {
        let signed = try #require(AWSSigV4.sign(
            AWSSigV4.Request(
                method: "GET", path: "/", query: nil, headers: [("Host", "example.amazonaws.com")],
                payloadHash: AWSSigV4.payloadHash([])),
            credentials: AWSSigV4.Credentials(
                accessKeyID: SecretValue("AKIDEXAMPLE")!, secretAccessKey: Self.example.secretAccessKey,
                sessionToken: SecretValue("real-session-token")),
            scope: AWSSigV4.Scope(region: "us-east-1", service: "service"), at: Self.suiteDate,
            options: AWSSigV4.Options()))
        for printed in [String(describing: signed), String(reflecting: signed), String(describing: Self.example)] {
            #expect(printed.contains("AKIDEXAMPLE") == false)
            #expect(printed.contains("real-session-token") == false)
            #expect(printed.contains("EXAMPLEKEY") == false)
        }
    }
}
