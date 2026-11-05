import SwiftUI
import AppKit
import MyParrotCore

/// #2438 NOTE-03／04：工具列與選單對編輯器下指令的橋。拿目前 `NSTextView` 的字串與選取（UTF-16 偏移＝NSRange），
/// 套 `MarkdownEditing` 的純函式，寫回文字並更新選取；編輯器不在畫面上時什麼都不做、回 false。
@MainActor
@Observable
final class NotesEditorProxy {
    @ObservationIgnored weak var textView: NotesNSTextView?
    /// 編輯器是不是 first responder（I1：⌘K 在筆記有焦點時＝連結，否則＝最近錄音）。
    var isFocused = false

    @discardableResult
    func apply(_ edit: (String, Range<Int>) -> MarkdownEdit?) -> Bool {
        guard let tv = textView else { return false }
        return tv.applyEdit(edit)
    }

    func focus() {
        guard let tv = textView else { return }
        tv.window?.makeFirstResponder(tv)
    }
}

/// 純文字 Markdown 編輯器本體：Enter 接清單、Tab／⇧Tab 縮排、⌘⏎ 切勾選框、`[` `` ` `` `*` 自動成對、貼網址自動成連結。
final class NotesNSTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?
    /// 正在用 `applyEdit` 整段換字（避免 SwiftUI 的 updateNSView 又把字寫回來）。
    private(set) var isApplyingEdit = false

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocusChange?(true) }
        return ok
    }

    override func resignFirstResponder() -> Bool {
        let ok = super.resignFirstResponder()
        if ok { onFocusChange?(false) }
        return ok
    }

    private var selection: Range<Int> {
        let r = selectedRange()
        return r.location..<(r.location + r.length)
    }

    /// 套一個純函式編輯：回 nil＝不處理（讓呼叫端走預設行為）。整段替換走 undo 堆疊（⌘Z 可還原）。
    @discardableResult
    func applyEdit(_ edit: (String, Range<Int>) -> MarkdownEdit?) -> Bool {
        guard let e = edit(string, selection) else { return false }
        let full = NSRange(location: 0, length: (string as NSString).length)
        if e.text != string {
            guard shouldChangeText(in: full, replacementString: e.text) else { return false }
            isApplyingEdit = true
            textStorage?.replaceCharacters(in: full, with: e.text)
            didChangeText()
            isApplyingEdit = false
        }
        let len = (e.text as NSString).length
        let lo = min(max(0, e.selection.lowerBound), len)
        let hi = min(max(lo, e.selection.upperBound), len)
        setSelectedRange(NSRange(location: lo, length: hi - lo))
        scrollRangeToVisible(selectedRange())
        return true
    }

    override func insertNewline(_ sender: Any?) {
        if applyEdit({ MarkdownEditing.enterContinuesList($0, selection: $1) }) { return }
        super.insertNewline(sender)
    }

    override func insertTab(_ sender: Any?) {
        if applyEdit({ MarkdownEditing.indent($0, selection: $1) }) { return }
        super.insertTab(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        if applyEdit({ MarkdownEditing.outdent($0, selection: $1) }) { return }
        super.insertBacktab(sender)
    }

    override func keyDown(with event: NSEvent) {
        // ⌘⏎：切換游標列的勾選框（非勾選行 ⇒ 變成 `- [ ] `）。
        if event.keyCode == 36, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
           applyEdit({ MarkdownEditing.toggleCheckbox($0, selection: $1) }) { return }
        super.keyDown(with: event)
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        if let s = string as? String, s.count == 1, let ch = s.first, "[]`*".contains(ch),
           replacementRange.location == NSNotFound,
           applyEdit({ MarkdownEditing.autoPair($0, selection: $1, typed: ch) }) { return }
        super.insertText(string, replacementRange: replacementRange)
    }

    override func paste(_ sender: Any?) {
        if let s = NSPasteboard.general.string(forType: .string),
           applyEdit({ MarkdownEditing.linkifyPastedURL($0, selection: $1, pasted: s) }) { return }
        super.paste(sender)
    }
}

/// `NotesNSTextView` 包成 SwiftUI：等寬 12pt、不自動替換引號／破折號、`MarkdownHighlight` 套色。
struct NotesTextView: NSViewRepresentable {
    @Binding var text: String
    let proxy: NotesEditorProxy

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        let tv = NotesNSTextView()
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.font = Coordinator.baseFont
        tv.textContainerInset = NSSize(width: 8, height: 8)
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        tv.delegate = context.coordinator
        let p = proxy
        tv.onFocusChange = { focused in p.isFocused = focused }
        tv.string = text
        scroll.documentView = tv
        proxy.textView = tv
        context.coordinator.highlight(tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let tv = scroll.documentView as? NotesNSTextView else { return }
        proxy.textView = tv
        if tv.string != text, !tv.isApplyingEdit, !context.coordinator.isEditing {
            // 外部換檔／外部改字：整段換，游標盡量留在原位。
            let sel = tv.selectedRange()
            tv.string = text
            let len = (text as NSString).length
            tv.setSelectedRange(NSRange(location: min(sel.location, len), length: 0))
            context.coordinator.highlight(tv)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NotesTextView
        var isEditing = false
        static let baseFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        static let boldFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .bold)
        static let headingFont = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)

        init(_ parent: NotesTextView) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NotesNSTextView else { return }
            isEditing = true
            parent.text = tv.string
            isEditing = false
            scheduleHighlight(tv)
        }

        /// PERF-06：套色不再每鍵整篇重套——最後一鍵後 120 ms 跑一次；輸入法組字中（`hasMarkedText`）不碰屬性，
        /// 等組字送出的那次 `textDidChange` 再排（嘸蝦米等 IME 的候選與底線不被打斷）。外部換檔（makeNSView／updateNSView）仍直接套。
        static let highlightDebounce: TimeInterval = 0.12
        private var highlightWork: DispatchWorkItem?
        func scheduleHighlight(_ tv: NSTextView) {
            highlightWork?.cancel()
            let work = DispatchWorkItem { [weak self, weak tv] in
                guard let self, let tv else { return }
                // 二審:到期時還在組字 ⇒ 再排一輪(不靠「送出一定會再來一次 textDidChange」),組字結束那一刻就套。
                if tv.hasMarkedText() { self.scheduleHighlight(tv); return }
                self.highlight(tv)
            }
            highlightWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.highlightDebounce, execute: work)
        }

        /// NOTE-05：依 `MarkdownHighlight.spans` 套色（只改屬性，不動字、不進 undo）。組字中不套。
        func highlight(_ tv: NSTextView) {
            guard !tv.hasMarkedText(), let storage = tv.textStorage else { return }
            let s = tv.string
            let full = NSRange(location: 0, length: (s as NSString).length)
            storage.beginEditing()
            storage.setAttributes([.font: Self.baseFont, .foregroundColor: NSColor.textColor], range: full)
            for span in MarkdownHighlight.spans(in: s) {
                let r = NSRange(location: span.range.lowerBound, length: span.range.count)
                guard r.location >= 0, r.location + r.length <= full.length else { continue }
                switch span.kind {
                case .heading:
                    storage.addAttributes([.font: Self.headingFont, .foregroundColor: NSColor(MP.blue)], range: r)
                case .bold:
                    storage.addAttribute(.font, value: Self.boldFont, range: r)
                case .listMarker:
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)
                case .checkbox:
                    storage.addAttributes([.foregroundColor: NSColor(MP.blue), .font: Self.boldFont], range: r)
                case .quote:
                    storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: r)
                case .code:
                    storage.addAttribute(.backgroundColor, value: NSColor.labelColor.withAlphaComponent(0.07), range: r)
                case .timestamp:
                    storage.addAttributes([.foregroundColor: NSColor(MP.coral), .font: Self.boldFont], range: r)
                case .link:
                    storage.addAttributes([.foregroundColor: NSColor.linkColor,
                                           .underlineStyle: NSUnderlineStyle.single.rawValue], range: r)
                }
            }
            storage.endEditing()
        }
    }
}
