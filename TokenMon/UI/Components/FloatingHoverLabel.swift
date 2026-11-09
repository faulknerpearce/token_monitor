import SwiftUI

/// Placement math for a hover label floating beside the pointer.
enum HoverLabelPlacement {
    /// Gap between the pointer and the label.
    static let pointerGap: CGFloat = 14

    /// Top-left corner of a label floating beside `pointer`: to its left when
    /// it fits, else to its right, else pinned inside the container's width;
    /// vertically centered on the pointer.
    ///
    /// - Parameter maxY: When set, the label is raised so its bottom edge does
    ///   not pass this y, for a container near the bottom of the panel where
    ///   a label hanging below it would be cut off. Nil keeps it centered.
    static func labelOrigin(
        pointer: CGPoint,
        labelSize: CGSize,
        containerWidth: CGFloat,
        maxY: CGFloat? = nil
    ) -> CGPoint {
        let left = pointer.x - pointerGap - labelSize.width
        let right = pointer.x + pointerGap
        let x: CGFloat
        if left >= 0 {
            x = left
        } else if right + labelSize.width <= containerWidth {
            x = right
        } else {
            x = max(0, min(left, containerWidth - labelSize.width))
        }
        let centered = pointer.y - labelSize.height / 2
        let y = maxY.map { min(centered, $0 - labelSize.height) } ?? centered
        return CGPoint(x: x, y: y)
    }

    /// The row whose vertical span is nearest `y` (the one containing it, when
    /// any does), so the gaps between rows keep the label up; nil when there
    /// are no rows.
    static func nearestRowIndex(y: CGFloat, rowFrames: [CGRect]) -> Int? {
        rowFrames.indices.min { lhs, rhs in
            distance(from: y, to: rowFrames[lhs]) < distance(from: y, to: rowFrames[rhs])
        }
    }

    /// Vertical distance from `y` to `frame`; 0 inside it.
    private static func distance(from y: CGFloat, to frame: CGRect) -> CGFloat {
        if y < frame.minY { return frame.minY - y }
        if y > frame.maxY { return y - frame.maxY }
        return 0
    }
}

/// Hover tracking for a container of items (day columns, model rows):
/// reports the item under the pointer and floats a label for it beside the
/// pointer. Shared by every hover label in the panel.
private struct FloatingHoverLabelModifier<Label: View>: ViewModifier {
    @Binding var hoveredIndex: Int?
    /// Keeps the label's bottom inside the container (see
    /// ``HoverLabelPlacement/labelOrigin(pointer:labelSize:containerWidth:maxY:)``).
    let staysAboveBottomEdge: Bool
    /// The item under a pointer at the point, in a container of the size.
    let index: (CGPoint, CGSize) -> Int?
    let label: (Int) -> Label

    /// Pointer position in the container while it hovers there.
    @State private var location: CGPoint?
    /// Measured size of the label, for placing it beside the pointer.
    @State private var labelSize: CGSize = .zero
    /// Measured size of the container.
    @State private var containerSize: CGSize = .zero

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                containerSize = size
            }
            .onContinuousHover { phase in
                switch phase {
                case let .active(point):
                    location = point
                    hoveredIndex = index(point, containerSize)
                case .ended:
                    location = nil
                    hoveredIndex = nil
                }
            }
            .overlay(alignment: .topLeading) {
                if let hoveredIndex, let location {
                    placedLabel(label(hoveredIndex), at: location)
                }
            }
    }

    private func placedLabel(_ label: Label, at pointer: CGPoint) -> some View {
        let origin = HoverLabelPlacement.labelOrigin(
            pointer: pointer,
            labelSize: labelSize,
            containerWidth: containerSize.width,
            maxY: staysAboveBottomEdge ? containerSize.height : nil
        )
        return label
            .fixedSize()
            .onGeometryChange(for: CGSize.self) { proxy in
                proxy.size
            } action: { size in
                labelSize = size
            }
            // Hidden until measured, so it never flashes at the corner.
            .opacity(labelSize == .zero ? 0 : 1)
            .offset(x: origin.x, y: origin.y)
            .allowsHitTesting(false)
    }
}

extension View {
    /// Floats a label beside the pointer while it hovers over one of this
    /// container's items, and reports the hovered item.
    ///
    /// - Parameters:
    ///   - hoveredIndex: Set to the hovered item's index, or nil.
    ///   - staysAboveBottomEdge: Raises the label so it never hangs below the
    ///     container; for content at the bottom of the panel.
    ///   - index: The item under the pointer, from the pointer position and
    ///     the container size; nil when none is.
    ///   - label: The label for an item.
    func floatingHoverLabel(
        hoveredIndex: Binding<Int?>,
        staysAboveBottomEdge: Bool = false,
        index: @escaping (_ pointer: CGPoint, _ containerSize: CGSize) -> Int?,
        @ViewBuilder label: @escaping (Int) -> some View
    ) -> some View {
        modifier(
            FloatingHoverLabelModifier(
                hoveredIndex: hoveredIndex,
                staysAboveBottomEdge: staysAboveBottomEdge,
                index: index,
                label: label
            )
        )
    }
}
