import AppKit
import XCTest
@testable import MakoshApp
@testable import MakoshTelegram

@MainActor final class TelegramSpecialConversationPresentationTests: XCTestCase {
    // Swapping bit order, drawing only SHA1, or reversing the row order changes
    // these rendered pixels. Expected colors are literal, independently derived.
    func testVerificationImageRendersReferenceBitOrderAndFingerprintBoundary() throws {
        var sha1 = Data(repeating: 0, count: 20), sha256 = Data(repeating: 0, count: 32)
        sha1[0] = 0xe4; sha1[15] = 0x6c; sha256[0] = 0x1b; sha256[19] = 0xe4
        let value = try XCTUnwrap(TelegramSecretChatVerification(sha1: sha1, sha256: sha256))
        guard let image = TelegramSecretVerificationImage.make(value) else {
            return XCTFail("Validated public fingerprints must produce the comparison image")
        }
        XCTAssertEqual(image.size, NSSize(width: 264, height: 264))
        let cg = try XCTUnwrap(image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cg)
        XCTAssertEqual(bitmap.pixelsWide, 264); XCTAssertEqual(bitmap.pixelsHigh, 264)
        let samples: [(Int, Int, UInt32)] = [
            (0, 0, 0xffffff), (1, 0, 0xd5e6f3), (2, 0, 0x2d5775), (3, 0, 0x2f99c9),
            (3, 5, 0xd5e6f3), (4, 5, 0x2f99c9), (5, 5, 0x2d5775),
            (6, 5, 0xd5e6f3), (7, 5, 0xffffff), (11, 11, 0x2f99c9)]
        for (x, y, rgb) in samples {
            let color = try XCTUnwrap(bitmap.colorAt(x: x * 22 + 11, y: y * 22 + 11)?.usingColorSpace(.deviceRGB))
            XCTAssertEqual(color.redComponent, CGFloat((rgb >> 16) & 255) / 255, accuracy: 0.005)
            XCTAssertEqual(color.greenComponent, CGFloat((rgb >> 8) & 255) / 255, accuracy: 0.005)
            XCTAssertEqual(color.blueComponent, CGFloat(rgb & 255) / 255, accuracy: 0.005)
            XCTAssertEqual(color.alphaComponent, 1, accuracy: 0.005)
        }
    }

    // Native controls must carry the currently presented immutable prompt ID;
    // a reused sheet cannot approve an older destination, price or revision.
    func testPaidPresentationUsesImmutableDetailsAndCurrentPromptForExplicitActions() {
        let view = TelegramPaidSendApprovalContentView()
        let first = prompt(title: "Synthetic Alice", count: 2, price: 7)
        var confirms: [UUID] = [], cancels: [UUID] = []
        view.update(prompt: first, isConfirming: false, confirm: { confirms.append($0) }, cancel: { cancels.append($0) })
        XCTAssertTrue(confirms.isEmpty); XCTAssertTrue(cancels.isEmpty)
        XCTAssertEqual(view.destinationField.stringValue, "Synthetic Alice")
        XCTAssertEqual(view.quantityField.stringValue, "Сообщений: 2")
        XCTAssertEqual(view.unitPriceField.stringValue, "За сообщение: ★ 7")
        XCTAssertEqual(view.totalField.stringValue, "Всего: ★ 14")
        XCTAssertEqual(view.confirmButton.title, "Оплатить ★ 14")
        view.confirmButton.performClick(nil)
        XCTAssertEqual(confirms, [first.id]); XCTAssertTrue(cancels.isEmpty)
        let second = prompt(title: "Synthetic Bob", count: 3, price: 5)
        view.update(prompt: second, isConfirming: false, confirm: { confirms.append($0) }, cancel: { cancels.append($0) })
        XCTAssertEqual(view.destinationField.stringValue, "Synthetic Bob")
        XCTAssertEqual(view.totalField.stringValue, "Всего: ★ 15")
        view.cancelButton.performClick(nil)
        XCTAssertEqual(cancels, [second.id]); XCTAssertEqual(confirms, [first.id])
    }

    // Consent writes cannot be repeated, but explicit cancellation stays
    // available. Clearing removes the previous destination and quoted price.
    func testConfirmingDisablesRepeatApprovalAndDismissedPresentationCannotReusePrompt() {
        let view = TelegramPaidSendApprovalContentView(), value = prompt()
        var actions: [UUID] = []
        view.update(prompt: value, isConfirming: true, confirm: { actions.append($0) }, cancel: { actions.append($0) })
        XCTAssertFalse(view.confirmButton.isEnabled); XCTAssertTrue(view.cancelButton.isEnabled)
        view.confirmButton.performClick(nil); view.cancelButton.performClick(nil)
        XCTAssertEqual(actions, [value.id])
        view.update(prompt: nil, isConfirming: false, confirm: { actions.append($0) }, cancel: { actions.append($0) })
        XCTAssertFalse(view.confirmButton.isEnabled); XCTAssertFalse(view.cancelButton.isEnabled)
        XCTAssertEqual(view.destinationField.stringValue, ""); XCTAssertEqual(view.quantityField.stringValue, "")
        XCTAssertEqual(view.unitPriceField.stringValue, ""); XCTAssertEqual(view.totalField.stringValue, "")
        view.confirmButton.performClick(nil); view.cancelButton.performClick(nil)
        XCTAssertEqual(actions, [value.id])
    }

    // Return remains inert: a generic keyboard shortcut must never imply an
    // explicit money confirmation. The controls expose distinct AX identities.
    func testPaidConfirmationHasNoImplicitReturnApprovalAndAccessibleActions() {
        let view = TelegramPaidSendApprovalContentView()
        view.update(prompt: prompt(), isConfirming: false, confirm: { _ in }, cancel: { _ in })
        XCTAssertEqual(view.confirmButton.keyEquivalent, "")
        XCTAssertEqual(view.confirmButton.identifier?.rawValue, "telegram.send.approval.confirm")
        XCTAssertEqual(view.cancelButton.identifier?.rawValue, "telegram.send.approval.cancel")
        XCTAssertEqual(view.confirmButton.accessibilityLabel(), "Оплатить ★ 14")
        XCTAssertTrue(view.destinationField.isSelectable)
    }

    private func prompt(title: String = "Synthetic Alice", count: Int = 2, price: Int64 = 7) -> TelegramSendApprovalPrompt {
        .init(id: UUID(), context: .init(accountID: 1, chatID: 42, threadID: nil,
            submissionRevision: UUID(), messageCount: count), title: title,
            perMessageStars: price, totalStars: price * Int64(count))
    }
}
