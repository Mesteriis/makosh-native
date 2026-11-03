import Foundation
import MakoshCodeHighlight

public enum TelegramCodeHighlighter {
    private static let worker = TelegramCodeHighlightQueue()

    /// Parses captured local code only. Unsupported, saturated, cancelled or
    /// over-budget requests retain the caller's native uncolored presentation.
    public static func highlight(source: String, language: String?) async -> TelegramCodeHighlight? {
        guard !Task.isCancelled, !source.isEmpty,
              source.utf16.prefix(32769).count <= 32768, let language else { return nil }
        let raw = Array(language.utf8.prefix(65))
        guard !raw.isEmpty, raw.count <= 64, raw.allSatisfy({ (0x21...0x7E).contains($0) }),
              worker.admit() else { return nil }
        guard let token = CodeHighlightCancellation() else { worker.release(); return nil }
        let hint = raw.map { (0x41...0x5A).contains($0) ? $0 + 0x20 : $0 }
        let result: TelegramCodeHighlight? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                worker.queue.async {
                    let result = parse(source: source, language: hint, token: token)
                    worker.release()
                    continuation.resume(returning: result)
                }
            }
        } onCancel: {
            token.cancel()
        }
        return Task.isCancelled ? nil : result
    }

    private static func parse(source: String, language: [UInt8], token: CodeHighlightCancellation) -> TelegramCodeHighlight? {
        let bytes = Array(source.utf8)
        var spans = [MKCodeHighlightSpan](repeating: .init(offset: 0, length: 0, role: 0), count: 8192)
        var written = 0
        let status = bytes.withUnsafeBufferPointer { sourceBytes in
            language.withUnsafeBufferPointer { hint in
                spans.withUnsafeMutableBufferPointer { output in
                    mk_code_highlight(sourceBytes.baseAddress, sourceBytes.count, hint.baseAddress, hint.count,
                        token.pointer, output.baseAddress, output.count, &written)
                }
            }
        }
        guard status == MKCodeHighlightSuccess, (0...8192).contains(written) else { return nil }
        return TelegramCodeHighlight(source: source, byteSpans: spans.prefix(written).map {
            .init(offset: $0.offset, length: $0.length, role: $0.role)
        })
    }
}

/// Native cancellation is atomic; ARC retains it through queued work and the
/// cancellation handler, then destroys it after synchronous native work ends.
private final class CodeHighlightCancellation: @unchecked Sendable {
    let pointer: OpaquePointer
    init?() {
        guard let pointer = mk_code_highlight_cancellation_create() else { return nil }
        self.pointer = pointer
    }
    func cancel() { mk_code_highlight_cancellation_cancel(pointer) }
    deinit { mk_code_highlight_cancellation_destroy(pointer) }
}
