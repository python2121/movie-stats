import AppKit
import SwiftUI

/// A thin vertical drag handle for resizing the AI side panel. A 1pt visible
/// line sits centred inside a wider invisible hit area so it's easy to grab.
///
/// Resize math uses absolute translation in `.global` coordinate space and a
/// snapshotted start width. Without that, the handle drifts: the gesture's
/// `.local` translation is measured relative to the handle's frame, and the
/// handle moves as the panel resizes — feeding the deltas back to itself and
/// producing the jitter.
struct ResizeHandle: View {
    /// The panel's current width — snapshotted at drag start and used as the
    /// origin for absolute width calculations during the drag.
    let currentWidth: CGFloat
    /// Fires with the proposed new width on every frame of the drag.
    let onResize: (CGFloat) -> Void
    let onDragEnded: () -> Void

    private static let hitWidth: CGFloat = 6

    @State private var dragStartWidth: CGFloat?

    var body: some View {
        ZStack {
            // Invisible hit area so the 1pt line is easier to grab.
            Color.clear
                .frame(width: Self.hitWidth)

            // The visible separator line. Explicit Rectangle (not Divider)
            // so we get a vertical line regardless of stack context.
            Rectangle()
                .fill(Color(NSColor.separatorColor))
                .frame(width: 1)
        }
        .frame(width: Self.hitWidth)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if dragStartWidth == nil {
                        dragStartWidth = currentWidth
                    }
                    guard let startWidth = dragStartWidth else { return }
                    // Cursor moved RIGHT by `translation.width` ⇒ panel
                    // should shrink by that much (handle sits on the panel's
                    // left edge).
                    onResize(startWidth - value.translation.width)
                }
                .onEnded { _ in
                    dragStartWidth = nil
                    onDragEnded()
                }
        )
    }
}
