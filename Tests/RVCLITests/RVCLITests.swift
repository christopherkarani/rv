import Testing
@testable import RVCLI

@Test func emptyModule_compiles() {
    let _: RVCLI.Type = RVCLI.self
}
