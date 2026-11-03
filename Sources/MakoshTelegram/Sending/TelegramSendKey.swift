import AppKit
import Carbon

public enum TelegramSendKey: String, CaseIterable, Sendable {
    case enter, commandEnter

    public static let preferenceKey = "Makosh.Telegram.SendKey"

    public init(preferenceValue: String?) {
        self = preferenceValue.flatMap(Self.init(rawValue:)) ?? .enter
    }

    public func shouldSubmit(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, hasMarkedText: Bool) -> Bool {
        guard !hasMarkedText,
              keyCode == UInt16(kVK_Return) || keyCode == UInt16(kVK_ANSI_KeypadEnter) else { return false }
        let flags = modifiers.intersection(.deviceIndependentFlagsMask)
        switch self {
        case .enter:
            return flags.isEmpty || flags == .capsLock || flags == .numericPad
        case .commandEnter:
            return flags.contains(.command)
        }
    }
}
