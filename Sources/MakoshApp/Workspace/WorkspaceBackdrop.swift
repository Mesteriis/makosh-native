import SwiftUI

/// Quiet shared surface. Explicit chat themes remain local to their service.
struct WorkspaceBackdrop: View {
    var intensity: Double = 1.0
    var body: some View {
        WorkspaceStyle.base.ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}
