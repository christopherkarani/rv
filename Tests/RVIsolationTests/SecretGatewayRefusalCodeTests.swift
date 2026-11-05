import Foundation
import Testing
@testable import RVIsolation

/// Pins the audit/OCSF spelling of every gateway refusal. Audit detail, OCSF
/// finding types and SIEM rules key on these strings.
@Suite("GatewayRefusalCodes")
struct SecretGatewayRefusalCodeTests {
    static let golden: [(GatewayRefusal, String)] = [
        (.malformed, "malformed"),
        (.unknownRoute, "unknownRoute"),
        (.noPlaceholder, "noPlaceholder"),
        (.unknownPlaceholder, "unknownPlaceholder"),
        (.foreignPlaceholder, "foreignPlaceholder"),
        (.tooLarge, "tooLarge"),
        (.unsafeValue, "unsafeValue"),
        (.echoMethod, "echoMethod"),
        (.encodedPlaceholder, "encodedPlaceholder"),
        (.surfaceNotAllowed, "surfaceNotAllowed"),
        (.repeatedPlaceholder, "repeatedPlaceholder"),
        (.outsideAllowRules, "outsideAllowRules"),
        (.ambiguousPath, "ambiguousPath"),
        (.auditUnavailable, "auditUnavailable"),
        (.runtimeMismatch, "runtimeMismatch"),
        (.runtimeUnverified, "runtimeUnverified"),
        (.expired, "expired"),
        (.refreshFailed, "refreshFailed"),
        (.awsKeyMismatch, "awsKeyMismatch"),
        (.awsSignedStreaming, "awsSignedStreaming"),
        (.approvalPending, "approvalPending"),
        (.approvalDenied, "approvalDenied"),
        (.approvalUnavailable, "approvalUnavailable"),
        (.binaryMismatch, "binaryMismatch"),
        (.awsUnsignedPayload, "awsUnsignedPayload"),
        (.awsCredentialsInResponse, "awsCredentialsInResponse"),
    ]

    @Test func everyRefusalCodeIsPinned() {
        for (refusal, code) in Self.golden {
            #expect(refusal.code == code)
        }
    }

    @Test func misuseSetIsPinned() {
        let misuse = Self.golden.filter { $0.0.isMisuse }.map(\.1)
        #expect(misuse == [
            "foreignPlaceholder", "echoMethod", "encodedPlaceholder", "surfaceNotAllowed", "repeatedPlaceholder",
            "outsideAllowRules", "ambiguousPath", "runtimeMismatch", "awsKeyMismatch", "binaryMismatch",
        ])
    }

    @Test func goldenCoversEveryCase() {
        #expect(Set(Self.golden.map(\.0)) == Set(GatewayRefusal.allCases))
        #expect(Self.golden.count == GatewayRefusal.allCases.count)
    }

    @Test func recordedRefusalReachesAuditDetailVerbatim() throws {
        for (refusal, code) in Self.golden {
            let record = SecretUseRecord(
                secret: "K", runtime: "r", upstreamHost: nil, method: "GET", path: "/p", status: refusal.status,
                upstreamStatus: nil, activity: .blocked, refusal: refusal, reason: refusal.reason, surfaces: [],
                fingerprint: nil, responseBytes: 0, durationMilliseconds: 0, stage: .complete)
            #expect(SecretLaunchBroker.auditEvent(record, workspace: nil).detail["refusal"] == code)
            #expect(SecretLaunchBroker.misuseEvent(record, workspace: nil)?.detail["refusal"] == code)
        }
    }

    /// A blocked request always raises the misuse finding, even if no refusal
    /// was recorded: the alert fails closed rather than going silent.
    @Test func blockedWithoutRefusalStillRaisesMisuse() throws {
        let record = SecretUseRecord(
            secret: "K", runtime: "r", upstreamHost: nil, method: "GET", path: "/p", status: 403,
            upstreamStatus: nil, activity: .blocked, refusal: nil, reason: nil, surfaces: [],
            fingerprint: nil, responseBytes: 0, durationMilliseconds: 0, stage: .complete)
        let event = try #require(SecretLaunchBroker.misuseEvent(record, workspace: nil))
        #expect(event.kind == .secretMisuse)
        #expect(event.detail == ["method": "GET", "path": "/p", "severity": "high"])
    }
}
