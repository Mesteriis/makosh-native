import SwiftUI
import MakoshMail

/// Account and exact wire-folder selection stay in the existing mail conductor.
struct MailNavigationBar: View {
    @Environment(\.workspaceNavigation) private var workspaceNavigation
    @ObservedObject var model: MailWorkspaceModel

    private var account: MailAccount? {
        model.accounts.first { $0.id == model.selectedFolder?.accountID } ?? model.accounts.first
    }

    var body: some View {
        HStack(spacing: 12) {
            accountMenu
            folderMenu
            Divider().frame(height: 24).padding(.horizontal, 4)
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Поиск в письмах", text: $model.search)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await model.refresh(serverSearch: true) } }
                    .accessibilityIdentifier("mail.search")
                if !model.search.isEmpty {
                    Button {
                        model.search = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain).accessibilityLabel("Очистить поиск")
                }
                Button {
                    Task { await model.refresh() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain).help("Обновить папку").accessibilityLabel("Обновить папку")
                .accessibilityIdentifier("mail.refresh")
                .disabled(model.busy || model.synthetic || !model.connected.contains(model.selectedFolder?.accountID ?? ""))
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(.white.opacity(0.045), in: RoundedRectangle(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(.white.opacity(0.08)))
            settingsMenu
            Button {
                model.compose()
            } label: {
                Label("Написать", systemImage: "square.and.pencil")
            }
            .buttonStyle(WorkspaceButtonStyle(prominent: true)).controlSize(.regular)
            .disabled(model.busy || model.accounts.isEmpty)
            .accessibilityIdentifier("mail.compose")
        }
        .labelStyle(.titleAndIcon)
        .accessibilityElement(children: .contain)
        .buttonBorderShape(.roundedRectangle(radius: 7))
        .padding(.horizontal, 8).frame(height: 44)
        .background { WorkspaceBackdrop(intensity: 0.4) }
    }

    private var accountMenu: some View {
        MakoshMenu {
            ForEach(model.accounts) { item in
                let folders = model.folders.filter { $0.accountID == item.id }
                MakoshMenuItem {
                    if let folder = folders.first(where: { $0.kind == .inbox }) ?? folders.first {
                        model.selectFolder(folder)
                    }
                } label: {
                    Label("\(item.displayName) · \(item.email)", systemImage: account?.id == item.id ? "checkmark" : "envelope")
                }.disabled(folders.isEmpty)
                MakoshMenu("Действия: \(item.email)") {
                    MakoshMenuItem("Настройки аккаунта…") {
                        model.editingAccount = item
                        model.accountSheet = true
                    }
                    MakoshMenuItem("Уведомления аккаунта…") { model.notificationSettingsScope = .account(item.id) }
                    if model.connected.contains(item.id) {
                        MakoshMenuItem("Отключить") { Task { await model.disconnect(item) } }
                    } else {
                        MakoshMenuItem("Подключить") { Task { await model.connect(item) } }.disabled(model.synthetic)
                    }
                }
            }
            Divider()
            MakoshMenuItem("Добавить аккаунт…", systemImage: "plus") {
                model.editingAccount = nil
                model.accountSheet = true
            }
            .accessibilityIdentifier("mail.addAccount")
        } label: {
            Label(account?.displayName ?? "Добавить почту", systemImage: "person.crop.circle")
                .lineLimit(1).fixedSize(horizontal: true, vertical: false)
        }
        .makoshMenuStyle(.bordered).controlSize(.regular).fixedSize().tint(.primary).disabled(model.busy)
        .help(account?.email ?? "Почтовые аккаунты")
        .accessibilityLabel("Почтовый аккаунт").accessibilityIdentifier("mail.accountMenu")
    }

    private var folderMenu: some View {
        MakoshMenu {
            ForEach(model.folders.filter { $0.accountID == account?.id }) { folder in
                MakoshMenuItem {
                    model.selectFolder(folder)
                } label: {
                    Label(
                        folder.title,
                        systemImage: !model.showArchive && folder.id == model.selectedFolder?.id ? "checkmark" : folder.kind.symbol)
                }.accessibilityIdentifier("mail.folder.\(folder.accountID).\(folder.path)")
            }
            Divider()
            MakoshMenuItem("Сохранённая переписка", systemImage: "archivebox") { model.selectArchive() }
            if let folder = model.selectedFolder, !model.showArchive {
                Divider()
                MakoshMenuItem("Уведомления папки…") {
                    model.notificationSettingsScope = .folder(accountID: folder.accountID, path: folder.path)
                }
            }
        } label: {
            Label(
                model.showArchive ? "Сохранённая переписка" : model.selectedFolder?.title ?? "Папки",
                systemImage: model.showArchive ? "archivebox" : model.selectedFolder?.kind.symbol ?? "folder"
            )
            .lineLimit(1)
        }
        .makoshMenuStyle(.bordered).controlSize(.regular).fixedSize().tint(.primary).disabled(model.busy)
        .accessibilityLabel("Почтовая папка").accessibilityIdentifier("mail.folderMenu")
    }

    private var settingsMenu: some View {
        MakoshMenu {
            MakoshMenuItem("Исходящие операции…") { model.outboxSheet = true }
            MakoshMenuItem("Уведомления…") { model.notificationSettingsScope = .global }
                .accessibilityIdentifier("mail.notifications.global")
            MakoshMenuItem("Подписи, шаблоны и правила…") { workspaceNavigation?.openSettings(.mail) }
                .accessibilityIdentifier("mail.automation.settings")
            #if DEBUG
            if model.synthetic {
                Divider()
                MakoshMenuItem("Тестовое входящее") { Task { await model.simulateIncoming() } }
                    .accessibilityIdentifier("mail.notifications.syntheticIncoming")
            }
            #endif
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .makoshMenuStyle(.plain).fixedSize().disabled(model.busy)
        .help("Настройки почты").accessibilityLabel("Настройки почты")
        .accessibilityIdentifier("mail.settingsMenu")
    }
}
