import AppKit
import Carbon.HIToolbox
import SwiftUI
import MakoshTelegram

/// SwiftUI owns the formatted value; the coordinator owns only native selection/undo glue.
struct TelegramRichTextEditor: View {
    @Binding var value: TelegramFormattedText
    @Binding var error: String?
    var selection: TelegramInputSelection? = nil
    var accessibilityID = "telegram.actions.editText"
    var placeholder: String? = nil
    var inputChanged: ((TelegramComposerInput) -> Void)? = nil
    var submit: (() -> Void)? = nil
    @State private var height: CGFloat = 52
    var body: some View {
        NativeTelegramText(value: $value,error: $error,height: $height,selection: selection,
            accessibilityID: accessibilityID,inputChanged: inputChanged,submit: submit)
            .frame(height: height)
            .disabled(!value.isEditable)
            .overlay(alignment: .topLeading) {
                if value.text.isEmpty, let placeholder {
                    Text(placeholder).font(.system(size: 14)).foregroundStyle(.tertiary)
                        .padding(.horizontal, 7).padding(.top, 3)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }
}
private struct NativeTelegramText: NSViewRepresentable {
    @Binding var value: TelegramFormattedText
    @Binding var error: String?
    @Binding var height: CGFloat
    let selection: TelegramInputSelection?
    let accessibilityID: String
    let inputChanged: ((TelegramComposerInput) -> Void)?
    let submit: (() -> Void)?
    func makeCoordinator() -> Coordinator {
        Coordinator(value: $value,error: $error,height: $height,selection: selection,inputChanged: inputChanged)
    }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = TelegramGrowingScrollView()
        scroll.hasVerticalScroller = false; scroll.scrollerStyle = .overlay; scroll.borderType = .bezelBorder
        let text = TelegramNativeInput(frame: .zero)
        text.isRichText = true; text.importsGraphics = false; text.allowsUndo = true
        text.textColor = .labelColor; text.backgroundColor = .textBackgroundColor
        text.typingAttributes = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NSColor.labelColor]
        text.isAutomaticLinkDetectionEnabled = false; text.isAutomaticDataDetectionEnabled = false
        text.isAutomaticTextReplacementEnabled = false; text.isAutomaticQuoteSubstitutionEnabled = false
        text.isAutomaticDashSubstitutionEnabled = false
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true
        text.textContainer?.heightTracksTextView = false
        text.minSize = .zero; text.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude,height: CGFloat.greatestFiniteMagnitude)
        scroll.didLayout = { [weak coordinator = context.coordinator,weak text,weak scroll] in
            guard let coordinator,let text,let scroll else { return }
            coordinator.measure(text,in: scroll)
        }
        text.setAccessibilityIdentifier(accessibilityID)
        text.setAccessibilityLabel(accessibilityID == "telegram.composer" ? "Сообщение в Telegram" :
            accessibilityID == "telegram.upload.caption" ? "Подпись к вложению" : "Изменить сообщение")
        text.delegate = context.coordinator
        text.format = { [weak coordinator = context.coordinator,weak text] kind in
            guard let coordinator,let text else { return }
            coordinator.apply(kind,in: text)
        }
        text.requestLink = { [weak coordinator = context.coordinator,weak text] in
            guard let coordinator,let text else { return }
            coordinator.editLink(in: text)
        }
        text.submit = submit
        scroll.documentView = text
        context.coordinator.install(value,in: text)
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView,context: Context) {
        let coordinator = context.coordinator
        coordinator.value = $value; coordinator.error = $error; coordinator.height = $height
        coordinator.selection = selection; coordinator.inputChanged = inputChanged
        guard let text = scroll.documentView as? NSTextView else { return }
        (text as? TelegramNativeInput)?.submit = submit
        text.isEditable = value.isEditable
        let installedDifferentValue = coordinator.lastValue != value
        if installedDifferentValue { coordinator.install(value,in: text) }
        else { coordinator.installSelection(in: text) }
        coordinator.measure(text,in: scroll)
    }
    static func dismantleNSView(_ scroll: NSScrollView,coordinator: Coordinator) {
        coordinator.detach()
        (scroll.documentView as? NSTextView)?.undoManager?.removeAllActions()
        (scroll as? TelegramGrowingScrollView)?.didLayout = nil
        (scroll.documentView as? NSTextView)?.delegate = nil
        (scroll.documentView as? TelegramNativeInput)?.format = nil
        (scroll.documentView as? TelegramNativeInput)?.requestLink = nil
        (scroll.documentView as? TelegramNativeInput)?.submit = nil
    }
    @MainActor final class Coordinator: NSObject,NSTextViewDelegate {
        var value: Binding<TelegramFormattedText>
        var error: Binding<String?>
        var lastValue: TelegramFormattedText?
        var height: Binding<CGFloat>
        var selection: TelegramInputSelection?
        var inputChanged: ((TelegramComposerInput) -> Void)?
        private var installing = false
        private var active = true
        private var revision = UUID()
        private var measurementTask: Task<Void,Never>?
        func detach() { active = false; measurementTask?.cancel(); measurementTask = nil }
        init(value: Binding<TelegramFormattedText>,error: Binding<String?>,height: Binding<CGFloat>,
             selection: TelegramInputSelection?,inputChanged: ((TelegramComposerInput) -> Void)?) {
            self.value = value; self.error = error; self.height = height
            self.selection = selection; self.inputChanged = inputChanged
        }
        func measure(_ text: NSTextView,in scroll: NSScrollView) {
            measurementTask?.cancel()
            measurementTask = Task { @MainActor [weak self,weak text,weak scroll] in
                guard !Task.isCancelled,let self,let text,let scroll,self.active,
                      let container = text.textContainer,let layout = text.layoutManager,
                      scroll.contentSize.width > 0 else { return }
                self.measurementTask = nil
                if abs(text.frame.width - scroll.contentSize.width) > 0.5 {
                    text.setFrameSize(NSSize(width: scroll.contentSize.width,height: text.frame.height))
                }
                container.containerSize = NSSize(width: max(1,scroll.contentSize.width - text.textContainerInset.width * 2),height: CGFloat.greatestFiniteMagnitude)
                layout.ensureLayout(for: container)
                let contentHeight = ceil(layout.usedRect(for: container).height + text.textContainerInset.height * 2 + 2)
                let bounded = min(160,max(52,contentHeight))
                scroll.hasVerticalScroller = contentHeight > 160
                let documentHeight = max(contentHeight,scroll.contentSize.height)
                if abs(text.frame.height - documentHeight) > 0.5 {
                    text.setFrameSize(NSSize(width: scroll.contentSize.width,height: documentHeight))
                }
                if abs(self.height.wrappedValue - bounded) > 0.5 { self.height.wrappedValue = bounded }
            }
        }
        func install(_ value: TelegramFormattedText,in text: NSTextView) {
            revision = UUID()
            do {
                let attributed = try TelegramAttributedText.attributedString(value)
                let previousSelection = text.selectedRange()
                installing = true
                text.undoManager?.removeAllActions()
                text.textStorage?.setAttributedString(attributed)
                if let selection { text.setSelectedRange(NSRange(location: selection.location,length: selection.length)) }
                else { text.setSelectedRange(NSRange(location: min(previousSelection.location,attributed.length),length: min(previousSelection.length,max(0,attributed.length - min(previousSelection.location,attributed.length))))) }
                installing = false
                lastValue = value
            } catch {
                let expectedRevision = revision
                Task { @MainActor [weak self] in
                    guard let self,self.active,self.revision == expectedRevision else { return }
                    self.error.wrappedValue = "Не удалось восстановить форматирование Telegram."
                }
            }
        }
        func installSelection(in text: NSTextView) {
            guard let selection else { return }
            let range = NSRange(location: selection.location,length: selection.length)
            guard text.selectedRange() != range else { return }
            installing = true; text.setSelectedRange(range); installing = false
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard active,!installing,inputChanged != nil,let text = notification.object as? NSTextView,
                  let current = try? TelegramAttributedText.formattedText(text.attributedString()),
                  current == lastValue else { return }
            _ = report(current,in: text)
        }
        private func report(_ next: TelegramFormattedText,in text: NSTextView) -> Bool {
            if let inputChanged {
                let range = text.selectedRange()
                guard let input = try? TelegramComposerInput(formattedText: next,
                    selection: TelegramInputSelection(location: range.location,length: range.length)) else {
                    error.wrappedValue = "Не удалось сохранить выделение текста."; return false
                }
                selection = input.selection
                inputChanged(input)
            } else { value.wrappedValue = next }
            return true
        }
        // Editing a Telegram link must never invoke NSWorkspace or an external browser.
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool { true }
        func textDidChange(_ notification: Notification) {
            guard active,!installing,let text = notification.object as? NSTextView else { return }
            revision = UUID()
            if let scroll = text.enclosingScrollView { measure(text,in: scroll) }
            do {
                let next = try TelegramAttributedText.formattedText(text.attributedString())
                let previous = lastValue
                // Publishing can synchronously update the representable. It must see
                // the value already installed, or install() would erase native redo.
                lastValue = next
                if report(next,in: text) { error.wrappedValue = nil }
                else { lastValue = previous }
            } catch { self.error.wrappedValue = "Форматирование не сохранено. Отмените последнее изменение перед отправкой." }
        }
        private func replace(_ value: NSAttributedString,selection: NSRange,in text: NSTextView) {
            let undoManager = text.undoManager
            let registrationEnabled = undoManager?.isUndoRegistrationEnabled == true
            if registrationEnabled { undoManager?.disableUndoRegistration() }
            // Storage and selection form one input snapshot. Delegate callbacks
            // must never publish the temporary selection created by replacement.
            installing = true
            text.textStorage?.setAttributedString(value)
            text.setSelectedRange(selection)
            installing = false
            if registrationEnabled { undoManager?.enableUndoRegistration() }
            text.didChangeText()
        }
        private func registerUndo(_ previous: NSAttributedString, selection: NSRange, in text: NSTextView) {
            text.undoManager?.registerUndo(withTarget: self) { coordinator in
                MainActor.assumeIsolated {
                    guard coordinator.active else { return }
                    let inverse = NSAttributedString(attributedString: text.attributedString())
                    let inverseSelection = text.selectedRange()
                    coordinator.registerUndo(inverse, selection: inverseSelection, in: text)
                    coordinator.replace(previous,selection: selection,in: text)
                }
            }
            text.undoManager?.setActionName("Форматирование Telegram")
        }
        func editLink(in text: NSTextView) {
            let selection = text.selectedRange(), expectedRevision = revision
            guard active,selection.length > 0,let window = text.window else { return }
            let alert = NSAlert(); alert.messageText = "Изменить ссылку"
            let field = NSTextField(frame: NSRect(x: 0,y: 0,width: 320,height: 24))
            if let current = try? TelegramAttributedText.formattedText(text.attributedString()),
               let entity = current.entities.first(where: { $0.offset == selection.location && $0.length == selection.length }),
               case let .textURL(url) = entity.kind { field.stringValue = url }
            field.placeholderString = "Адрес ссылки"
            alert.accessoryView = field; alert.addButton(withTitle: "Готово"); alert.addButton(withTitle: "Отмена")
            alert.beginSheetModal(for: window) { [weak self,weak text] response in
                MainActor.assumeIsolated {
                    guard response == .alertFirstButtonReturn,let self,let text,self.active,
                          self.revision == expectedRevision,text.selectedRange() == selection else { return }
                    self.apply(.textURL(url: field.stringValue),in: text)
                }
            }
        }
        func apply(_ kind: TelegramTextEntityKind,in text: NSTextView) {
            let range = text.selectedRange()
            guard range.length > 0 else {
                self.error.wrappedValue = "Сначала выделите текст."; return
            }
            do {
                let current = try TelegramAttributedText.formattedText(text.attributedString())
                var entities = current.entities
                if case .textURL = kind {
                    entities.removeAll { entity in
                        if case .textURL = entity.kind { return entity.offset == range.location && entity.length == range.length }
                        return false
                    }
                    if case let .textURL(url) = kind,!url.isEmpty { entities.append(TelegramTextEntity(offset: range.location,length: range.length,kind: kind)) }
                } else if let index = entities.firstIndex(where: { $0.offset == range.location && $0.length == range.length && $0.kind == kind }) {
                    entities.remove(at: index)
                } else { entities.append(TelegramTextEntity(offset: range.location,length: range.length,kind: kind)) }
                let next = try TelegramFormattedText(text: current.text,entities: entities)
                let replacement = try TelegramAttributedText.attributedString(next)
                guard text.shouldChangeText(in: NSRange(location: 0,length: text.string.utf16.count),replacementString: next.text) else { return }
                let previous = NSAttributedString(attributedString: text.attributedString())
                registerUndo(previous, selection: range, in: text)
                replace(replacement,selection: range,in: text)
                self.error.wrappedValue = nil
            } catch { self.error.wrappedValue = "Это выделение несовместимо с границами форматирования Telegram." }
        }
    }
}

@MainActor private final class TelegramGrowingScrollView: NSScrollView {
    var didLayout: (() -> Void)?
    override func layout() { super.layout(); didLayout?() }
}

@MainActor private final class TelegramNativeInput: NSTextView {
    var format: ((TelegramTextEntityKind) -> Void)?
    var requestLink: (() -> Void)?
    var submit: (() -> Void)?
    private let commands: [(String,String,NSEvent.ModifierFlags,TelegramTextEntityKind?)] = [
        ("Жирный","b",.command,.bold),("Курсив","i",.command,.italic),
        ("Моноширинный","k",[.command,.shift],.code),("Ссылка…","u",.command,nil),
        ("Зачёркнутый","x",[.command,.shift],.strikethrough),("Подчёркнутый","u",[.command,.shift],.underline),
        ("Спойлер","p",[.command,.shift],.spoiler),("Цитата","i",[.command,.shift],.blockQuote(isCollapsed: false)),
        ("Блок кода","",[],.pre(language: nil))]
    private let commandKeyCodes: [String: UInt16] = [
        "b": UInt16(kVK_ANSI_B), "i": UInt16(kVK_ANSI_I), "k": UInt16(kVK_ANSI_K),
        "u": UInt16(kVK_ANSI_U), "x": UInt16(kVK_ANSI_X), "p": UInt16(kVK_ANSI_P)]
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let formatting = NSMenu(title: "Форматирование")
        for (index,command) in commands.enumerated() {
            let item = NSMenuItem(title: command.0,action: #selector(transform(_:)),keyEquivalent: command.1)
            item.target = self; item.tag = index; item.keyEquivalentModifierMask = command.2
            item.isEnabled = isEditable && selectedRange().length > 0; formatting.addItem(item)
        }
        formatting.autoenablesItems = false
        menu.addItem(.separator())
        let parent = NSMenuItem(title: "Форматирование",action: nil,keyEquivalent: "")
        parent.submenu = formatting; menu.addItem(parent); return menu
    }
    @objc private func transform(_ sender: NSMenuItem) {
        guard isEditable,selectedRange().length > 0,commands.indices.contains(sender.tag) else { return }
        if let kind = commands[sender.tag].3 { format?(kind) } else { requestLink?() }
    }
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if performFormattingCommand(event) { return true }
        return super.performKeyEquivalent(with: event)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Return), !hasMarkedText(),
           event.modifierFlags.intersection([.command,.shift,.option,.control]).isEmpty,
           let submit { submit(); return }
        if !performFormattingCommand(event) { super.keyDown(with: event) }
    }
    private func performFormattingCommand(_ event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection([.command,.shift,.option,.control])
        if isEditable,selectedRange().length > 0,
           let command = commands.first(where: {
               !$0.1.isEmpty && $0.2 == modifiers &&
                   ($0.1 == event.charactersIgnoringModifiers?.lowercased() || commandKeyCodes[$0.1] == event.keyCode)
           }) {
            if let kind = command.3 { format?(kind) } else { requestLink?() }; return true
        }
        return false
    }
}
