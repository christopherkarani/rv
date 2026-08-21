import RVDomain
import RVPresentation
import Testing
@testable import RVCLI

@Test func packsListPretty_usesPacksRendererLayout() {
    let model = packsViewModel(
        enabled: [.coreFilesystem, .coreGit],
        catalog: [
            (.coreFilesystem, "filesystem"),
            (.coreGit, "git"),
        ]
    )
    let text = PacksListFormat.pretty(model, appearance: .robot)
    #expect(text.contains("core.filesystem"))
    #expect(text.contains("core.git"))
    #expect(text.contains("on"))
    #expect(text.hasPrefix("on ") == false)
    #expect(text.contains("core.filesystem  on") || text.contains("core.filesystem on"))
}
