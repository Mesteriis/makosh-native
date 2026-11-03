import SwiftUI

private struct FindTelegramMessageKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var findTelegramMessage: (() -> Void)? {
        get { self[FindTelegramMessageKey.self] }
        set { self[FindTelegramMessageKey.self] = newValue }
    }
}

struct TelegramSearchCommands: Commands {
    @FocusedValue(\.findTelegramMessage) private var findMessage

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Найти сообщение") { findMessage?() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(findMessage == nil)
        }
    }
}
