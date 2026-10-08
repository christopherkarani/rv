import Foundation
import Testing
import RVDomain
@testable import RVIPC

/// Step 8 F1: the hook-evaluate wire carries a closed host family. Unknown
/// or malformed hosts fail decode — they never reach a pause profile and
/// can never select quiet-allow.
struct HookEvaluateHostBoundaryTests {
    @Test(arguments: ["evil", "", "GROK", " grok", "grok ", "claude-code"])
    func unknownHost_failsDecode(_ raw: String) throws {
        let json = Data(
            #"{"host":"\#(raw)","stdin":"{}"}"#.utf8
        )
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(HookEvaluateParams.self, from: json)
        }
    }

    @Test(arguments: HookHost.allCases)
    func knownHost_decodes(_ host: HookHost) throws {
        let json = Data(
            #"{"host":"\#(host.rawValue)","stdin":"{}"}"#.utf8
        )
        let decoded = try JSONDecoder().decode(HookEvaluateParams.self, from: json)
        #expect(decoded.host == host)
    }

    @Test func missingHost_failsDecode() {
        #expect(throws: DecodingError.self) {
            _ = try JSONDecoder().decode(
                HookEvaluateParams.self, from: Data(#"{"stdin":"{}"}"#.utf8)
            )
        }
    }
}
