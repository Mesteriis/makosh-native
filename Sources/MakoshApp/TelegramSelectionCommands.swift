import SwiftUI

private struct CopyTelegramSelectionKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var copyTelegramSelection: (() -> Void)? {
        get { self[CopyTelegramSelectionKey.self] }
        set { self[CopyTelegramSelectionKey.self] = newValue }
    }
}

/// The native text responder remains in charge outside the selection panel.
struct TelegramSelectionCommands: Commands {
    @FocusedValue(\.copyTelegramSelection) private var copySelection
    var body: some Commands {
        CommandGroup(before: .pasteboard) {
            if let copySelection {
                Button("Копировать выбранные сообщения", action: copySelection).keyboardShortcut("c", modifiers: .command)
            }
        }
    }
}
