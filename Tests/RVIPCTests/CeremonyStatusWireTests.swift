import Foundation
import Testing
import RVDomain
import RVIPC

/// The m3 promise: typed statuses encode to byte-identical wire strings,
/// and unknown strings fail decode (closed vocabulary, HookHost-style).
struct CeremonyStatusWireTests {
    @Test func everyStatusEncodesToItsRawValue() throws {
        for status in HookReviewStatus.allCases {
            let bytes = try IPCJSON.encode(UIHookStatusDTO(approvalID: "a", status: status))
            #expect(String(data: bytes, encoding: .utf8)?.contains("\"status\":\"\(status.rawValue)\"") == true)
        }
        for status in HostActionApprovalStatus.allCases {
            let bytes = try IPCJSON.encode(HostActionApprovalStatusReplyDTO(status: status))
            #expect(String(data: bytes, encoding: .utf8)?.contains("\"status\":\"\(status.rawValue)\"") == true)
        }
        for status in WorkspaceOperationStatus.allCases {
            let bytes = try IPCJSON.encode(UIOperationStatusDTO(operationID: UUID(), status: status))
            #expect(String(data: bytes, encoding: .utf8)?.contains("\"status\":\"\(status.rawValue)\"") == true)
        }
        for result in LaunchResult.allCases {
            let bytes = try IPCJSON.encode(
                ProposalStatusReply(operationID: UUID(), status: .consumed, launchResult: result))
            #expect(String(data: bytes, encoding: .utf8)?.contains("\"launchResult\":\"\(result.rawValue)\"") == true)
        }
    }

    @Test func unknownStatusFailsDecode() throws {
        let hook = "{\"approvalID\":\"a\",\"status\":\"pendingReview\"}"
        #expect(throws: (any Error).self) {
            try IPCJSON.decode(UIHookStatusDTO.self, from: Data(hook.utf8))
        }
        let action = "{\"status\":\"pendingReview\"}"
        #expect(throws: (any Error).self) {
            try IPCJSON.decode(HostActionApprovalStatusReplyDTO.self, from: Data(action.utf8))
        }
        let operation = "{\"operationID\":\"\(UUID().uuidString)\",\"status\":\"pending\"}"
        #expect(throws: (any Error).self) {
            try IPCJSON.decode(UIOperationStatusDTO.self, from: Data(operation.utf8))
        }
    }

    @Test func legacyPayloadsStillDecode() throws {
        // Pre-m3 bytes (bare status strings) decode into the typed fields.
        let hook = "{\"approvalID\":\"a\",\"status\":\"allowedOnce\"}"
        #expect(try IPCJSON.decode(UIHookStatusDTO.self, from: Data(hook.utf8)).status == .allowedOnce)
        let action = "{\"status\":\"authorized\"}"
        #expect(try IPCJSON.decode(
            HostActionApprovalStatusReplyDTO.self, from: Data(action.utf8)).status == .authorized)
        let operation = "{\"operationID\":\"\(UUID().uuidString)\",\"status\":\"consumed\",\"launchResult\":\"launched\"}"
        let decoded = try IPCJSON.decode(ProposalStatusReply.self, from: Data(operation.utf8))
        #expect(decoded.status == .consumed)
        #expect(decoded.launchResult == .launched)
    }
}
