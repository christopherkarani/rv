import Testing
import RVDomain
@testable import RVPacks

@Test func selectionToken_parseClassifiesPackCategoryAndPreset() throws {
    let index = try PackRegistry.loadIndex()
    #expect(
        SelectionToken.parse("database.redis", index: index)
            == [.id(PackID(rawValue: "database.redis"))]
    )
    #expect(SelectionToken.parse("database", index: index) == [.category("database")])
    #expect(
        SelectionToken.parse("careful_company_running_windows", index: index)
            == [
                .category("careful_company_running_windows"),
                .preset("careful_company_running_windows"),
            ]
    )
}

@Test func selectionToken_parseKeepsOverlappingPackAndCategoryAdditive() throws {
    let index = try PackRegistry.loadIndex()
    let tokens = SelectionToken.parse("strict_git", index: index)
    #expect(Set(tokens) == [
        .id(PackID(rawValue: "strict_git")),
        .category("strict_git"),
    ])
    let expanded = try PackSet.expand(tokens, index: index, rejectUnknown: true)
    #expect(expanded == [PackID(rawValue: "strict_git")])
}

@Test func selectionToken_unknownBecomesIDCarryingOperatorSpelling() throws {
    let index = try PackRegistry.loadIndex()
    #expect(
        SelectionToken.parse("paranoid", index: index)
            == [.id(PackID(rawValue: "paranoid"))]
    )
    #expect(
        SelectionToken.parse("Not A Pack!", index: index)
            == [.id(PackID(rawValue: "Not A Pack!"))]
    )
}

@Test func selectionToken_rawValueRoundTripsThroughParse() throws {
    let index = try PackRegistry.loadIndex()
    for raw in ["database.redis", "database", "careful_company_running_windows"] {
        for token in SelectionToken.parse(raw, index: index) {
            #expect(token.rawValue == raw)
        }
    }
    #expect(SelectionToken.category("solo").rawValue == "solo")
    #expect(SelectionToken.preset("solo").rawValue == "solo")
}

@Test func packIndex_packIDsArePackID() throws {
    let index = try PackRegistry.loadIndex()
    #expect(index.packIDs.contains(.coreGit))
    #expect(index.packIDs.contains(.coreFilesystem))
    let catalog = PackCatalog.bundlingAll(enabled: [.coreGit], index: index)
    #expect(catalog.enabledIDs.contains(.coreGit))
}
