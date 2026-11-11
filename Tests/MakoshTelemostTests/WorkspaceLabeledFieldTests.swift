import AppKit
import SwiftUI
import Vision
import XCTest
@testable import MakoshApp

/// Form rows render as plain views under `WorkspaceFormStyle`, so a field's title survives a prefilled
/// value only when the row draws its own caption. SwiftUI exposes no in-process accessibility tree,
/// so the rendered window is read back with on-device text recognition.
@MainActor final class WorkspaceLabeledFieldTests: XCTestCase {
    func testBareFieldShowsOnlyItsValueOnceItHoldsOne() async throws {
        let text = try await renderedText {
            Form { TextField("Сервер", text: .constant("imap.example.org")) }
        }
        XCTAssertTrue(text.contains("imap.example.org"), "The value is drawn: \(text)")
        XCTAssertFalse(text.contains("Сервер"), "A bare field keeps its title only as the hidden placeholder: \(text)")
    }

    func testLabeledFieldKeepsItsTitleVisibleBesideAPrefilledValue() async throws {
        let text = try await renderedText {
            Form { WorkspaceLabeledField("Сервер") { TextField("Сервер", text: .constant("imap.example.org")) } }
        }
        XCTAssertTrue(text.contains("Сервер"), "The caption keeps the title visible: \(text)")
        XCTAssertTrue(text.contains("imap.example.org"), "The value stays in the control: \(text)")
    }

    private func renderedText<Content: View>(@ViewBuilder _ content: () -> Content) async throws -> [String] {
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 600, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(
            rootView: content().formStyle(WorkspaceFormStyle()).textFieldStyle(WorkspaceTextFieldStyle())
                .frame(width: 600, height: 300))
        window.contentView = host
        window.orderFront(nil)
        defer {
            window.orderOut(nil)
            window.contentView = nil
            window.close()
        }
        for _ in 0..<6 {
            host.layoutSubtreeIfNeeded()
            window.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        let image = try XCTUnwrap(rep.cgImage)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["ru-RU", "en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        let text = request.results?.compactMap { $0.topCandidates(1).first?.string } ?? []
        print("workspace-labeled-field image=\(image.width)x\(image.height) text=\(text)")
        return text
    }
}
