public import SwiftTUICore

extension View {
  /// Receives one terminal bracketed-paste payload while this view or its
  /// hosted content has focus. The payload preserves newlines and Unicode.
  /// File-drop destinations get the first chance to claim path-shaped input.
  @MainActor
  public func onPaste(
    perform action: @escaping @MainActor @Sendable (String) -> KeyPressResult
  ) -> ModifiedContent<Self, PasteModifier> {
    modifier(
      PasteModifier(
        authoringContext: currentImperativeAuthoringContextSnapshot(),
        action: action
      )
    )
  }
}

public struct PasteModifier: IterativePrimitiveViewModifier, Sendable {
  package let authoringContext: ImperativeAuthoringContextSnapshot?
  package let action: @MainActor @Sendable (String) -> KeyPressResult

  package init(
    authoringContext: ImperativeAuthoringContextSnapshot?,
    action: @escaping @MainActor @Sendable (String) -> KeyPressResult
  ) {
    self.authoringContext = authoringContext
    self.action = action
  }

  package func makeResolveWork<Content: View>(
    content: ModifierContentInputs<Content>,
    in context: ResolveContext
  ) -> ResolveWork<[ResolvedNode]> {
    content.resolveWork(in: context).map { node in
      guard context.environmentValues.isEnabled else { return [node] }
      let intake = HandlerDescriptorIntake(
        context: context,
        preferringSnapshot: authoringContext
      )
      intake.registerPasteHandler(identity: node.identity) { pasted in
        action(pasted) == .handled
      }
      return [node]
    }
  }
}
