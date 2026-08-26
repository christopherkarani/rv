import Testing
@testable import RVDomain

@Test func scanBounds_defaultsMatchREQ016() {
    let bounds = ScanBounds.default
    #expect(bounds.maxDepth == 8)
    #expect(bounds.maxFiles == 10_000)
    #expect(bounds.maxTotalBytes == 268_435_456)
    #expect(bounds.maxFileBytes == 33_554_432)
    #expect(ScanBounds() == bounds)
}

@Test func scanHostID_rawValuesMatchSpec() {
    #expect(ScanHostID.claude.rawValue == "claude")
    #expect(ScanHostID.pi.rawValue == "pi")
    #expect(ScanHostID.grok.rawValue == "grok")
    #expect(ScanHostID.opencode.rawValue == "opencode")
    #expect(ScanHostID.openclaw.rawValue == "openclaw")
}

@Test func scanHome_rejectsEmptyPath() {
    #expect(ScanHome(validating: "") == nil)
}

@Test func scanHome_acceptsNonEmptyPath() throws {
    let home = try #require(ScanHome(validating: "/tmp/rv-scan-home"))
    #expect(home.path == "/tmp/rv-scan-home")
}

@Test func scanTypes_areSendableValueTypes() throws {
    let bounds: any Sendable = ScanBounds.default
    let host: any Sendable = ScanHostID.opencode
    let home: any Sendable = try #require(ScanHome(validating: "/tmp/h"))
    _ = (bounds, host, home)
}
