import AppKit
import CoreText
import Foundation
import PDFKit

/// Documents built in the test itself: a PDF with a real text layer (Core
/// Text into a PDF context), scanned pages (bitmaps), Word files and plain text.
enum Fixtures {
    enum Page {
        case text(String)
        case scan(String)
    }

    static func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("makosh-fixtures-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return url
    }

    /// Letter-sized pages; text pages keep a selectable text layer, scans are images only.
    static func pdf(_ pages: [Page], at url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else {
            throw NSError(domain: "fixtures", code: 1)
        }
        for page in pages {
            context.beginPDFPage(nil)
            switch page {
            case .text(let text):
                let font = CTFontCreateWithName("Helvetica" as CFString, 24, nil)
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
                context.textPosition = CGPoint(x: 60, y: 700)
                CTLineDraw(line, context)
            case .scan(let text):
                let image = bitmap(text: text, size: CGSize(width: 1200, height: 400))
                context.draw(image, in: CGRect(x: 60, y: 300, width: 490, height: 163))
            }
            context.endPDFPage()
        }
        context.closePDF()
    }

    /// A white bitmap with large black text, as a scanner would produce.
    static func bitmap(text: String, size: CGSize) -> CGImage {
        let image = NSImage(size: size)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 96, weight: .semibold), .foregroundColor: NSColor.black,
        ]
        NSAttributedString(string: text, attributes: attributes).draw(at: NSPoint(x: 60, y: size.height / 2 - 60))
        image.unlockFocus()
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    static func png(text: String, at url: URL) throws {
        let image = bitmap(text: text, size: CGSize(width: 1200, height: 400))
        let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
        try data.write(to: url)
    }

    static func docx(_ text: String, at url: URL) throws {
        let data = try NSAttributedString(string: text).data(
            from: NSRange(location: 0, length: text.utf16.count),
            documentAttributes: [.documentType: NSAttributedString.DocumentType.officeOpenXML])
        try data.write(to: url)
    }

    static func rtf(_ text: String, at url: URL) throws {
        let data = try NSAttributedString(string: text).data(
            from: NSRange(location: 0, length: text.utf16.count), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try data.write(to: url)
    }
}
