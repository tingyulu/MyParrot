import SwiftUI
import MyParrotCore

enum NotesViewMode: String, CaseIterable { case edit, preview }

/// #2438 筆記面板內容（欄標題列由工作區的 PaneContainer 畫）：編輯｜預覽分段＋存檔狀態、工具列、編輯器／預覽、底部提示。
/// 文件切換（草稿／進行中那場／選中列）由呼叫端操作 `NotesStore`；這裡只顯示與編輯。
struct NotesEditorPane: View {
    let store: NotesStore
    let proxy: NotesEditorProxy
    /// 現在能不能標記（錄音中／暫停中）；PERF-04：狀態值，不是每 0.25 s 變的時鐘。
    var canMark: Bool = false
    /// 錄音經過秒數；只在按下標記時讀。nil＝現在不能標記。
    var markerElapsed: () -> TimeInterval?
    /// 標題列的鎖定提示（錄音中筆記鎖在進行中那場：「🔒 錄音中」；待錄音：「草稿」）。
    var contextLabel: String? = nil
    var contextIcon: String = "doc.text"
    var onTimestamp: ((TimeInterval) -> Void)? = nil

    @State private var mode: NotesViewMode = .edit
    @State private var loc = Localizer.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("", selection: $mode) {
                    Text(L("編輯")).tag(NotesViewMode.edit)
                    Text(L("預覽")).tag(NotesViewMode.preview)
                }
                .pickerStyle(.segmented).labelsHidden().controlSize(.small).frame(width: 110)
                if let c = contextLabel {
                    Label(c, systemImage: contextIcon).font(MPFont.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                status
            }
            if mode == .edit {
                MarkdownToolbar(proxy: proxy, canMark: canMark, markerElapsed: markerElapsed)
                NotesTextView(text: Binding(get: { store.text }, set: { store.setText($0) }), proxy: proxy)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                MarkdownPreview(text: store.text, onToggleCheckbox: { line in
                    store.setText(MarkdownEditing.toggleCheckbox(store.text, atLine: line).text)
                }, onTimestamp: onTimestamp)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text(L("純 .md，1 秒自動存檔 · Enter 接清單 · ⌘⏎ 切勾選"))
                .font(MPFont.caption).foregroundStyle(.tertiary).lineLimit(1)
        }
    }

    @ViewBuilder private var status: some View {
        if let e = store.lastError {
            Label(e, systemImage: "exclamationmark.triangle.fill").font(MPFont.caption).foregroundStyle(.red).lineLimit(1)
                .help(e)
        } else if store.isDirty {
            Text(L("儲存中…")).font(MPFont.caption).foregroundStyle(.secondary)
        } else if let t = store.lastSavedAt {
            Text("\(L("已存")) \(Self.hhmm(t))").font(MPFont.caption).foregroundStyle(.secondary).monospacedDigit()
        } else if store.url == nil {
            Text(L("尚未附到任何錄音")).font(MPFont.caption).foregroundStyle(.tertiary)
        }
    }

    static func hhmm(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: d)
    }
}
