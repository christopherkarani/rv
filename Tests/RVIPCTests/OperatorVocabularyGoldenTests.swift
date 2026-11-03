import Foundation
import Testing
import RVDomain
import RVIPC

/// Pins the exact JSON bytes of the closed operator vocabularies (launch
/// kind, ask reason) as they travel through XPC DTOs, so typing them cannot
/// change the wire.
@Suite("Operator vocabulary golden bytes")
struct OperatorVocabularyGoldenTests {
    private static let id = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!

    private static let proposeNamed = "{\"arguments\":[\"a\"],\"definitionID\":\"d\",\"io\":{\"discard\":{}},\"kind\":\"named\",\"workspace\":\"\\/w\"}"
    private static let proposeCustom = "{\"arguments\":[],\"executable\":\"\\/bin\\/x\",\"expectedDigest\":\"ab\",\"io\":{\"discard\":{}},\"kind\":\"custom\",\"workspace\":\"\\/w\"}"
    private static let prepareNamed = "{\"arguments\":[],\"definitionID\":\"d\",\"io\":{\"discard\":{}},\"kind\":\"named\",\"requestID\":\"00000000-0000-0000-0000-000000000001\"}"
    private static let prepareCustom = "{\"arguments\":[],\"executable\":\"\\/bin\\/x\",\"expectedDigest\":\"ab\",\"io\":{\"discard\":{}},\"kind\":\"custom\",\"requestID\":\"00000000-0000-0000-0000-000000000001\"}"
    private static let descriptionNamed = "{\"arguments\":[],\"environmentDigestHex\":\"00\",\"environmentPolicy\":\"containedProjectionV1\",\"executable\":\"\\/bin\\/x\",\"expiresAt\":1,\"generation\":\"00000000-0000-0000-0000-000000000001\",\"hostID\":\"00000000-0000-0000-0000-000000000001\",\"intentDigestHex\":\"00\",\"io\":{\"discard\":{}},\"preparedAt\":0,\"preparedID\":\"00000000-0000-0000-0000-000000000001\",\"target\":\"named\",\"workingDirectory\":\"\\/w\",\"workspaceSessionID\":\"00000000-0000-0000-0000-000000000001\"}"
    private static let descriptionCustom = "{\"arguments\":[],\"environmentDigestHex\":\"00\",\"environmentPolicy\":\"containedProjectionV1\",\"executable\":\"\\/bin\\/x\",\"expiresAt\":1,\"generation\":\"00000000-0000-0000-0000-000000000001\",\"hostID\":\"00000000-0000-0000-0000-000000000001\",\"intentDigestHex\":\"00\",\"io\":{\"discard\":{}},\"preparedAt\":0,\"preparedID\":\"00000000-0000-0000-0000-000000000001\",\"target\":\"custom\",\"workingDirectory\":\"\\/w\",\"workspaceSessionID\":\"00000000-0000-0000-0000-000000000001\"}"

    private func json<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try IPCJSON.encode(value), as: UTF8.self)
    }

    @Test func proposeLaunchParamsBytes() throws {
        let named = ProposeLaunchParams(
            workspace: "/w", kind: .named, definitionID: "d", arguments: ["a"])
        #expect(try json(named) == Self.proposeNamed)
        let custom = ProposeLaunchParams(
            workspace: "/w", kind: .custom, executable: "/bin/x", expectedDigest: "ab")
        #expect(try json(custom) == Self.proposeCustom)
        for literal in [Self.proposeNamed, Self.proposeCustom] {
            let decoded = try IPCJSON.decode(ProposeLaunchParams.self, from: Data(literal.utf8))
            #expect(try json(decoded) == literal)
        }
    }

    @Test func hostPrepareRequestBytes() throws {
        let named = HostPrepareRequestDTO(
            requestID: Self.id, kind: .named, definitionID: "d", executable: nil,
            expectedDigest: nil, arguments: [], io: .discard)
        #expect(try json(named) == Self.prepareNamed)
        let custom = HostPrepareRequestDTO(
            requestID: Self.id, kind: .custom, definitionID: nil, executable: "/bin/x",
            expectedDigest: "ab", arguments: [], io: .discard)
        #expect(try json(custom) == Self.prepareCustom)
        for literal in [Self.prepareNamed, Self.prepareCustom] {
            let decoded = try IPCJSON.decode(HostPrepareRequestDTO.self, from: Data(literal.utf8))
            #expect(try json(decoded) == literal)
        }
    }

    @Test func hostPreparedDescriptionTargetBytes() throws {
        for (target, literal) in [
            (WorkspaceLaunchKind.named, Self.descriptionNamed),
            (WorkspaceLaunchKind.custom, Self.descriptionCustom),
        ] {
            let dto = HostPreparedDescriptionDTO(
                workspaceSessionID: Self.id, hostID: Self.id, generation: Self.id,
                preparedID: Self.id, requestID: nil, target: target, definitionID: nil,
                revisionDigest: nil, executable: "/bin/x", expectedDigest: nil,
                workingDirectory: "/w", arguments: [], io: .discard,
                environmentPolicy: "containedProjectionV1", intentDigestHex: "00",
                environmentDigestHex: "00",
                preparedAt: Date(timeIntervalSinceReferenceDate: 0),
                expiresAt: Date(timeIntervalSinceReferenceDate: 1))
            #expect(try json(dto) == literal)
            let decoded = try IPCJSON.decode(
                HostPreparedDescriptionDTO.self, from: Data(literal.utf8))
            #expect(decoded == dto)
        }
    }

    @Test func unknownLaunchKindFailsDecode() {
        #expect(throws: (any Error).self) {
            try IPCJSON.decode(
                HostPrepareRequestDTO.self,
                from: Data(Self.prepareNamed.replacingOccurrences(
                    of: "\"named\"", with: "\"other\"").utf8))
        }
    }

    @Test func askReasonBytes() throws {
        let ref = AgentPrincipalReference(
            agentInstanceID: AgentInstanceID(), runtimeSessionID: RuntimeSessionID(),
            workspaceSessionID: WorkspaceSessionID(), workspaceHostID: WorkspaceHostID(),
            workspaceHostGeneration: WorkspaceHostGeneration())
        let action = ProposedAction.shell(ShellAction.effectOnly(EffectShell(
            fingerprint: ActionFingerprint(rawValue: "wire:echo"),
            scope: ActionScope(workingDirectory: WorkingDirectory(rawValue: "/work")),
            supportingCommand: ShellCommand(rawValue: "echo hello"))))
        for (reason, raw) in [(RuntimeAskReason.mandatoryHuman, "mandatoryHuman"),
                              (RuntimeAskReason.reviewAsk, "reviewAsk")] {
            let dto = HostActionApprovalCreateDTO(
                reference: ref, action: action, reason: reason, policyContext: "c",
                definitionID: AgentDefinitionID(rawValue: "a"),
                definitionRevision: AgentDefinitionRevision(
                    digestHex: String(repeating: "c", count: 64)))
            let object = try #require(
                JSONSerialization.jsonObject(with: IPCJSON.encode(dto)) as? [String: Any])
            #expect(object["reason"] as? String == raw)
            #expect(try IPCJSON.decode(
                HostActionApprovalCreateDTO.self, from: IPCJSON.encode(dto)) == dto)
        }
    }

    @Test func unknownAskReasonFailsDecode() throws {
        let ref = AgentPrincipalReference(
            agentInstanceID: AgentInstanceID(), runtimeSessionID: RuntimeSessionID(),
            workspaceSessionID: WorkspaceSessionID(), workspaceHostID: WorkspaceHostID(),
            workspaceHostGeneration: WorkspaceHostGeneration())
        let action = ProposedAction.shell(ShellAction.effectOnly(EffectShell(
            fingerprint: ActionFingerprint(rawValue: "wire:echo"),
            scope: ActionScope(workingDirectory: WorkingDirectory(rawValue: "/work")),
            supportingCommand: ShellCommand(rawValue: "echo hello"))))
        let dto = HostActionApprovalCreateDTO(
            reference: ref, action: action, reason: .reviewAsk, policyContext: "c",
            definitionID: AgentDefinitionID(rawValue: "a"),
            definitionRevision: AgentDefinitionRevision(
                digestHex: String(repeating: "c", count: 64)))
        let text = String(decoding: try IPCJSON.encode(dto), as: UTF8.self)
            .replacingOccurrences(of: "\"reviewAsk\"", with: "\"alwaysAllow\"")
        #expect(throws: (any Error).self) {
            try IPCJSON.decode(HostActionApprovalCreateDTO.self, from: Data(text.utf8))
        }
    }
}
