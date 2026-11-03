import SwiftUI
import AppKit

/// Resizable panes with a transparent handle instead of a system divider/gutter.
struct WorkspaceSplitView<Sidebar: View, Detail: View>: View {
    @Binding var width: CGFloat
    let minimum: CGFloat
    let maximum: CGFloat
    let minimumDetail: CGFloat
    let sidebar: Sidebar
    let detail: Detail
    @State private var dragOrigin: CGFloat?

    init(width: Binding<CGFloat>, minimum: CGFloat, maximum: CGFloat, minimumDetail: CGFloat,
         @ViewBuilder sidebar: () -> Sidebar, @ViewBuilder detail: () -> Detail) {
        _width = width; self.minimum = minimum; self.maximum = maximum; self.minimumDetail = minimumDetail
        self.sidebar = sidebar(); self.detail = detail()
    }

    var body: some View {
        GeometryReader { geometry in
            let limit = max(minimum, min(maximum, geometry.size.width - minimumDetail))
            let resolved = min(max(width, minimum), limit)
            HStack(spacing: 0) {
                sidebar.frame(width: resolved)
                detail.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .overlay(alignment: .leading) {
                Color.clear.frame(width: 8).contentShape(Rectangle()).offset(x: resolved - 4)
                    .onHover { inside in if inside { NSCursor.resizeLeftRight.set() } else { NSCursor.arrow.set() } }
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if dragOrigin == nil { dragOrigin = resolved }
                            width = min(max((dragOrigin ?? resolved) + value.translation.width, minimum), limit)
                        }
                        .onEnded { _ in dragOrigin = nil })
                    .accessibilityLabel("Ширина списка")
                    .accessibilityValue("\(Int(resolved))")
                    .accessibilityAdjustableAction { direction in
                        switch direction {
                        case .increment: width = min(resolved + 20, limit)
                        case .decrement: width = max(resolved - 20, minimum)
                        @unknown default: break
                        }
                    }
            }
        }
    }
}
