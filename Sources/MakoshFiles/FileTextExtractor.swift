import AppKit
import Foundation
import MakoshCore
import PDFKit
import Vision

/// The text of one file as the AI card sends it: pages for a PDF, parts for
/// everything else, with the pages that came from OCR marked.
public struct ExtractedText: Sendable, Equatable {
    public let pages: [String]
    public let pageCount: Int
    public let paginated: Bool
    public let recognizedPages: Set<Int>
    public let truncatedOCR: Bool
    public init(pages: [String], pageCount: Int, paginated: Bool, recognizedPages: Set<Int>, truncatedOCR: Bool) {
        self.pages = pages
        self.pageCount = pageCount
        self.paginated = paginated
        self.recognizedPages = recognizedPages
        self.truncatedOCR = truncatedOCR
    }
}

public struct ExtractionProgress: Sendable, Equatable {
    public let done: Int
    public let total: Int
    public init(done: Int, total: Int) {
        self.done = done
        self.total = total
    }
}

/// Reads text on the Mac: the PDF text layer first, Vision for scanned pages
/// and images, `NSAttributedString` for Word/RTF, plain text as UTF-8 or
/// CP1251. Nothing leaves the machine.
public actor FileTextExtractor {
    public static let ocrPageLimit = 200
    public static let renderDPI: CGFloat = 150
    public static let partCharacters = 3_000
    /// Fewer characters than this on a PDF page means "no text layer".
    public static let textLayerThreshold = 20
    private static let wordExtensions: Set<String> = ["docx", "doc", "rtf", "rtfd", "odt"]
    private static let plainExtensions: Set<String> = ["txt", "md", "csv", "markdown", "log", "json", "xml", "html", "htm"]

    private let languages: [String]
    private let ocrPageLimit: Int
    private var cache: [String: ExtractedText] = [:]

    public init(languages: [String] = ["ru-RU", "es-ES", "en-US"], ocrPageLimit: Int = FileTextExtractor.ocrPageLimit) {
        self.languages = languages
        self.ocrPageLimit = ocrPageLimit
    }

    /// Pages are 1-based and inclusive; nil means the whole file. Progress is
    /// reported after each finished page.
    public func extract(
        _ file: URL, name: String, pages: ClosedRange<Int>?, progress: (@Sendable (ExtractionProgress) -> Void)? = nil
    ) async throws -> ExtractedText {
        let suffix = (name as NSString).pathExtension.lowercased()
        let category = FileCategory.classify(name: name, kind: "")
        if suffix == "pdf" { return try await pdf(file, pages: pages, progress: progress) }
        if Self.wordExtensions.contains(suffix) { return try parts(of: try Self.attributedText(file), pages: pages) }
        if Self.plainExtensions.contains(suffix) { return try parts(of: try Self.plainText(file), pages: pages) }
        if category == .image { return try await image(file, pages: pages, progress: progress) }
        throw FilesFailure.unsupportedText(suffix.isEmpty ? category.title.lowercased() : suffix)
    }

    public func cached(key: String) -> ExtractedText? { cache[key] }
    public func store(_ value: ExtractedText, key: String) { cache[key] = value }
    public func clear() { cache = [:] }

    // MARK: - PDF

    private func pdf(
        _ file: URL, pages: ClosedRange<Int>?, progress: (@Sendable (ExtractionProgress) -> Void)?
    ) async throws -> ExtractedText {
        guard let document = PDFDocument(url: file), document.pageCount > 0 else { throw FilesFailure.unsupportedText("pdf") }
        let count = document.pageCount
        let selected = try Self.selection(pages, count: count)
        var result: [String] = []
        var recognized = Set<Int>(), ocrDone = 0, truncated = false
        for number in selected {
            try Task.checkCancellation()
            guard let page = document.page(at: number - 1) else { throw FilesFailure.unsupportedText("pdf") }
            let layer = (page.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if layer.count >= Self.textLayerThreshold {
                result.append(layer)
            } else if ocrDone < ocrPageLimit, let image = Self.render(page) {
                ocrDone += 1
                let text = try await recognize(image)
                result.append(text.isEmpty ? layer : text)
                if !text.isEmpty { recognized.insert(number) }
            } else {
                if ocrDone >= ocrPageLimit { truncated = true }
                result.append(layer)
            }
            progress?(ExtractionProgress(done: number - selected.lowerBound + 1, total: selected.count))
        }
        return ExtractedText(pages: result, pageCount: count, paginated: true, recognizedPages: recognized, truncatedOCR: truncated)
    }

    nonisolated private static func render(_ page: PDFPage) -> CGImage? {
        let bounds = page.bounds(for: .mediaBox)
        let scale = renderDPI / 72
        let size = CGSize(width: max(1, bounds.width * scale), height: max(1, bounds.height * scale))
        let image = page.thumbnail(of: size, for: .mediaBox)
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)
    }

    // MARK: - Images

    private func image(
        _ file: URL, pages: ClosedRange<Int>?, progress: (@Sendable (ExtractionProgress) -> Void)?
    ) async throws -> ExtractedText {
        guard let image = NSImage(contentsOf: file), let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw FilesFailure.unsupportedText((file.pathExtension.isEmpty ? "image" : file.pathExtension).lowercased())
        }
        try Task.checkCancellation()
        let text = try await recognize(cgImage)
        progress?(ExtractionProgress(done: 1, total: 1))
        let all = Self.parts(text)
        let count = max(all.count, 1)
        let selected = try Self.selection(pages, count: count)
        let chosen = all.isEmpty ? [""] : Array(all[(selected.lowerBound - 1)..<selected.upperBound])
        return ExtractedText(
            pages: chosen, pageCount: count, paginated: false, recognizedPages: text.isEmpty ? [] : Set(selected), truncatedOCR: false)
    }

    /// Lines top to bottom, left to right, as Vision found them. Vision runs
    /// off the actor so other cards keep reading; cancellation stops the request.
    private func recognize(_ image: CGImage) async throws -> String {
        let languages = languages
        try Task.checkCancellation()
        nonisolated(unsafe) let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true
        let lines: [String] = try await withTaskCancellationHandler {
            try await BackgroundWork.run {
                try VNImageRequestHandler(cgImage: image).perform([request])
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                return observations.sorted { a, b in
                    let rowA = Int((a.boundingBox.midY * 100).rounded()), rowB = Int((b.boundingBox.midY * 100).rounded())
                    return rowA != rowB ? rowA > rowB : a.boundingBox.minX < b.boundingBox.minX
                }.compactMap { $0.topCandidates(1).first?.string }
            }
        } onCancel: {
            request.cancel()
        }
        try Task.checkCancellation()
        return lines.joined(separator: "\n")
    }

    // MARK: - Text

    nonisolated private static func attributedText(_ file: URL) throws -> String {
        do { return try NSAttributedString(url: file, options: [:], documentAttributes: nil).string } catch {
            throw FilesFailure.unsupportedText(file.pathExtension.lowercased())
        }
    }

    nonisolated private static func plainText(_ file: URL) throws -> String {
        let data = try Data(contentsOf: file)
        if let text = String(data: data, encoding: .utf8) { return text }
        if let text = String(data: data, encoding: .windowsCP1251) { return text }
        throw FilesFailure.unsupportedText(file.pathExtension.lowercased())
    }

    private func parts(of text: String, pages: ClosedRange<Int>?) throws -> ExtractedText {
        let all = Self.parts(text)
        let count = max(all.count, 1)
        let selected = try Self.selection(pages, count: count)
        let chosen = all.isEmpty ? [""] : Array(all[(selected.lowerBound - 1)..<selected.upperBound])
        return ExtractedText(pages: chosen, pageCount: count, paginated: false, recognizedPages: [], truncatedOCR: false)
    }

    /// Paragraphs are packed up to `size`; an oversized paragraph is split by
    /// lines, and a line with no breaks is cut hard.
    public static func parts(_ text: String, size: Int = partCharacters) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, size > 0 else { return [] }
        var result: [String] = []
        var current = ""
        func flush() {
            let value = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result.append(value) }
            current = ""
        }
        func append(_ piece: String) {
            if current.isEmpty {
                current = piece
            } else if current.count + 2 + piece.count <= size {
                current += "\n\n" + piece
            } else {
                flush()
                current = piece
            }
        }
        for paragraph in trimmed.components(separatedBy: "\n\n") {
            let paragraph = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !paragraph.isEmpty else { continue }
            if paragraph.count <= size {
                append(paragraph)
                continue
            }
            for line in paragraph.components(separatedBy: "\n") {
                if line.count <= size {
                    append(line)
                    continue
                }
                var rest = Substring(line)
                while !rest.isEmpty {
                    let piece = String(rest.prefix(size))
                    rest = rest.dropFirst(size)
                    flush()
                    result.append(piece)
                }
            }
        }
        flush()
        return result
    }

    nonisolated private static func selection(_ pages: ClosedRange<Int>?, count: Int) throws -> ClosedRange<Int> {
        guard let pages else { return 1...count }
        guard pages.lowerBound >= 1, pages.upperBound <= count else { throw FilesFailure.pagesOutOfRange(pageCount: count) }
        return pages
    }
}
