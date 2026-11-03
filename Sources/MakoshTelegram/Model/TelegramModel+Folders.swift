import Foundation
import TelegramCore
import Postbox
import SwiftSignalKit

/// Workspace folder rail backed by the account's chat filters.
extension TelegramModel {
    public var workspaceFolderTitle: String {
        if chatFolder == .archive { return "Архив" }
        return workspaceFolders.first { $0.id == workspaceFolderID }?.title ?? "Все чаты"
    }

    public func selectWorkspaceFolder(_ id: Int32?) {
        guard id == nil || workspaceFolders.contains(where: { $0.id == id }) else { return }
        let changedGroup = chatFolder != .inbox
        workspaceFolderID = id
        if changedGroup { chatFolder = .inbox } else { loadChatList(clear: true) }
    }

    public func showWorkspaceArchive() {
        workspaceFolderID = nil
        if chatFolder == .archive { loadChatList(clear: true) } else { chatFolder = .archive }
    }

    func bindWorkspaceFolders(_ account: Account?) {
        workspaceFolderObservation.set(nil)
        workspaceNativeFolders = []
        workspaceFolders = []
        workspaceFolderID = nil
        guard let account else { return }
        let token = accountGeneration
        workspaceFolderObservation.set(
            (telegramWorkspaceFolderUpdates(account: account) |> deliverOnMainQueue).start(next: { [weak self] filters in
                guard let self, self.accountGeneration == token, self.account === account else { return }
                let previous = self.workspaceNativeFolders.first { $0.id == self.workspaceFolderID }
                self.workspaceNativeFolders = filters
                self.workspaceFolders = filters.compactMap {
                    guard case let .filter(id, title, _, _) = $0 else { return nil }
                    return TelegramWorkspaceFolder(id: id, title: title.text)
                }
                if let selected = self.workspaceFolderID {
                    if !filters.contains(where: { $0.id == selected }) { self.workspaceFolderID = nil }
                    if previous != filters.first(where: { $0.id == selected }) { self.loadChatList(clear: true) }
                }
            }))
    }
}
