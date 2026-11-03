import SwiftUI
import MakoshTelegram

struct TelegramPeerPermissionsView: View {
    @ObservedObject var controller: TelegramPeerManagementController
    @State private var basis: Int32?
    @State private var flags: Int32 = 0
    @State private var context = UUID()
    @State private var pending: TelegramPeerChange?
    var body: some View {
        Form {
            Section("Разрешения для участников") {
                ForEach(Array(TelegramPeerRight.restrictions.dropFirst())) { right in
                    Toggle(right.title.replacingOccurrences(of: "Запретить", with: "Разрешить"), isOn: Binding(
                        get: { flags & right.id == 0 }, set: { allowed in flags = allowed ? flags & ~right.id : flags | right.id }))
                }
                Text("Эти разрешения действуют по умолчанию для участников. Отдельные ограничения настраиваются в списке участников.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Button("Сохранить разрешения…") {
                    if let basis { pending = .permissions(previous: basis, value: flags) }
                }.disabled(basis == nil || flags == basis || controller.status != .ready || controller.mutationStatus == .saving || controller.mutationStatus == .uncertain)
                    .accessibilityIdentifier("telegram.profile.permissions.save")
                TelegramPeerManagementStatusView(controller: controller)
            }
        }.formStyle(.grouped)
            .onAppear(perform: reset)
            .onChange(of: controller.snapshot) { _, _ in if controller.mutationStatus == .saved || controller.mutationStatus == .changed { reset() } }
            .confirmationDialog("Изменить разрешения участников?", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }), titleVisibility: .visible) {
                Button("Подтвердить изменение") { if let pending { controller.apply(pending, contextID: context) }; pending = nil }
                Button("Отмена", role: .cancel) { pending = nil }
            } message: { Text("Новые разрешения будут сохранены в Telegram для этого чата.") }
    }
    private func reset() { basis = controller.snapshot?.defaultBannedRights; flags = basis ?? 0; context = controller.contextID }
}
