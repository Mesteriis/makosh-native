import AppKit
import SwiftUI
import MakoshTelegram

/// Presentation of fresh, account-bound native capabilities. Send authorization
/// remains in the transactional core; this view cannot grant it.
public struct TelegramConversationCapabilityBanner: View {
    public let capabilities: TelegramConversationCapabilities
    public let onShowVerification: () -> Void
    public init(capabilities: TelegramConversationCapabilities, onShowVerification: @escaping () -> Void) {
        self.capabilities = capabilities; self.onShowVerification = onShowVerification
    }
    public var body: some View {
        if capabilities.secret != nil || capabilities.messageFee != .free {
            HStack(spacing: 12) {
                if let secret = capabilities.secret {
                    Image(systemName: "lock.fill")
                    Text(secretStatus(secret)).lineLimit(1).help(secretStatus(secret))
                    Spacer(minLength: 8)
                    if secret.state == .active, secret.verification != nil {
                        Button("Ключ шифрования", action: onShowVerification)
                            .buttonStyle(.link)
                            .accessibilityIdentifier("telegram.secret.verify")
                    }
                }
                switch capabilities.messageFee {
                case .free: EmptyView()
                case let .stars(price):
                    Text("★ \(price) за сообщение")
                        .accessibilityIdentifier("telegram.conversation.messagePrice")
                case .unavailable:
                    Text("Стоимость отправки недоступна")
                        .accessibilityIdentifier("telegram.conversation.messagePriceUnavailable")
                }
            }
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .accessibilityIdentifier("telegram.conversation.capabilities")
        }
    }
    private func secretStatus(_ secret: TelegramSecretConversation) -> String {
        switch secret.state {
        case .handshake: "Ожидание подключения \(secret.participantTitle)"
        case .active: secret.verification == nil ? "Секретный чат · ключ проверки недоступен" : "Секретный чат"
        case .terminated: "Секретный чат завершён"
        }
    }
}

public struct TelegramSecretVerificationView: View {
    public let secret: TelegramSecretConversation
    public init(secret: TelegramSecretConversation) { self.secret = secret }
    public var body: some View {
        ScrollView {
            if secret.state == .active, let verification = secret.verification,
                let image = TelegramSecretVerificationImage.make(verification) {
                VStack(spacing: 30) {
                    Image(nsImage: image).interpolation(.none)
                        .frame(width: 264, height: 264)
                        .accessibilityLabel("Изображение для сравнения ключа секретного чата")
                    Text(verification.hexLines.joined(separator: "\n"))
                        .font(.system(size: 14, design: .monospaced)).lineSpacing(3)
                        .multilineTextAlignment(.center).textSelection(.enabled)
                        .accessibilityIdentifier("telegram.secret.fingerprint")
                    Text("Сравните изображение и код с \(secret.participantTitle) при личной встрече или по доверенному каналу связи.")
                        .font(.system(size: 13)).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                }
                .padding(30).frame(maxWidth: .infinity)
            } else {
                Text("Ключ проверки недоступен")
                    .foregroundStyle(.secondary).padding(30)
                    .frame(maxWidth: .infinity, minHeight: 264)
            }
        }
        .frame(minWidth: 324, idealWidth: 360, minHeight: 450)
        .accessibilityIdentifier("telegram.secret.verification")
    }
}

enum TelegramSecretVerificationImage {
    @MainActor static func make(_ verification: TelegramSecretChatVerification) -> NSImage? {
        // A fixed public-fingerprint visualization:144cells,22px per cell.
        // No key material, decoder, network request or external image is used.
        let sha1 = Array(verification.sha1), sha256 = Array(verification.sha256)
        let palette: [[UInt8]] = [[255, 255, 255], [213, 230, 243], [45, 87, 117], [47, 153, 201]]
        var pixels = [UInt8](repeating: 255, count: 264 * 264 * 4)
        for cell in 0..<144 {
            let bit = cell * 2
            let bytes = bit < 128 ? sha1 : sha256
            let offset = bit < 128 ? bit : bit - 128
            let color = palette[Int((bytes[offset / 8] >> (offset % 8)) & 3)]
            let left = (cell % 12) * 22, top = (cell / 12) * 22
            for y in top..<(top + 22) {
                for x in left..<(left + 22) {
                    let index = (y * 264 + x) * 4
                    pixels[index] = color[0]; pixels[index + 1] = color[1]; pixels[index + 2] = color[2]
                }
            }
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
            let image = CGImage(width: 264, height: 264, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: 264 * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        return NSImage(cgImage: image, size: .init(width: 264, height: 264))
    }
}

/// Uses the shared controller's immutable prompt. Merely presenting this view
/// does not request a consent, begin a journal entry, or enqueue a message.
public struct TelegramPaidSendApprovalView: View {
    @ObservedObject private var controller: TelegramSendApprovalController
    public init(controller: TelegramSendApprovalController) { self.controller = controller }
    public var body: some View {
        TelegramPaidSendApprovalRepresentable(prompt: controller.pendingPrompt,
            isConfirming: controller.isConfirming,
            confirm: { controller.confirm(promptID: $0) }, cancel: { controller.cancel(promptID: $0) })
            .frame(width: 360, height: 240)
    }
}

private struct TelegramPaidSendApprovalRepresentable: NSViewRepresentable {
    let prompt: TelegramSendApprovalPrompt?
    let isConfirming: Bool
    let confirm: (UUID) -> Void
    let cancel: (UUID) -> Void
    func makeNSView(context: Context) -> TelegramPaidSendApprovalContentView {
        TelegramPaidSendApprovalContentView()
    }
    func updateNSView(_ view: TelegramPaidSendApprovalContentView, context: Context) {
        view.update(prompt: prompt, isConfirming: isConfirming, confirm: confirm, cancel: cancel)
    }
}

@MainActor final class TelegramPaidSendApprovalContentView: NSView {
    let titleField = NSTextField(labelWithString: "")
    let destinationField = NSTextField(labelWithString: "")
    let quantityField = NSTextField(labelWithString: "")
    let unitPriceField = NSTextField(labelWithString: "")
    let totalField = NSTextField(labelWithString: "")
    let confirmButton = NSButton(title: "", target: nil, action: nil)
    let cancelButton = NSButton(title: "", target: nil, action: nil)
    private var promptID: UUID?
    private var confirm: ((UUID) -> Void)?
    private var cancel: ((UUID) -> Void)?
    override init(frame: NSRect) {
        super.init(frame: frame)
        titleField.font = .systemFont(ofSize: 15, weight: .semibold)
        destinationField.font = .systemFont(ofSize: 13, weight: .medium)
        destinationField.isSelectable = true
        destinationField.lineBreakMode = .byTruncatingTail
        destinationField.maximumNumberOfLines = 2
        destinationField.usesSingleLineMode = false
        for field in [titleField, destinationField, quantityField, unitPriceField, totalField] {
            field.alignment = .center
        }
        for field in [quantityField, unitPriceField, totalField] {
            field.font = .systemFont(ofSize: 13)
        }
        totalField.font = .systemFont(ofSize: 13, weight: .medium)
        for button in [confirmButton, cancelButton] {
            button.bezelStyle = .rounded; button.controlSize = .large
            button.font = .systemFont(ofSize: 13, weight: .medium)
            button.target = self; button.isEnabled = false
        }
        confirmButton.action = #selector(confirmPressed)
        cancelButton.action = #selector(cancelPressed)
        confirmButton.identifier = .init("telegram.send.approval.confirm")
        cancelButton.identifier = .init("telegram.send.approval.cancel")
        // Payment needs explicit button activation. Return is never assigned as
        // a default payment shortcut; Escape remains an explicit cancellation.
        confirmButton.keyEquivalent = ""; cancelButton.keyEquivalent = "\u{1b}"
        let details = NSStackView(views: [quantityField, unitPriceField, totalField])
        details.orientation = .vertical; details.alignment = .centerX; details.spacing = 4
        let actions = NSStackView(views: [cancelButton, confirmButton])
        actions.orientation = .horizontal; actions.alignment = .centerY; actions.spacing = 12
        let content = NSStackView(views: [titleField, destinationField, details, actions])
        content.orientation = .vertical; content.alignment = .centerX; content.spacing = 12
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 24),
            content.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -24),
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            destinationField.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor),
            confirmButton.heightAnchor.constraint(equalToConstant: 32),
            cancelButton.heightAnchor.constraint(equalToConstant: 32)
        ])
    }
    convenience init() { self.init(frame: .zero) }
    required init?(coder: NSCoder) { return nil }
    func update(prompt: TelegramSendApprovalPrompt?, isConfirming: Bool,
        confirm: @escaping (UUID) -> Void, cancel: @escaping (UUID) -> Void) {
        promptID = prompt?.id
        self.confirm = prompt == nil ? nil : confirm
        self.cancel = prompt == nil ? nil : cancel
        titleField.stringValue = prompt == nil ? "" : "Платная отправка"
        destinationField.stringValue = prompt?.title ?? ""
        destinationField.toolTip = prompt?.title
        quantityField.stringValue = prompt.map { "Сообщений: \($0.context.messageCount)" } ?? ""
        unitPriceField.stringValue = prompt.map { "За сообщение: ★ \($0.perMessageStars)" } ?? ""
        totalField.stringValue = prompt.map { "Всего: ★ \($0.totalStars)" } ?? ""
        confirmButton.title = prompt.map { isConfirming ? "Подтверждение…" : "Оплатить ★ \($0.totalStars)" } ?? ""
        cancelButton.title = prompt == nil ? "" : "Отмена"
        confirmButton.isEnabled = prompt != nil && !isConfirming
        cancelButton.isEnabled = prompt != nil
        confirmButton.setAccessibilityLabel(confirmButton.title)
        cancelButton.setAccessibilityLabel(cancelButton.title)
    }
    @objc private func confirmPressed() {
        guard confirmButton.isEnabled, let promptID else { return }
        confirm?(promptID)
    }
    @objc private func cancelPressed() {
        guard cancelButton.isEnabled, let promptID else { return }
        cancel?(promptID)
    }
}
