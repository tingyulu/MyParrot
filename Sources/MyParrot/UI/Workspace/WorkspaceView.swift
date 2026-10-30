import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MyParrotCore

/// #2438 M4 面板工作區(plan §3.4、spec §3.2;A1／B2／K1):
/// `控制欄(遙控器＋橫幅＋檔案面板)` 與 `內容直欄(逐字稿／筆記／會議記錄)` 橫向並排;
/// `remoteSide == .left` ⇒ 控制欄在左,否則在右(K1:只停左右,內容欄永遠在中間)。
///
/// 寬度口徑(與 `WorkspaceLayout.resolve` 對齊):視窗內左右各留 `outerPadding` 12;控制欄內容寬 356,
/// 連同兩側留白＝`leftWidth` 380(＝三欄全關／窄版的視窗寬,spec §3.2「現在 app 的形狀」);
/// 每開一欄 ＋ 間距 10 ＋ 欄寬(預設 380)。最右(或最靠控制欄)那欄有彈性:使用者自己拉大視窗時由它吃掉多出來的寬度,
/// 其餘欄固定在記住的寬度。
///
/// 視窗寬度只在**開關欄、停靠、會議記錄後端開關**與進入標準模式時重算(A1);使用者自己拖視窗邊不觸發。
/// Eric 2026-10-19 23:40～23:42 三條修正:1. 視窗最小寬度＝左欄＋每欄(間距＋320),縮不到比內容窄;2. 視窗比各欄記住的寬度窄
/// 時各欄**等比壓縮**到 320 下限(暫時狀態,不寫回偏好);3. 欄間把手＝左右兩欄在**目前視窗寬度內**互換寬度,不再拉大視窗。
/// 窄版／迷你沒有直欄(`open` 執行期視為空,不寫回偏好)。
struct WorkspaceView: View {
    @Bindable var controller: RecordingController
    let updates: UpdateChecker
    @Bindable var uiState: AppUIState
    let windowMode: WindowModeManager

    static let outerPadding: CGFloat = 12
    /// 控制欄連同視窗左右留白的寬度(＝`resolve` 的 `leftWidth`)。
    static let leftWidth: CGFloat = 380
    static var leftContentWidth: CGFloat { leftWidth - 2 * outerPadding }
    static let gap: CGFloat = 10
    static let minColumn: CGFloat = PaneState.minColumnWidth
    nonisolated static let coordinateSpaceName = "workspace"

    @State private var loc = Localizer.shared
    // UPD:〔×〕=本次啟動不再顯示(不持久化,重啟再現)。從 RootView 搬來。
    @State private var updateBannerDismissed = false
    /// 拉欄寬中的暫時寬度(放開才寫進 `panes`)。
    @State private var liveWidths: [PaneKind: CGFloat] = [:]
    /// 螢幕放不下時的壓縮寬度(只當這次 frame 用,🚫 不寫回偏好——report-M4 裁示 3:只有使用者自己拉的寬度才存)。
    @State private var compressedWidths: [PaneKind: CGFloat] = [:]
    @State private var dragBase: CGFloat = 0
    @State private var dragBaseRight: CGFloat = 0
    /// 各內容欄在工作區座標的 frame(放下點換算、插入指示線位置)。
    @State private var columnFrames: [PaneKind: CGRect] = [:]
    @State private var workspaceWidth: CGFloat = 0
    /// 拖曳中的插入指示線(工作區座標 x)。
    @State private var dropIndicatorX: CGFloat?
    @State private var resolveGeneration = 0

    /// 給 DebugControl `snapshot` 用:這組面板狀態在標準模式下的目標視窗寬(不含螢幕限制)。
    static func targetWidth(_ panes: PaneState, minutesEnabled: Bool) -> CGFloat {
        panes.openWidths(minutesEnabled: minutesEnabled).reduce(leftWidth) { $0 + gap + $1 }
    }

    /// 視窗最小寬度(掛在 MyParrotApp 的 `.frame(minWidth:)`):標準模式＝左欄＋每個開著的欄(間距＋320);其他模式＝左欄。
    static func minimumWindowWidth(_ ui: AppUIState, mode: WindowMode) -> CGFloat {
        guard mode == .standard else { return leftWidth }
        let n = ui.panes.visibleColumns(minutesEnabled: ui.minutesEnabled).count
        return WorkspaceLayout.minimumWidth(leftWidth: leftWidth, gap: gap, columns: n, minColumn: minColumn)
    }

    // MARK: 版面

    private enum Slot: Hashable {
        case remote, gap
        case pane(PaneKind)
        /// 把手在這一欄的右邊,拖它改這一欄的寬度。
        case handle(PaneKind)
    }

    /// 畫面上的內容欄(依順序)。窄版／迷你 ⇒ 空。
    private var columns: [PaneKind] {
        guard windowMode.mode == .standard else { return [] }
        return uiState.panes.visibleColumns(minutesEnabled: uiState.minutesEnabled)
    }

    private func slots(_ cols: [PaneKind]) -> [Slot] {
        var out: [Slot] = []
        let left = uiState.panes.remoteSide == .left
        if left { out.append(.remote); if !cols.isEmpty { out.append(.gap) } }
        for (i, k) in cols.enumerated() {
            if i > 0 { out.append(.handle(cols[i - 1])) }
            out.append(.pane(k))
        }
        if !left { if !cols.isEmpty { out.append(.gap) }; out.append(.remote) }
        return out
    }

    private func width(of kind: PaneKind) -> CGFloat {
        liveWidths[kind] ?? compressedWidths[kind] ?? uiState.panes.width(of: kind)
    }

    var body: some View {
        let cols = columns
        // 可用寬度用 GeometryReader 量(它永遠拿到視窗給的空間);🚫 不能量 HStack 自己:內容放不下時 HStack 回報的是
        // 自己撐開的寬,壓縮就會算少、內容照樣溢出被兩邊裁掉(2026-10-19 23:5x 真機量到 32pt)。
        GeometryReader { geo in
            HStack(alignment: .top, spacing: 0) {
                ForEach(slots(cols), id: \.self) { slot in
                    switch slot {
                    case .remote:
                        controlColumn(flexible: cols.isEmpty)
                    case .gap:
                        Color.clear.frame(width: Self.gap)
                    case .pane(let kind):
                        paneColumn(kind, in: cols)
                    case .handle(let kind):
                        resizeHandle(for: kind, in: cols)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .coordinateSpace(.named(Self.coordinateSpaceName))
            .overlay(alignment: .topLeading) { dropIndicator }
            .onChange(of: geo.size.width, initial: true) { _, w in workspaceWidth = w; recompress() }
        }
        .onChange(of: layoutKey) { old, new in
            scheduleResolve(reason: new.open.count > old.open.count ? .opened : .changed)
            recompress()
        }
        .onChange(of: uiState.panes.widths) { _, _ in recompress() }
        .onAppear { scheduleResolve(reason: .appear) }
    }

    /// 修正 2:視窗(工作區)比各欄記住的寬度總和窄 ⇒ 等比壓縮到 320 下限(`WorkspaceLayout.compress`,水位填平);
    /// 放得下就用記住的寬。只當這次版面用,不寫回偏好;拉把手中不動。
    private func recompress() {
        let cols = columns
        guard liveWidths.isEmpty, !cols.isEmpty, workspaceWidth > 0 else {
            if !compressedWidths.isEmpty { compressedWidths = [:] }
            return
        }
        let stored = cols.map { uiState.panes.width(of: $0) }
        let natural = stored.reduce(Self.leftContentWidth) { $0 + Self.gap + $1 }
        if workspaceWidth + 0.5 >= natural {
            if !compressedWidths.isEmpty { compressedWidths = [:] }
            return
        }
        let room = workspaceWidth - Self.leftContentWidth - Self.gap * CGFloat(cols.count)
        let fitted = WorkspaceLayout.compress(stored, toFit: room, floor: Self.minColumn)
        let next = Dictionary(uniqueKeysWithValues: zip(cols, fitted))
        if next != compressedWidths { compressedWidths = next }
    }

    // MARK: 控制欄(遙控器＋橫幅＋檔案面板)

    private func controlColumn(flexible: Bool) -> some View {
        VStack(alignment: .leading, spacing: MP.spM) {
            RemoteView(controller: controller, uiState: uiState, windowMode: windowMode)
                // 控制欄整欄搬家(停靠換邊、模式切換、視窗自動加寬)時,鸚鵡的 phaseAnimator(點頭 0.2 s＋延遲 3.6 s)
                // 會把位置變動也帶上動畫,真機看到牠從舊位置慢慢飛過來(M4 實測)。把遙控器的幾何當成一個整體,
                // 位移只套在這一層、不往下傳到動畫中的子 view。
                .geometryGroup()
                .frame(maxWidth: .infinity, alignment: .center)
            banners
            FilesPane(controller: controller, uiState: uiState)
            if !uiState.panes.filesExpanded { Spacer(minLength: 0) }
        }
        .frame(minWidth: Self.leftContentWidth, idealWidth: Self.leftContentWidth,
               maxWidth: flexible ? .infinity : Self.leftContentWidth, maxHeight: .infinity, alignment: .top)
    }

    /// 警告／權限／更新三種橫幅(原 `RootView.controlSection`,原封不動搬來,放遙控器下方)。
    @ViewBuilder private var banners: some View {
        // #949 REC-35:CLI 在錄 ⇒ 最上面的橘色橫幅(名稱／時間／電平／暫停＋停止鈕),在警示橫幅之上。
        if controller.externalRecording != nil {
            ExternalRecordingBanner(controller: controller)
        }
        if let warn = controller.warning {
            HStack(spacing: MP.spS) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                // BUG-28:Core 只給「哪一種警示+參數」,這裡依介面語言組字。
                Text(warn.localized).font(MPFont.caption).foregroundStyle(.orange).lineSpacing(3)
                Spacer()
                Button { controller.warning = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
            }
            .mpBanner(color: .orange)
        }
        if !controller.micPermission || !controller.speechPermission {
            HStack(spacing: MP.spS) {
                Image(systemName: "lock.shield").foregroundStyle(MP.blue)
                Text(L("需要麥克風 / 語音辨識 / 系統音訊權限")).font(MPFont.caption).foregroundStyle(.secondary).lineSpacing(3)
                Spacer()
                Button(L("授權")) { Task { await controller.requestPermissions() } }.font(MPFont.caption)
            }
            .mpBanner(color: MP.blue)
        }
        // UPD:非阻斷更新提示——僅 idle 時顯示(錄音/暫停中不打擾,開會場景)。MAS-14:商店版不編(status 永遠 idle)。
        #if !MYPARROT_MAS
        if case .updateAvailable(let ver, let url) = updates.status,
           controller.state == .idle, !updateBannerDismissed {
            HStack(spacing: MP.spS) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(MP.blue)
                Text(L("有新版本") + " v\(ver)").font(MPFont.caption)
                Spacer()
                Button(L("前往下載")) { NSWorkspace.shared.open(url) }.controlSize(.small)
                Button(L("略過此版")) { updates.skip() }.controlSize(.small)
                Button { updateBannerDismissed = true } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
            }
            .mpBanner(color: MP.blue)
        }
        #endif
    }

    // MARK: 內容直欄

    private func paneColumn(_ kind: PaneKind, in cols: [PaneKind]) -> some View {
        let w = width(of: kind)
        let isLast = kind == cols.last
        let index = cols.firstIndex(of: kind) ?? 0
        return PaneContainer(kind: kind, uiState: uiState,
                             canMoveLeft: index > 0, canMoveRight: index < cols.count - 1) {
            paneControls(kind)
        } content: {
            paneContent(kind)
        }
        .frame(minWidth: isLast ? min(w, Self.minColumn) : w, idealWidth: w,
               maxWidth: isLast ? .infinity : w, maxHeight: .infinity)
        .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(Self.coordinateSpaceName)) } action: {
            columnFrames[kind] = $0
            uiState.renderedColumnWidths[kind] = $0.width
        }
        .onDrop(of: [.text], delegate: PaneDropDelegate(
            target: kind, frame: columnFrames[kind] ?? .zero, workspaceWidth: workspaceWidth,
            columns: cols, uiState: uiState, indicatorX: $dropIndicatorX))
    }

    @ViewBuilder private func paneControls(_ kind: PaneKind) -> some View {
        switch kind {
        case .transcript:
            HStack(spacing: MP.spS) {
                TranslationControl(controller: controller, uiState: uiState)   // #2612 TRL-07:翻譯後端 off 時不出現
                TranscriptRangeControl(uiState: uiState)
            }
        case .notes, .minutes: EmptyView()
        }
    }

    @ViewBuilder private func paneContent(_ kind: PaneKind) -> some View {
        switch kind {
        case .transcript: TranscriptPane(controller: controller, uiState: uiState)
        case .notes: NotesPane(controller: controller, uiState: uiState)
        case .minutes: MinutesPane(controller: controller, uiState: uiState)
        }
    }

    // MARK: 欄寬(拖欄間把手)

    /// 修正 3:把手在 `kind` 右邊,拖它＝`kind` 與右鄰那欄在目前視窗寬度內互換寬度(`WorkspaceLayout.redistribute`),
    /// 兩欄都不低於 320、視窗不動。基準取**畫面上實際渲染**的寬(右鄰若是彈性的最後一欄,可能比記住的寬);
    /// 放開時兩欄的新寬都寫進偏好(記住的＝看到的),該兩欄的壓縮暫存清掉。
    private func resizeHandle(for kind: PaneKind, in cols: [PaneKind]) -> some View {
        let right: PaneKind? = cols.firstIndex(of: kind).flatMap { $0 + 1 < cols.count ? cols[$0 + 1] : nil }
        return ColumnResizeHandle(
            onBegin: {
                dragBase = columnFrames[kind]?.width ?? width(of: kind)
                dragBaseRight = right.flatMap { columnFrames[$0]?.width ?? width(of: $0) } ?? 0
            },
            onChange: { dx in
                guard let right else { return }
                let r = WorkspaceLayout.redistribute(left: dragBase, right: dragBaseRight, dx: dx, floor: Self.minColumn)
                liveWidths[kind] = r.left
                liveWidths[right] = r.right
            },
            onEnd: { dx in
                guard let right else { liveWidths = [:]; return }
                let r = WorkspaceLayout.redistribute(left: dragBase, right: dragBaseRight, dx: dx, floor: Self.minColumn)
                liveWidths = [:]
                compressedWidths[kind] = nil
                compressedWidths[right] = nil
                uiState.panes.setWidth(r.left, for: kind)
                uiState.panes.setWidth(r.right, for: right)
            })
    }

    // MARK: 視窗寬度(A1)

    /// 欄寬不在 key 裡:拉把手是視窗內互換(修正 3),不動視窗。
    private struct LayoutKey: Equatable {
        var open: Set<PaneKind>
        var side: RemoteSide
        var minutesEnabled: Bool
        var mode: WindowMode
    }

    private var layoutKey: LayoutKey {
        LayoutKey(open: uiState.panes.open, side: uiState.panes.remoteSide,
                  minutesEnabled: uiState.minutesEnabled, mode: windowMode.mode)
    }

    private enum ResolveReason { case appear, opened, changed }

    /// 等這一輪 SwiftUI 更新(含 MyParrotApp 的 `applyInitialFrame`、模式切換的自存 frame)跑完再算;
    /// 連續變動只算最後一次。
    private func scheduleResolve(reason: ResolveReason) {
        resolveGeneration &+= 1
        let generation = resolveGeneration
        Task { @MainActor in
            await Task.yield()
            guard generation == resolveGeneration else { return }
            resolveWindowFrame(reason: reason)
        }
    }

    /// A1:開一欄 ⇒ 視窗長到放得下各欄記住的寬(本來就更寬就不縮);關欄／停靠／模式 ⇒ 縮回各欄記住的寬;
    /// 進入標準模式 ⇒ 只保證不比最小寬度窄(自存 frame 比內容窄時 hosting view 會把內容置中裁掉)。
    /// 壓縮不在這裡算(`recompress` 依實際工作區寬度算)。
    private func resolveWindowFrame(reason: ResolveReason) {
        guard windowMode.mode == .standard, liveWidths.isEmpty,
              let window = windowMode.currentWindow(), let visible = windowMode.currentVisibleFrame() else { return }
        let widths = uiState.panes.openWidths(minutesEnabled: uiState.minutesEnabled)
        let r = WorkspaceLayout.resolve(current: window.frame, leftWidth: Self.leftWidth, gap: Self.gap,
                                        openWidths: widths, minColumn: Self.minColumn, visible: visible)
        var frame = r.frame
        switch reason {
        case .appear:
            let minW = min(WorkspaceLayout.minimumWidth(leftWidth: Self.leftWidth, gap: Self.gap, columns: widths.count,
                                                        minColumn: Self.minColumn), visible.width)
            if window.frame.width + 0.5 >= minW { return }
            frame = CGRect(x: min(window.frame.minX, visible.maxX - minW), y: r.frame.minY, width: minW, height: r.frame.height)
        case .opened:
            if window.frame.width + 0.5 >= r.frame.width { return }
        case .changed:
            break
        }
        windowMode.applyWorkspaceFrame(frame, animate: true)
    }

    // MARK: 拖曳指示線

    @ViewBuilder private var dropIndicator: some View {
        if let x = dropIndicatorX {
            Capsule().fill(MP.blue)
                .frame(width: 2)
                .frame(maxHeight: .infinity)
                .offset(x: min(max(x, 1), max(workspaceWidth - 1, 1)) - 1)
                .allowsHitTesting(false)
        }
    }
}

/// 內容欄的放下處理(換位與停靠;spec K1、plan §3.4)。整欄(標題列＋本體)都是放下目標。
/// - 拖的是 `"remote"`(狀態藥丸 ⋮⋮)⇒ 以放下點與視窗中線判定停靠邊(`PaneState.dock(dropX:windowWidth:)`)。
/// - 拖的是某欄(欄標題 ⋮⋮)⇒ 放在目標欄左半＝插到它前面、右半＝插到它後面,換算成 `PaneState.move(_:by:)`。
/// - 指示線:停靠＝工作區最左／最右;換位＝目標欄左／右緣外的間距中線;不會改變順序時不畫。
@MainActor
private struct PaneDropDelegate: DropDelegate {
    let target: PaneKind
    let frame: CGRect
    let workspaceWidth: CGFloat
    let columns: [PaneKind]
    let uiState: AppUIState
    @Binding var indicatorX: CGFloat?

    func validateDrop(info: DropInfo) -> Bool { info.hasItemsConforming(to: [.text]) }

    func dropEntered(info: DropInfo) { updateIndicator(info) }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        updateIndicator(info)
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) { indicatorX = nil }

    func performDrop(info: DropInfo) -> Bool {
        indicatorX = nil
        let x = frame.minX + info.location.x
        let (target, frame, width, columns, uiState) = (self.target, self.frame, self.workspaceWidth, self.columns, self.uiState)
        guard let provider = info.itemProviders(for: [.text]).first else { return false }
        _ = provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let text = (object as? NSString).map({ $0 as String }) else { return }
            Task { @MainActor in
                WorkspaceDrop.apply(text, x: x, target: target, targetFrame: frame,
                                    workspaceWidth: width, columns: columns, uiState: uiState)
            }
        }
        return true
    }

    private func updateIndicator(_ info: DropInfo) {
        let x = frame.minX + info.location.x
        switch uiState.dragPayload {
        case WorkspaceDrop.remotePayload?:
            indicatorX = x < workspaceWidth / 2 ? 0 : workspaceWidth
        case let raw?:
            guard let kind = PaneKind(rawValue: raw),
                  WorkspaceDrop.moveDelta(kind, x: x, target: target, targetFrame: frame, columns: columns) != 0 else {
                indicatorX = nil; return
            }
            indicatorX = x < frame.midX ? frame.minX - WorkspaceView.gap / 2 : frame.maxX + WorkspaceView.gap / 2
        case nil:
            indicatorX = nil
        }
    }
}

@MainActor
enum WorkspaceDrop {
    nonisolated static let remotePayload = "remote"

    /// 放在目標欄左半＝插到它前面、右半＝插到它後面;回 `move(_:by:)` 要的格數(以畫面上的欄為準)。
    nonisolated static func moveDelta(_ kind: PaneKind, x: CGFloat, target: PaneKind, targetFrame: CGRect,
                                      columns: [PaneKind]) -> Int {
        guard kind != target, let i = columns.firstIndex(of: kind), let t = columns.firstIndex(of: target) else { return 0 }
        let after = x >= targetFrame.midX
        let final = after ? (i > t ? t + 1 : t) : (i > t ? t : t - 1)
        return final - i
    }

    static func apply(_ payload: String, x: CGFloat, target: PaneKind, targetFrame: CGRect,
                      workspaceWidth: CGFloat, columns: [PaneKind], uiState: AppUIState) {
        uiState.dragPayload = nil
        if payload == remotePayload {
            // K1:視窗中線＝工作區中線(左右留白相同);換成視窗座標再判定,跟 spec 的口徑一致。
            let pad = WorkspaceView.outerPadding
            uiState.panes.dock(dropX: x + pad, windowWidth: workspaceWidth + 2 * pad)
            return
        }
        guard let kind = PaneKind(rawValue: payload) else { return }   // 外部 App 拖進來的字:不處理
        let delta = moveDelta(kind, x: x, target: target, targetFrame: targetFrame, columns: columns)
        guard delta != 0 else { return }
        uiState.panes.move(kind, by: delta, minutesEnabled: uiState.minutesEnabled)
    }
}
