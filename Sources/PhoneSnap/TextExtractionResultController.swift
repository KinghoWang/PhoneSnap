import AppKit
import UniformTypeIdentifiers

final class ExtractedTextView: NSTextView {
    var onSave: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else { return super.performKeyEquivalent(with: event) }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "a": selectAll(nil)
        case "c": copy(nil)
        case "x": cut(nil)
        case "v": paste(nil)
        case "z": event.modifierFlags.contains(.shift) ? undoManager?.redo() : undoManager?.undo()
        case "s": onSave?()
        default: return super.performKeyEquivalent(with: event)
        }
        return true
    }
}

final class TextExtractionResultController: NSWindowController {
    let textView = ExtractedTextView()
    private let message = NSTextField(wrappingLabelWithString: "来自当前编辑后的画面；默认保留换行。结果可修改，可能有错字；不会自动写入剪贴板。")
    var onClosed: (() -> Void)?

    init(text: String, sourceDescription: String? = nil) {
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 460),
                             styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        super.init(window: sheet)
        if let sourceDescription { message.stringValue = sourceDescription }
        sheet.title = "提取的文字 · 本机识别"
        sheet.minSize = NSSize(width: 620, height: 360)
        sheet.isReleasedWhenClosed = false
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = .systemFont(ofSize: 15)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = .width
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 680, height: CGFloat.greatestFiniteMagnitude)
        textView.string = text
        textView.onSave = { [weak self] in self?.saveText() }
        scroll.documentView = textView
        let merge = makeButton("合并换行（可撤销）", #selector(mergeLines))
        let copy = makeButton("复制全部文字", #selector(copyAllText))
        let save = makeButton("另存 TXT…", #selector(saveText))
        let done = makeButton("关闭", #selector(dismissResult))
        done.keyEquivalent = "\u{1b}"
        let buttons = NSStackView(views: [merge, copy, save, done])
        buttons.spacing = 8
        message.font = .systemFont(ofSize: 12)
        message.textColor = .secondaryLabelColor
        guard let root = sheet.contentView else { return }
        for view in [message, scroll, buttons] {
            view.translatesAutoresizingMaskIntoConstraints = false
            root.addSubview(view)
        }
        NSLayoutConstraint.activate([
            message.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            message.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            message.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            scroll.topAnchor.constraint(equalTo: message.bottomAnchor, constant: 12),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),
            buttons.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            buttons.leadingAnchor.constraint(greaterThanOrEqualTo: root.leadingAnchor, constant: 16),
            buttons.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -16)
        ])
        sheet.initialFirstResponder = textView
    }

    required init?(coder: NSCoder) { fatalError("not supported") }

    private func makeButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        return button
    }

    func present(on parent: NSWindow) {
        guard let window, parent.attachedSheet == nil else { return }
        parent.beginSheet(window) { [weak self] _ in
            self?.textView.string = ""
            self?.onClosed?()
        }
        window.makeFirstResponder(textView)
    }

    @objc func mergeLines() {
        let merged = TextExtraction.mergingLines(textView.string)
        guard merged != textView.string else { return }
        textView.breakUndoCoalescing()
        textView.insertText(merged, replacementRange: NSRange(location: 0, length: (textView.string as NSString).length))
        textView.breakUndoCoalescing()
        message.stringValue = "已合并换行。按 ⌘Z 可恢复；复制和导出均使用当前修改后的文字。"
    }

    func copyText(to pasteboard: NSPasteboard) -> Bool {
        guard !textView.string.isEmpty else { return false }
        pasteboard.clearContents()
        return pasteboard.setString(textView.string, forType: .string)
    }

    func exportData() -> Data { Data(textView.string.utf8) }

    @objc private func copyAllText() {
        message.stringValue = copyText(to: .general) ? "已复制当前全部文字。请检查错字与隐私后再分享。" : "未复制：文字为空或剪贴板写入失败。"
    }

    @objc private func saveText() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "截图文字.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try exportData().write(to: url, options: .atomic)
            message.stringValue = "已将当前文字保存为 UTF-8 TXT。"
        } catch {
            message.stringValue = "保存失败，请检查文件夹权限或磁盘空间。"
        }
    }

    @objc func dismissResult() {
        guard let window else { return }
        if let parent = window.sheetParent { parent.endSheet(window) }
        else { window.orderOut(nil); onClosed?() }
    }
}
