import Foundation
import RVDomain
import Testing
@testable import RVIsolation

/// Body construction and oracle rules for the egress refusal response.
struct EgressDenialResponseTests {
    private func json(_ response: EgressDenialResponse) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: Data(response.body))
        return try #require(object as? [String: Any])
    }

    private func text(_ response: EgressDenialResponse) -> String {
        String(decoding: response.bytes, as: UTF8.self)
    }

    @Test func policyDenialWithProposalNamesTheApproveCommand() throws {
        let id = "0B5E1A2C-3D4E-4F60-8A9B-0C1D2E3F4A5B"
        let response = EgressDenialResponse(
            reason: .deniedPolicy, host: "Blocked.Example", port: 443, proposalID: id)
        let body = try json(response)
        #expect(body["schema"] as? String == "rv.egress.denied.v1")
        #expect(body["reason"] as? String == "denied-policy")
        #expect(body["host"] as? String == "blocked.example")
        #expect(body["port"] as? Int == 443)
        #expect(body["proposal_id"] as? String == id)
        #expect(body["next_step"] as? String == "rv egress approve \(id)")
        #expect((body["message"] as? String)?.isEmpty == false)
        let wire = text(response)
        #expect(wire.hasPrefix("HTTP/1.1 403 Forbidden\r\n"))
        #expect(wire.contains("\r\nContent-Type: application/json\r\n"))
        #expect(wire.contains("\r\nContent-Length: \(response.body.count)\r\n"))
        #expect(wire.contains("\r\nConnection: close\r\n\r\n"))
        #expect(wire.contains(
            "\r\nProxy-Status: rv-egress; error=http_request_denied; details=\"denied-policy; run: rv egress approve \(id)\"\r\n"))
        #expect(wire.hasSuffix(String(decoding: response.body, as: UTF8.self)))
    }

    @Test func policyDenialWithoutProposalPointsAtDenials() throws {
        let body = try json(EgressDenialResponse(reason: .deniedPolicy, host: "a.example", port: 443))
        #expect(body["proposal_id"] == nil)
        #expect(body["next_step"] as? String == "rv egress denials")
    }

    @Test func eachRecordedReasonMapsToItsWireShape() throws {
        let expectations: [(EgressDenialReason, String, String, String?)] = [
            (.deniedPolicy, "denied-policy", "http_request_denied", "rv egress denials"),
            (.binaryMismatch, "denied-policy", "http_request_denied", "rv egress denials"),
            (.unattributedPeer, "denied-policy", "http_request_denied", "rv egress denials"),
            (.sniMismatch, "denied-policy", "http_request_denied", "rv egress denials"),
            (.dnsFailed, "dial-failed", "destination_unavailable", "rv egress denials"),
            (.addressFiltered, "dial-failed", "destination_unavailable", "rv egress denials"),
            (.dialFailed, "dial-failed", "destination_unavailable", "rv egress denials"),
            (.headerTooLarge, "header-too-large", "http_request_error", nil),
            (.malformed, "malformed", "http_request_error", nil),
            (.deniedCredential, "denied-credential", "http_request_denied", "rv egress denials"),
        ]
        #expect(expectations.count == EgressDenialReason.allCases.count)
        for (recorded, wire, proxyError, next) in expectations {
            let response = EgressDenialResponse(reason: recorded, host: "h.example", port: 443)
            let body = try json(response)
            #expect(body["reason"] as? String == wire, "\(recorded)")
            #expect(body["next_step"] as? String == next, "\(recorded)")
            #expect(response.proxyStatusError == proxyError, "\(recorded)")
        }
    }

    @Test func credentialDenialIs407WithChallenge() {
        let wire = text(EgressDenialResponse(reason: .deniedCredential, host: "a.example", port: 443))
        #expect(wire.hasPrefix("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Bearer\r\n"))
        #expect(wire.contains("\"reason\":\"denied-credential\""))
    }

    // Oracle: binary and pin state must never reach the cage. Both binary
    // reasons hide behind a proposal-less policy denial, byte for byte, and
    // a proposal id offered to them is dropped.
    @Test func binaryDenialsAreByteIdenticalToProposalLessPolicyDenial() {
        let policy = EgressDenialResponse(reason: .deniedPolicy, host: "api.example", port: 443).bytes
        for reason in [EgressDenialReason.binaryMismatch, .unattributedPeer] {
            #expect(EgressDenialResponse(reason: reason, host: "api.example", port: 443).bytes == policy)
            #expect(
                EgressDenialResponse(
                    reason: reason, host: "api.example", port: 443,
                    proposalID: "0B5E1A2C-3D4E-4F60-8A9B-0C1D2E3F4A5B"
                ).bytes == policy,
                "binary denials must not carry a proposal")
        }
    }

    // Oracle: DNS existence and private-address resolution of a name stay
    // off the wire; all three dial outcomes are the old catch-all.
    @Test func resolverOutcomesAreByteIdentical() {
        let dial = EgressDenialResponse(reason: .dialFailed, host: "intranet.corp", port: 443).bytes
        #expect(EgressDenialResponse(reason: .dnsFailed, host: "intranet.corp", port: 443).bytes == dial)
        #expect(EgressDenialResponse(reason: .addressFiltered, host: "intranet.corp", port: 443).bytes == dial)
    }

    @Test func proposalIDsOnlyRideValidPolicyDenials() throws {
        for bad in ["", "../etc", "id with space", "a\"b", String(repeating: "A", count: 65), "\u{1b}[31m"] {
            let body = try json(EgressDenialResponse(reason: .deniedPolicy, host: "a.example", port: 443, proposalID: bad))
            #expect(body["proposal_id"] == nil, "\(bad)")
            #expect(body["next_step"] as? String == "rv egress denials")
        }
        let dial = try json(EgressDenialResponse(reason: .dialFailed, host: "a.example", port: 443, proposalID: "ABC-1"))
        #expect(dial["proposal_id"] == nil)
    }

    @Test func unsafeHostsAreOmittedNotEchoed() throws {
        for host in [
            "", "a\"b.example", "a\\b", "evil\u{1b}]0;x\u{07}.example", "ex ample", "exämple.com",
            "a/b", String(repeating: "a", count: 254),
        ] {
            let response = EgressDenialResponse(reason: .deniedPolicy, host: host, port: 443)
            let body = try json(response)
            #expect(body["host"] == nil, "\(host.debugDescription)")
            #expect(body["port"] as? Int == 443)
        }
        let longest = String(repeating: "a", count: 253)
        let body = try json(EgressDenialResponse(reason: .deniedPolicy, host: longest, port: 443))
        #expect(body["host"] as? String == longest)
    }

    @Test func emptyTargetsOmitHostAndPort() throws {
        let body = try json(EgressDenialResponse(reason: .malformed, host: "", port: 0))
        #expect(body["host"] == nil)
        #expect(body["port"] == nil)
        #expect(body["reason"] as? String == "malformed")
    }

    @Test func bodyStaysBoundedAtTheLargestInputs() {
        let response = EgressDenialResponse(
            reason: .deniedPolicy, host: String(repeating: "a", count: 253), port: 65535,
            proposalID: String(repeating: "F", count: 64))
        #expect(response.body.count <= EgressDenialResponse.maximumBodyBytes)
        #expect(response.bytes.count <= 2048)
    }

    @Test func bodiesNeverCarryPathsOrSecrets() {
        for reason in EgressDenialReason.allCases {
            let wire = text(EgressDenialResponse(reason: reason, host: "a.example", port: 443))
            #expect(wire.contains("/opt") == false)
            #expect(wire.contains("binary") == false, "\(reason)")
            #expect(wire.contains("\"/") == false, "\(reason)")
        }
    }

    @Test func jsonStringEscapesEverythingUnsafe() {
        #expect(EgressDenialResponse.jsonString("a\"b\\c\n\u{1b}é") == "\"a\\\"b\\\\c\\u000a\\u001b\\u00e9\"")
    }
}
