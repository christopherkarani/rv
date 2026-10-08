import Foundation
import Testing
@testable import RVDomain

@Test func principalReferenceRoundTripsAllFiveNames() throws {
    let reference = AgentPrincipalReference(
        agentInstanceID: AgentInstanceID(), runtimeSessionID: RuntimeSessionID(),
        workspaceSessionID: WorkspaceSessionID(), workspaceHostID: WorkspaceHostID(),
        workspaceHostGeneration: WorkspaceHostGeneration()
    )
    let data = try JSONEncoder().encode(reference)
    #expect(try JSONDecoder().decode(AgentPrincipalReference.self, from: data) == reference)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object.count == 5)
    #expect(object["capability"] == nil)
    #expect(object["secret"] == nil)
}

@Test func principalReferenceRequiresGeneration() throws {
    let object: [String: String] = [
        "agentInstanceID": UUID().uuidString, "runtimeSessionID": UUID().uuidString,
        "workspaceSessionID": UUID().uuidString, "workspaceHostID": UUID().uuidString,
    ]
    let data = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(AgentPrincipalReference.self, from: data)
    }
}

@Test func hostIncarnationsHaveDistinctGeneration() {
    #expect(WorkspaceHostGeneration() != WorkspaceHostGeneration())
}
