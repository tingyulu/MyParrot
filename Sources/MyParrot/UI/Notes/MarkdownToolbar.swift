import SwiftUI
import AppKit
import MyParrotCore

/// #2438 NOTE-03：筆記格式工具列（H1／H2／H3、B、I、S、清單、編號、勾選框、引用、程式碼、連結、表格、分隔線、標記）。
/// 每顆都呼叫 `MarkdownEditing` 的同一組純函式（選單 ⌘B／⌘I／⌘K／⌘⇧L 也走同一組）。
struct MarkdownToolbar: View {
    let proxy: NotesEditorProxy
    /// 現在能不能標記（錄音中／暫停中）。PERF-04：只看狀態，不在 body 讀 elapsed，筆記欄才不會跟著時鐘每 0.25 s 重建。
    var canMark: Bool
    /// 錄音經過秒數；只在按下標記時讀。nil＝現在不能標記。
    var markerElapsed: () -> TimeInterval?
    @State private var loc = Localizer.shared

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                chip(Text("H1"), help: "\(L("標題")) 1") { prefix("# ") }
                chip(Text("H2"), help: "\(L("標題")) 2") { prefix("## ") }
                chip(Text("H3"), help: "\(L("標題")) 3") { prefix("### ") }
                sep
                chip(Text("B").bold(), badge: "⌘B", help: L("粗體")) { wrap("**") }
                chip(Text("I").italic(), badge: "⌘I", help: L("斜體")) { wrap("*") }
                chip(Text("S").strikethrough(), help: L("刪除線")) { wrap("~~") }
                sep
                chip(Text("•"), help: L("清單")) { prefix("- ") }
                chip(Text("1."), help: L("編號清單")) { prefix("1. ") }
                chip(Text("☑"), badge: "⌘⇧L", help: L("勾選框")) { prefix("- [ ] ") }
                chip(Text("❝"), help: L("引用")) { prefix("> ") }
                chip(Text("</>"), help: L("程式碼")) { apply { MarkdownEditing.toggleCode($0, selection: $1) } }
                sep
                chip(Image(systemName: "link"), badge: "⌘K", help: L("連結")) { insertLink() }
                chip(Image(systemName: "tablecells"), help: L("表格")) {
                    apply { MarkdownEditing.insertTable2x2($0, selection: $1, headers: (L("欄 1"), L("欄 2"))) }
                }
                chip(Text("—"), help: L("分隔線")) { apply { MarkdownEditing.insertHR($0, selection: $1) } }
                sep
                chip(Image(systemName: "flag.fill"), badge: "⌘⇧M", help: L("標記"), tint: MP.blue) { insertMarker() }
                    .disabled(!canMark)
                    .opacity(canMark ? 1 : 0.4)
            }
            .padding(.vertical, 2)
        }
        .frame(height: 26)
    }

    private var sep: some View { Divider().frame(height: 14).padding(.horizontal, 2) }

    private func chip<Label: View>(_ label: Label, badge: String? = nil, help: String, tint: Color = .primary,
                                   action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 3) {
                label.font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(tint)
                if let badge { ShortcutBadge(symbol: badge, size: 9) }
            }
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(MP.line, lineWidth: 0.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(badge.map { "\(help) \($0)" } ?? help)
        .accessibilityLabel(help)
    }

    // MARK: 動作（全部走 MarkdownEditing；做完把焦點還給編輯器）

    private func apply(_ edit: @escaping (String, Range<Int>) -> MarkdownEdit?) {
        proxy.apply(edit)
        proxy.focus()
    }

    private func prefix(_ p: String) { apply { MarkdownEditing.prefixLines($0, selection: $1, with: p) } }
    private func wrap(_ m: String) { apply { MarkdownEditing.wrap($0, selection: $1, with: m) } }

    /// 連結：剪貼簿是網址 ⇒ `[選取](網址)`；否則 `[選取](url)` 並選中字面 url 讓人直接打。
    private func insertLink() {
        let clip = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let isURL = MarkdownEditing.isLikelyURL(clip)
        apply { MarkdownEditing.insertLink($0, selection: $1, url: isURL ? clip : "url", clipboardIsURL: isURL) }
    }

    /// 標記 ⚑：在游標處插入 `⚑ h:mm:ss `（錄音經過時間）。
    private func insertMarker() {
        guard let t = markerElapsed() else { return }
        apply { MarkdownEditing.insert($0, selection: $1, snippet: NotesDocument.marker(at: t)) }
    }
}
