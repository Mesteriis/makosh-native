import SwiftUI

/// Quiet shared surface. Explicit chat themes remain local to their service.
struct WorkspaceBackdrop: View {
    var intensity: Double = 1.0
    var body: some View {
        ZStack {
            WorkspaceStyle.base
            LinearGradient(
                colors: [WorkspaceStyle.accent.opacity(0.055 * intensity), .clear, WorkspaceStyle.highlight],
                startPoint: .topLeading, endPoint: .bottomTrailing)
        }.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}
