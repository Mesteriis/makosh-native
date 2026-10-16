import SwiftUI

/// Compatibility wrapper for the common workspace's concrete Telemost detail.
struct MeetingsView: View {
    @ObservedObject var model: TelemostWorkspaceModel
    var body: some View { TelemostDetailView(model: model, contacts: [], dossier: { _ in }) }
}
