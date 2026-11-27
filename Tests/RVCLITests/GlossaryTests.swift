import Foundation
import RVDomain
import RVPresentation
import RVTheme
import Testing
@testable import RVCLI

/// One glossary: `rv explain --help` and the README name the same words,
/// and every glyph rv draws is on it.
@Suite("rv's glossary")
struct GlossaryTests {
    @Test("rv explain --help ends with the glossary")
    func explainHelpShowsTheWords() {
        let page = HelpCatalog.page(.explain)
        #expect(page.sections.last == HelpCatalog.glossary)
        let text = HelpDispatch.text(.explain, palette: colorOffPalette)
        #expect(text.contains("\nWords\n"))
        #expect(text.contains("  ✕ stopped     rv stopped the command. It did not run\n"))
    }

    @Test("every glyph and both host modes are defined")
    func everyGlyphIsDefined() {
        let names = HelpCatalog.glossary.rows.map(\.name)
        for glyph in CommandVocabulary.Glyph.allCases {
            #expect(names.contains { $0.hasPrefix(glyph.rawValue + " ") }, "glossary missing \(glyph)")
        }
        #expect(names.contains(CommandVocabulary.PlannedWord.guarding))
        #expect(names.contains(CommandVocabulary.PlannedWord.watching))
    }

    @Test("the README's word table names every glossary word")
    func readmeHasTheWords() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let readme = try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8)
        let section = try #require(readme.components(separatedBy: "## Words rv uses\n").dropFirst().first)
        let table = section.components(separatedBy: "\n## ").first ?? section
        for row in HelpCatalog.glossary.rows {
            #expect(table.contains("| \(row.name) |"), "README glossary missing \(row.name)")
        }
    }
}
