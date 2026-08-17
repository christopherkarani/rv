import Testing
@testable import RVTUI

@Test func emptyModule_compiles() {
    let _: RVTUI.Type = RVTUI.self
}
