import Foundation

/// Captured before editing; a UI callback must never borrow a later account/context.
public struct TelegramPrivacyEditorBasis: Equatable, Sendable {
    public let accountID: Int64
    public let contextID: UUID
    public let setting: TelegramPrivacySetting
    @MainActor public init?(controller: TelegramPrivacyController, kind: TelegramPrivacyKind) {
        guard controller.status == .ready, let snapshot = controller.snapshot, let setting = snapshot.settings[kind] else { return nil }
        accountID = snapshot.accountID; contextID = controller.contextID; self.setting = setting
    }
    @MainActor public func isCurrent(in controller: TelegramPrivacyController) -> Bool {
        controller.canEdit(setting.kind)
            && controller.contextID == contextID && controller.snapshot?.accountID == accountID
            && controller.snapshot?.settings[setting.kind] == setting
    }
    @MainActor public func change(to replacement: TelegramPrivacySetting, controller: TelegramPrivacyController) -> TelegramPrivacyChange? {
        guard isCurrent(in: controller) else { return nil }
        let change = TelegramPrivacyChange(expected: setting, replacement: replacement)
        return change.replacement == nil ? nil : change
    }
}

public struct TelegramGlobalPrivacyEditorBasis: Equatable, Sendable {
    public let accountID: Int64
    public let contextID: UUID
    public let setting: TelegramGlobalPrivacySetting
    private let capabilities: TelegramPrivacyCapabilities
    @MainActor public init?(controller: TelegramPrivacyController) {
        guard controller.status == .ready, let snapshot = controller.snapshot,
              let setting = snapshot.global, let capabilities = snapshot.capabilities else { return nil }
        accountID = snapshot.accountID; contextID = controller.contextID; self.setting = setting; self.capabilities = capabilities
    }
    @MainActor public func isCurrent(in controller: TelegramPrivacyController) -> Bool {
        controller.status == .ready && controller.mutationStatus != .saving && controller.mutationStatus != .uncertain &&
        controller.contextID == contextID && controller.snapshot?.accountID == accountID &&
        controller.snapshot?.global == setting && controller.snapshot?.capabilities == capabilities
    }
    @MainActor public func change(to replacement: TelegramGlobalPrivacySetting, controller: TelegramPrivacyController) -> TelegramGlobalPrivacyChange? {
        guard isCurrent(in: controller) else { return nil }
        let change = TelegramGlobalPrivacyChange(expected: setting, proposed: replacement)
        return change.replacement(capabilities: capabilities) == nil ? nil : change
    }
}
