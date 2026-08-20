import RVHooks
import Testing

@Test(arguments: [HookHost.grok, .pi, .opencode])
func hostAdapter_bakedRvPath_roundTripsAllResources(host: HookHost) throws {
    let adapter = try HostAdapterResources.load(for: host)
    let rvPath = "/Applications/rv/bin/rv"
    let rendered = adapter.rendered(rvPath: rvPath)

    #expect(adapter.bakedRvPath(in: rendered) == rvPath)
}

@Test(arguments: [HookHost.grok, .pi, .opencode])
func hostAdapter_bakedRvPath_rejectsModifiedAndForeignBytes(host: HookHost) throws {
    let adapter = try HostAdapterResources.load(for: host)
    let rendered = adapter.rendered(rvPath: "/opt/rv/bin/rv")

    #expect(adapter.bakedRvPath(in: rendered + "\nforeign edit") == nil)
    #expect(adapter.bakedRvPath(in: "foreign adapter") == nil)
}

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
