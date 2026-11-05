import Foundation
import Testing
import RVIPC

/// Pins the exact JSON bytes of the host prepare-refusal and redeem-outcome
/// response DTOs for every vocabulary value. Written against the String-typed
/// fields and kept unchanged across the typing refactor: it only round-trips
/// JSON literals, so it compiles and must pass on both sides.
@Suite("Host outcome vocabulary golden bytes")
struct HostOutcomeVocabularyGoldenTests {
    static let refusals = [
        "notAccepting", "invalidRequest", "preparationFailed", "unknownDefinition",
        "invalidDefinition", "projectNotEligible", "executableUnavailable",
        "invalidExecutable", "unsupportedExecutable", "credentialDeferred",
        "invalidDigest", "refused",
    ]
    static let outcomes = ["unknown", "alreadyAccepted", "launchFailed"]

    private func reencode<T: Codable>(_ type: T.Type, _ literal: String) throws -> String {
        let decoded = try IPCJSON.decode(type, from: Data(literal.utf8))
        return String(decoding: try IPCJSON.encode(decoded), as: UTF8.self)
    }

    @Test(arguments: refusals)
    func prepareRefusalBytes(_ raw: String) throws {
        let literal = "{\"error\":\"\(raw)\"}"
        #expect(try reencode(HostPrepareResponseDTO.self, literal) == literal)
    }

    @Test func prepareNoErrorBytes() throws {
        #expect(try reencode(HostPrepareResponseDTO.self, "{}") == "{}")
    }

    @Test(arguments: outcomes)
    func redeemOutcomeBytes(_ raw: String) throws {
        for accepted in ["true", "false"] {
            let literal = "{\"accepted\":\(accepted),\"error\":\"\(raw)\"}"
            #expect(try reencode(HostRedeemResponseDTO.self, literal) == literal)
        }
    }

    @Test func redeemSuccessBytes() throws {
        let literal = "{\"accepted\":true,\"agentInstanceID\":\"00000000-0000-0000-0000-000000000002\","
            + "\"runtimeSessionID\":\"00000000-0000-0000-0000-000000000001\"}"
        #expect(try reencode(HostRedeemResponseDTO.self, literal) == literal)
    }
}
