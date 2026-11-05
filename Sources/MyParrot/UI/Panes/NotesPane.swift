import SwiftUI
import MyParrotCore

/// #2438 M5:筆記直欄＝`NotesEditorPane`(編輯／預覽、工具列、自動存檔),文件跟著 `NotesSession`
/// (待錄音＝草稿、錄音中鎖進行中那場、結束後／選中列＝那場的 `.notes.md`)。session 還沒建好時顯示空殼。
struct NotesPane: View {
    @Bindable var controller: RecordingController
    @Bindable var uiState: AppUIState
    @State private var loc = Localizer.shared

    var body: some View {
        if let n = uiState.notes {
            // PERF-04:工具列只吃 canMark(狀態,少變);elapsed 留在閉包、按下標記才讀,筆記欄不再跟時鐘每 0.25 s 重建。
            NotesEditorPane(store: n.store, proxy: n.proxy,
                            canMark: controller.state == .recording || controller.state == .paused,
                            markerElapsed: { controller.state == .recording || controller.state == .paused ? controller.elapsedExact : nil },
                            contextLabel: contextLabel(n), contextIcon: contextIcon(n),
                            onTimestamp: { t in seek(n, to: t) })
        } else {
            PaneEmptyState(kind: .notes, message: L("會議筆記會顯示在這裡"))
        }
    }

    private func contextLabel(_ n: NotesSession) -> String? {
        if n.lockedStem != nil { return L("錄音中") }
        if n.isDraft { return L("草稿") }
        return n.stem.map { SidecarSet.splitName($0.lastPathComponent).title }
    }

    private func contextIcon(_ n: NotesSession) -> String {
        if n.lockedStem != nil { return "lock.fill" }
        if n.isDraft { return "doc.badge.plus" }
        return "doc.text"
    }

    /// 預覽裡點時間戳:那場正在播就跳到該秒(Phase 1 只做 seek)。
    private func seek(_ n: NotesSession, to t: TimeInterval) {
        guard let s = n.stem, let playing = controller.playingURL, SidecarSet.stem(of: playing) == s else { return }
        controller.seek(to: t)
    }
}

/// 直欄沒內容時的置中空狀態:該欄圖示＋一句話。
struct PaneEmptyState: View {
    let kind: PaneKind
    let message: String

    var body: some View {
        VStack(spacing: MP.spS) {
            Image(systemName: kind.symbol).font(.system(size: 26, weight: .regular))
                .foregroundStyle(kind.tint.opacity(0.55))
            Text(message).font(MPFont.label).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center).lineSpacing(3)
        }
        .padding(MP.spL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
