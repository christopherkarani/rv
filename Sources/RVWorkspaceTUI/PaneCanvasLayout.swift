#if os(macOS)
import SwiftTUICLI

struct PaneLayoutID: LayoutValueKey {
    static let defaultValue: PaneID? = nil
}

/// Places a flat set of stable PaneID children from precomputed pure geometry.
/// SwiftTUI may run this on a frame worker, so it holds no model or I/O reference.
struct PaneCanvasLayout: Layout {
    let viewport: CellRect
    let placements: [PanePlacement]

    func sizeThatFits(proposal: ProposedViewSize, subviews: LayoutSubviews,
                      cache: inout Void) -> LayoutSize {
        LayoutSize(width: viewport.width, height: viewport.height)
    }

    func placeSubviews(in bounds: LayoutRect, proposal: ProposedViewSize,
                       subviews: LayoutSubviews, cache: inout Void) {
        for subview in subviews {
            guard let id = subview[PaneLayoutID.self],
                  let placement = placements.first(where: { $0.id == id }) else { continue }
            subview.place(
                at: LayoutPoint(x: bounds.origin.x + placement.outer.x,
                                y: bounds.origin.y + placement.outer.y),
                proposal: ProposedViewSize(width: placement.outer.width,
                                           height: placement.outer.height)
            )
        }
    }
}
#endif
