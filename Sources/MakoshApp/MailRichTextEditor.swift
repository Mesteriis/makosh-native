// Derived from MMail, copyright (c) 2026 moerdowo, MIT.
// See Dependencies/Mail/MMail.MIT.notice. UI-only TextKit formatting; graphics imports disabled.
import SwiftUI
import AppKit

enum MailRichFormat { case bold, italic, underline, bullet, numbered }

/// Owns the NSTextView so the toolbar can format it directly (no SwiftUI binding
/// round-trip, which previously reverted string-changing edits like lists).
@MainActor final class MailRichTextController: ObservableObject {
    @Published private(set) var isEmpty: Bool
    weak var textView: NSTextView?
    let initial: NSAttributedString
    let baseFontSize: CGFloat
    let focusOnAppear: Bool

    init(initial: NSAttributedString, baseFontSize: CGFloat = 14, focusOnAppear: Bool = false) {
        self.initial = initial
        self.baseFontSize = baseFontSize
        self.focusOnAppear = focusOnAppear
        self.isEmpty = initial.string.isEmpty
    }

    private var baseAttrs: [NSAttributedString.Key: Any] {
        [.font: NSFont.systemFont(ofSize: baseFontSize), .foregroundColor: NSColor.labelColor]
    }

    func currentAttributed() -> NSAttributedString { textView?.attributedString() ?? initial }
    func currentString() -> String { textView?.string ?? initial.string }
    func noteChanged() { isEmpty = currentString().isEmpty }

    func appendPlain(_ text: String) {
        guard let storage = textView?.textStorage else { return }
        storage.append(NSAttributedString(string: text, attributes: baseAttrs))
        noteChanged()
    }
    func replaceAll(_ text: String) {
        guard let storage = textView?.textStorage else { return }
        storage.setAttributedString(NSAttributedString(string: text, attributes: baseAttrs))
        noteChanged()
    }
    /// Replace only the untouched signature tail; the user owns all edited text.
    @discardableResult func replaceSignature(previous: String, with next: String) -> Bool {
        guard let storage = textView?.textStorage else { return false }
        if !previous.isEmpty {
            let suffix = "\n\n" + previous
            guard storage.string.hasSuffix(suffix) else { return false }
            storage.deleteCharacters(in: NSRange(location: storage.length - suffix.utf16.count, length: suffix.utf16.count))
        }
        if !next.isEmpty { storage.append(NSAttributedString(string: "\n\n" + next, attributes: baseAttrs)) }
        noteChanged(); return true
    }

    func apply(_ cmd: MailRichFormat) {
        guard let tv = textView, let storage = tv.textStorage else { return }
        let sel = tv.selectedRange()
        switch cmd {
        case .bold: toggleTrait(.boldFontMask, tv: tv, storage: storage, sel: sel)
        case .italic: toggleTrait(.italicFontMask, tv: tv, storage: storage, sel: sel)
        case .underline: toggleUnderline(tv: tv, storage: storage, sel: sel)
        case .bullet: applyList(ordered: false, tv: tv, storage: storage)
        case .numbered: applyList(ordered: true, tv: tv, storage: storage)
        }
        noteChanged()
    }

    private func toggleTrait(_ trait: NSFontTraitMask, tv: NSTextView, storage: NSTextStorage, sel: NSRange) {
        let fm = NSFontManager.shared
        if sel.length == 0 {
            let cur = (tv.typingAttributes[.font] as? NSFont) ?? .systemFont(ofSize: baseFontSize)
            let has = fm.traits(of: cur).contains(trait)
            tv.typingAttributes[.font] = has ? fm.convert(cur, toNotHaveTrait: trait) : fm.convert(cur, toHaveTrait: trait)
            return
        }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: sel, options: []) { value, sub, _ in
            let font = (value as? NSFont) ?? .systemFont(ofSize: baseFontSize)
            let has = fm.traits(of: font).contains(trait)
            let newFont = has ? fm.convert(font, toNotHaveTrait: trait) : fm.convert(font, toHaveTrait: trait)
            storage.addAttribute(.font, value: newFont, range: sub)
        }
        storage.endEditing()
    }

    private func toggleUnderline(tv: NSTextView, storage: NSTextStorage, sel: NSRange) {
        if sel.length == 0 {
            let on = (tv.typingAttributes[.underlineStyle] as? Int) ?? 0
            tv.typingAttributes[.underlineStyle] = on == 0 ? NSUnderlineStyle.single.rawValue : 0
            return
        }
        var allUnderlined = true
        storage.enumerateAttribute(.underlineStyle, in: sel, options: []) { value, _, stop in
            if (value as? Int) ?? 0 == 0 { allUnderlined = false; stop.pointee = true }
        }
        storage.beginEditing()
        if allUnderlined { storage.removeAttribute(.underlineStyle, range: sel) }
        else { storage.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: sel) }
        storage.endEditing()
    }

    private static let bulletRe = try? NSRegularExpression(pattern: "^•\\s")
    private static let numberRe = try? NSRegularExpression(pattern: "^\\d+\\.\\s")

    /// Toggle a bullet / numbered list across the selected lines, preserving each
    /// line's inline formatting (only the leading marker is rewritten).
    private func applyList(ordered: Bool, tv: NSTextView, storage: NSTextStorage) {
        let ns = storage.string as NSString
        let block = ns.lineRange(for: tv.selectedRange())
        var starts: [Int] = []
        var i = block.location
        while i < NSMaxRange(block) {
            starts.append(i)
            i = NSMaxRange(ns.lineRange(for: NSRange(location: i, length: 0)))
        }
        if starts.isEmpty { starts = [block.location] }

        func line(_ start: Int) -> NSString {
            ns.substring(with: ns.lineRange(for: NSRange(location: start, length: 0))) as NSString
        }
        func prefixLen(_ re: NSRegularExpression?, _ s: NSString) -> Int {
            re?.firstMatch(in: s as String, range: NSRange(location: 0, length: s.length))?.range.length ?? 0
        }
        let nonEmpty = starts.filter { !(line($0) as String).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let allBulleted = !nonEmpty.isEmpty && nonEmpty.allSatisfy { prefixLen(Self.bulletRe, line($0)) > 0 }
        let allNumbered = !nonEmpty.isEmpty && nonEmpty.allSatisfy { prefixLen(Self.numberRe, line($0)) > 0 }
        let removing = (ordered && allNumbered) || (!ordered && allBulleted)

        struct Edit { let start: Int; let removeLen: Int; let insert: String }
        var edits: [Edit] = []
        var counter = 1
        for start in starts {
            let c = line(start)
            if (c as String).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let existing = max(prefixLen(Self.bulletRe, c), prefixLen(Self.numberRe, c))
            let insert: String
            if removing { insert = "" }
            else if ordered { insert = "\(counter). "; counter += 1 }
            else { insert = "• " }
            edits.append(Edit(start: start, removeLen: existing, insert: insert))
        }
        storage.beginEditing()
        for e in edits.sorted(by: { $0.start > $1.start }) {
            storage.replaceCharacters(in: NSRange(location: e.start, length: e.removeLen),
                                      with: NSAttributedString(string: e.insert, attributes: baseAttrs))
        }
        storage.endEditing()
        let newLen = (storage.string as NSString).length
        tv.setSelectedRange(NSRange(location: min(NSMaxRange(block), newLen), length: 0))
    }
}

struct MailRichTextEditor: NSViewRepresentable {
    let controller: MailRichTextController

    func makeCoordinator() -> Coordinator { Coordinator(controller) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        guard let tv = scroll.documentView as? NSTextView else { return scroll }
        tv.isRichText = true
        tv.importsGraphics = false
        tv.allowsImageEditing = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.drawsBackground = false
        tv.textContainerInset = NSSize(width: 8, height: 10)
        tv.font = .systemFont(ofSize: controller.baseFontSize)
        tv.textColor = .labelColor
        tv.typingAttributes = [.font: NSFont.systemFont(ofSize: controller.baseFontSize),
                               .foregroundColor: NSColor.labelColor]
        tv.delegate = context.coordinator
        tv.textStorage?.setAttributedString(controller.initial)
        controller.textView = tv
        if controller.focusOnAppear {
            DispatchQueue.main.async {
                tv.window?.makeFirstResponder(tv)
                tv.setSelectedRange(NSRange(location: 0, length: 0))
                tv.scrollRangeToVisible(NSRange(location: 0, length: 0))
            }
        }
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {}

    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        let controller: MailRichTextController
        init(_ controller: MailRichTextController) { self.controller = controller }
        func textDidChange(_ notification: Notification) { controller.noteChanged() }
    }
}
