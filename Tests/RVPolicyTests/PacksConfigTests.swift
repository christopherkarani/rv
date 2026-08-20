import Testing
import RVDomain
import RVPolicy

@Test func packsConfig_parseRoundTripEmpty() {
    let config = PacksConfig.empty
    let text = PacksConfigStore.render(config)
    #expect(PacksConfigStore.parse(text) == config)
}

@Test func packsConfig_mergePreservesSiblingSections() {
    let existing = """
    [theme]
    mode = "dark"

    [packs]
    enabled = ["database.sqlite"]
    disabled = []

    [history]
    enabled = false
    """
    let merged = PacksConfigStore.mergePacksSection(
        existing: existing,
        config: PacksConfig(enabled: ["kubernetes"], disabled: ["database.redis"])
    )
    #expect(merged.contains("[theme]"))
    #expect(merged.contains("mode = \"dark\""))
    #expect(merged.contains("[history]"))
    #expect(merged.contains("enabled = false"))
    let packs = PacksConfigStore.parse(merged)
    #expect(packs.enabled == ["kubernetes"])
    #expect(packs.disabled == ["database.redis"])
    #expect(!merged.contains("database.sqlite"))
}

@Test func packsConfig_mergeIntoEmptyExisting() {
    let merged = PacksConfigStore.mergePacksSection(
        existing: "   \n",
        config: PacksConfig(enabled: ["containers.docker"], disabled: [])
    )
    #expect(merged.hasPrefix("[packs]"))
    #expect(PacksConfigStore.parse(merged).enabled == ["containers.docker"])
}
