import Foundation
import Testing
@testable import RVIPC

struct EvaluationRouteTests {
    @Test func transportAbsentIsInProcess() {
        #expect(EvaluationRoute.path(for: .transportAbsent) == .inProcess)
    }

    @Test func missingAdvertisedServiceSemverIsInProcess() {
        #expect(
            EvaluationRoute.path(
                for: .reply(
                    clientSemver: ProtocolVersion.serviceSemver,
                    advertisedServiceSemver: nil
                )
            ) == .inProcess
        )
    }

    @Test func emptyAdvertisedServiceSemverIsInProcess() {
        #expect(
            EvaluationRoute.path(
                for: .reply(
                    clientSemver: ProtocolVersion.serviceSemver,
                    advertisedServiceSemver: ""
                )
            ) == .inProcess
        )
    }

    @Test func unparseableAdvertisedServiceSemverIsInProcess() {
        #expect(
            EvaluationRoute.path(
                for: .reply(
                    clientSemver: ProtocolVersion.serviceSemver,
                    advertisedServiceSemver: "not-a-version"
                )
            ) == .inProcess
        )
    }

    @Test func emptyClientSemverIsInProcess() {
        #expect(
            EvaluationRoute.path(
                for: .reply(clientSemver: "", advertisedServiceSemver: "1.0.0")
            ) == .inProcess
        )
    }

    @Test func unparseableClientSemverIsInProcess() {
        #expect(
            EvaluationRoute.path(
                for: .reply(
                    clientSemver: "not-a-version",
                    advertisedServiceSemver: "1.0.0"
                )
            ) == .inProcess
        )
    }

    @Test func equalMajorVersionsUseXPC() {
        #expect(
            EvaluationRoute.path(
                for: .reply(clientSemver: "1.0.0", advertisedServiceSemver: "1.9.9")
            ) == .service
        )
    }

    @Test func differentMajorVersionsUseInProcess() {
        #expect(
            EvaluationRoute.path(
                for: .reply(clientSemver: "1.0.0", advertisedServiceSemver: "2.0.0")
            ) == .inProcess
        )
    }

    /// Parity lock with Sources/rv-c/tests/evaluation_route_test.c: both
    /// harnesses consume evaluation_route_vectors.tsv, so a vector they
    /// disagree on fails both suites. A missing vectors file fails loudly.
    @Test func sharedVectorsMatchCImplementation() throws {
        let vectorsURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources/rv-c/tests/evaluation_route_vectors.tsv")
        let text = try #require(
            try? String(contentsOf: vectorsURL, encoding: .utf8),
            "evaluation_route_vectors.tsv is missing; C/Swift parity is unverified"
        )
        var cases = 0
        for line in text.split(separator: "\n") {
            if line.hasPrefix("#") || line.isEmpty {
                continue
            }
            // No trimming: leading spaces are significant vectors.
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false)
            try #require(fields.count == 3, "malformed vector row: \(line)")
            let row = fields
            let client = String(row[0])
            let serviceField = String(row[1])
            let service: String? = serviceField == "NULL" ? nil : serviceField
            let want: EvaluationPath
            switch row[2] {
            case "service": want = .service
            case "inProcess": want = .inProcess
            default: throw VectorsError.unknownExpectation(String(line))
            }
            #expect(
                EvaluationRoute.path(for: .reply(clientSemver: client, advertisedServiceSemver: service))
                    == want,
                "vector mismatch: \(line)"
            )
            cases += 1
        }
        #expect(cases > 0, "vectors file contributed zero cases")
    }
}

private enum VectorsError: Error {
    case unknownExpectation(String)
}
