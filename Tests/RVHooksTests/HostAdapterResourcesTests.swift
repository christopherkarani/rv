import RVHooks
import Testing

@Test func hostAdapter_matchesCurrent_acceptsAnyBakedPath() throws {
    let adapter = try HostAdapterResources.load(for: .grok)
    let oldPath = adapter.rendered(rvPath: "/old/rv")
    let newPath = adapter.rendered(rvPath: "/new/rv")
    #expect(adapter.matchesCurrent(oldPath))
    #expect(adapter.matchesCurrent(newPath))
    #expect(adapter.matchesCurrent(oldPath + "\nextra") == false)
    #expect(adapter.matchesCurrent("{\"hooks\":[]}\n") == false)
}

@Test func hostAdapter_piAndOpenCode_matchOnlyTheirOwnRender() throws {
    let pi = try HostAdapterResources.load(for: .pi)
    let openCode = try HostAdapterResources.load(for: .opencode)
    let piBody = pi.rendered(rvPath: "/opt/rv")
    #expect(pi.matchesCurrent(piBody))
    #expect(openCode.matchesCurrent(piBody) == false)
    #expect(pi.matchesCurrent(openCode.rendered(rvPath: "/opt/rv")) == false)
}
