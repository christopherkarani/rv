# SwiftTUI source pin for RV

This directory copies SwiftTUI 0.14.0 at upstream commit
`581c3ab7e2383ce86fcebe36e81041aecac443a5`, including its license and
vendored dependencies. Git history and build caches are excluded.

RV adds a public `View.onPaste` modifier and routes a focused paste through
ancestor handlers. The terminal reader, parser, and paste event remain owned
by SwiftTUI. The modifier delivers the original multiline Unicode payload
once; RV forwards it through the focused pane's existing input path.

The RV patch changes only:

- `Sources/SwiftTUIViews/Input/PasteModifier.swift` (new)
- `Sources/SwiftTUIRuntime/RunLoop/RunLoop+EventDispatch.swift`
- `Tests/SwiftTUITests/DropDestinationDispatchTests.swift`

Replace the local package with an upstream release once the same public paste
contract and ancestor dispatch are available there.
