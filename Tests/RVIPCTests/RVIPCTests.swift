import Testing
@testable import RVIPC

@Test func emptyModule_compiles() {
    let _: RVIPC.Type = RVIPC.self
}
