import SwiftUI
import AppKit
import MyParrotCore

@main
struct MyParrotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var controller = RecordingController()
    // UI-25: 三態視窗模式(標準／窄版／迷你)單一真相,取代原本的 miniMode 布林。
    @State private var windowMode = WindowModeManager()
    // UPD:掛在 Group 而非 RootView——模式切換不會取消/重跑這個 3 秒延遲檢查。
    @State private var updates = UpdateChecker()
    // UI-24: 選單命令(在 view 樹外)與 RootView 都要讀寫的狀態(設定 sheet、
    // 逐字稿範圍、列表收折)——集中成一個 @Observable 匯流排注入 environment,
    // 不用 NotificationCenter 亂飛(Eric 明確指定的作法)。
    @State private var uiState = AppUIState()

    var body: some Scene {
        WindowGroup("MyParrot") {
            Group {
                if windowMode.mode == .mini {
                    MiniView(controller: controller, windowMode: windowMode)
                } else {
                    RootView(controller: controller, updates: updates,
                              uiState: uiState, windowMode: windowMode)
                }
            }
            // UI-20: 視窗最小尺寸的**單一真相**(RootView 不再自帶 frame——雙重約束
            // 取大者,曾讓 RootView 的 320 被這裡的舊 720 蓋掉而失效)。
            // UI-34(Eric 2026-08-24 09:05):320 → 380——狀態列「待錄音 00:00:00」+
            // 模式/設定兩鈕單列所需寬度(真機二分實測臨界 370,+10 安全邊際);
            // 最小寬度保證不觸發 ViewThatFits 兩列退版(退版程式保留,當非中文
            // 語系狀態字較寬時的保險)。
            // UI-21 v4: minHeight 620——逐字稿/列表間改 VSplitView 可拖曳分隔後,
            // 內容下限=控制卡+逐字稿 pane min 140+列表 pane min 88+adBar;620 保證
            // footer 兩行完整、其餘比例使用者自己拖(不再硬寫死列表高度)。
            // UI-25: 窄版(compact)沿用同一組 380/620——WindowModeManager 把窄版
            // 釘死在這個下限上,兩者本就該是同一個數字,不新增第三組。
            // #2438 M4:逐字稿移到直欄後左欄只剩遙控器＋橫幅＋檔案列表,M3 的 760 過渡收回 620(plan §3.4)。
            // #2438 UI-47(Eric 2026-10-19 23:40):標準模式的最小寬度要把開著的欄算進去(每欄 320＋間距 10),
            // 否則視窗縮到比內容窄,hosting view 把過寬的內容置中、兩邊被裁掉。窄版／迷你照舊。
            .frame(minWidth: windowMode.mode == .mini ? 300 : WorkspaceView.minimumWindowWidth(uiState, mode: windowMode.mode),
                   minHeight: windowMode.mode == .mini ? 60 : 620)
            // MAS-17(2.5.14):錄音中 Dock badge「REC」＋選單列狀態項,四種視窗模式(含關窗)都看得到。
            .onChange(of: controller.state, initial: true) { _, new in RecordingIndicator.update(state: new) }
            .onAppear {
                appDelegate.controller = controller
                appDelegate.uiState = uiState
                // MAS-06／07:啟動後重探一次書籤(stale 重存),沒有可用的錄音夾就跳選擇提示;先處理啟動前就送到的 open 事件
                //(`open -a MyParrot <資料夾>`／拖到圖示),有給資料夾就不用問。
                appDelegate.flushPendingOpenURLs()
                controller.revalidateRecordingsFolder()
                if controller.needsRecordingsFolder { uiState.showFolderPrompt = true }
                // #949:標記數進 state.json(GUI 當 owner 時 CLI `status` 看得到)。
                uiState.onMarkersChanged = { [controller] n in controller.markerCount = n }
                // #949 REC-36:CLI 送來的 `mark` 指令(Core 沒有標記方法)走 App 的 ⌘⇧M 同一條路。
                controller.onExternalCommand = { [uiState, controller] cmd in
                    if cmd.cmd == "mark" { uiState.addMarker(at: controller.elapsed) }
                }
                // #2438 M5:筆記／會議記錄 session(草稿、sidecar、自動存檔)。
                if uiState.notes == nil { uiState.notes = NotesSession(recordingsDir: controller.recordingsDir) }
                // #2407:會議提醒(排程器＋通知)接線;總開關預設關,關著時什麼都不做、零權限請求。
                ReminderWiring.install(controller: controller)
                // #949 REC-35:監看 ~/.config/myparrot 與錄音資料夾(CLI 在錄 ⇒ 橫幅;別的進程發布成品 ⇒ 列表自己出現)。
                // C2(Eric 16:36):協定檔搬進 <錄音夾>/.myparrot ⇒ 商店版也監看(沙盒看得到自己選的夾);沒選夾時先看佔位夾,選完 setDirectories 跟著換。
                controller.startExternalWatch()
                // UI-25: 啟動套一次自存模式/frame,之後不再干預使用者拖拉/並排。
                windowMode.applyInitialFrame()
                #if DEBUG
                // #2412:只有 DEBUG 建置才裝控制通道(驗證腳本用;release 連這行都不編)。
                DebugControl.install(controller: controller, updates: updates, uiState: uiState, windowMode: windowMode)
                #endif
            }
            #if !MYPARROT_MAS
            // UPD:啟動 3 秒後背景查一次更新(避開啟動關鍵路徑/權限請求),失敗靜默。MAS-14:商店版不編。
            .task { try? await Task.sleep(for: .seconds(3)); await updates.autoCheckAtLaunch() }
            #endif
        }
        .windowResizability(.contentSize)
        // UI-21: 移除 hiddenTitleBar(它把內容拉進標題列、與工具列疊字=Eric 回報的
        // header overlap)。改用原生標題列(內容乾淨落在其下),迷你/設定兩鈕移進內容
        // 首列的 statusCard(見 RootView),不再靠 macOS 工具列(窄視窗會收「»」)。
        .commands {
            // UPD:App menu 加「檢查更新…」(macOS 慣例位置),無視 enabled/skip。
            CommandGroup(after: .appInfo) {
                Button(L("檢查更新…")) { Task { await updates.checkNow() } }
            }
            // UI-24:App menu「設定… ⌘,」+ CommandMenu「錄音」「顯示方式」。
            AppCommands(controller: controller, uiState: uiState, windowMode: windowMode)
        }
    }
}

/// UI-24: cross-cutting UI state the `.commands` menu (outside the view
/// hierarchy) and RootView both need to read/write. Centralizing this here
/// (instead of NotificationCenter, instead of duplicating @State in both
/// places) is what lets a menu click or ⌘L/⌘K actually move RootView's UI.
@MainActor
@Observable
final class AppUIState {
    var showSettings = false
    /// MAS-06／07:商店版「選擇錄音資料夾」提示框(RootView 的 alert;DebugControl `folder-prompt` 也能叫出／收掉)。
    var showFolderPrompt = false
    /// MAS-31:首啟模型下載卡片(RootView 的 alert;選完錄音夾之後、沒裝模型時跳一次)。
    var showOnboarding = false
    /// UI-57:首次啟動模型功能說明框(RootView 的 alert;DebugControl `model-hint show` 也能叫出來)。
    var showModelHint = false
    /// 設定頁打開後要捲到的區段 id(`SettingsView.modelSectionID`);SettingsView 捲完清回 nil。
    var settingsScrollTo: String? = nil

    /// UI-57 說明框的兩顆鈕(RootView 的 alert 與 DebugControl `model-hint open|later` 共用同一條路)。
    func modelHintOpenSettings() {
        ModelHint.markShown()
        showModelHint = false
        settingsScrollTo = SettingsView.modelSectionID
        showSettings = true
    }
    func modelHintLater() {
        ModelHint.markShown()
        showModelHint = false
    }
    var fullTranscript = false
    /// UI-60:選中的校正建議 id(點建議列或 DebugControl `correction focus`);TranscriptPane 觀察它捲到對應段並高亮。
    var focusedSuggestionID: String?
    /// 逐字稿捲動區的 [offset, contentHeight, containerHeight](TranscriptPane 的 onScrollGeometryChange 寫;只給 DebugControl 讀,不驅動畫面)。
    @ObservationIgnored var transcriptScroll: [Double] = []
    /// DebugControl `transcript scroll bottom|<index>`(帶時間戳讓同一指令可重送);TranscriptPane 的 onChange 執行。
    var transcriptScrollRequest: String?
    /// #2438 M4 面板工作區(UI-45/46):哪些直欄開著、順序、控制欄停靠邊、欄寬、檔案列表展開。
    /// 偏好只有 `panes.standard` 一把 JSON(plan §4);每次變動寫回。窄版不另存:`open` 在窄版
    /// 執行期視為空(`WorkspaceView` 依模式過濾),不寫回。
    var panes: PaneState {
        didSet { if panes != oldValue { PanesStore.save(panes) } }
    }
    /// 既有呼叫點(⌘K、檔案面板標題 chip)不動:轉接到 `panes.filesExpanded`。
    var listExpanded: Bool {
        get { panes.filesExpanded }
        set { panes.filesExpanded = newValue }
    }
    /// B2:會議記錄後端 ≠ off 才有會議記錄圖示與欄。偏好(含 argument domain)變動時重讀。
    private(set) var minutesEnabled: Bool
    /// 拖曳中的內容(`"remote"` 或 `PaneKind.rawValue`),onDrag 開始時設;只給插入指示線預判用,
    /// 放下時仍以拖曳資料本身為準(外部 App 拖進來的字不會被當成面板)。
    @ObservationIgnored var dragPayload: String?
    /// 畫面上各內容欄實際渲染的寬(DebugControl `panes` 回報用;WorkspaceView 的 onGeometryChange 寫)。
    @ObservationIgnored var renderedColumnWidths: [PaneKind: CGFloat] = [:]
    /// #2438 標記 ⌘⇧M(錄音經過秒數)。M5 筆記面板接上後寫成 `⚑ h:mm:ss ` 行;之前只累計、遙控器鍵上顯示顆數。
    var markers: [TimeInterval] = [] { didSet { onMarkersChanged?(markers.count) } }
    /// #949:標記數同步給 controller(寫進 state.json 給 CLI `status` 看)。
    @ObservationIgnored var onMarkersChanged: ((Int) -> Void)?
    /// #2438 M5:筆記／會議記錄 session(草稿、sidecar、自動存檔);啟動後由 MyParrotApp 注入。
    var notes: NotesSession?
    /// 檔案面板選中的那筆(點列 ⇒ 三欄切到那場;UI-52)。
    var selectedRecording: UUID?
    /// 檔案面板搜尋字串(DebugControl `files search` 也寫它)。
    var filesQuery = ""
    /// #2438 M6(MDL-03):設定頁「模型」區段的選擇流程(隱私確認框掛起中的那筆);DebugControl `model request` 共用。
    let modelFlow = ModelSelectionFlow()
    /// 標記 ⌘⇧M:有筆記 session 就直接寫進筆記(游標處或文末)並確保筆記欄開著;顆數照累計給遙控器鍵顯示。
    func addMarker(at elapsed: TimeInterval) {
        markers.append(elapsed)
        guard let n = notes else { return }
        n.insertMarker(elapsed: elapsed)
        if !panes.open.contains(.notes) { panes.toggle(.notes) }
    }

    @ObservationIgnored private var defaultsObserver: NSObjectProtocol?

    init() {
        panes = PanesStore.load()
        minutesEnabled = ModelBackendRegistry.isEnabled(.minutes)
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshMinutesEnabled() }
        }
    }

    func refreshMinutesEnabled() {
        let now = ModelBackendRegistry.isEnabled(.minutes)
        if now != minutesEnabled { minutesEnabled = now }
        notes?.minutes.refreshProvider()
    }
}

/// #2438 M4:`panes.standard` 偏好(整份 `PaneState` 的 JSON 字串)。壞 JSON ⇒ 回 `PaneState.standard`
/// 並印一行;鍵不存在 ⇒ 標準預設,舊 `listExpanded` 鍵有值就讀一次搬進 `filesExpanded` 並立刻寫成新鍵
/// (舊鍵保留不刪,plan §4)。
enum PanesStore {
    static let key = "panes.standard"
    static let legacyListExpandedKey = "listExpanded"

    static func load(_ defaults: UserDefaults = .standard) -> PaneState {
        if let raw = defaults.object(forKey: key) {
            let data = (raw as? String).map { Data($0.utf8) } ?? (raw as? Data)
            if let data, let state = try? JSONDecoder().decode(PaneState.self, from: data) { return state }
            print("[PANES] \(key) 偏好解不開(\(type(of: raw))),改用標準預設")
            return .standard
        }
        var state = PaneState.standard
        if defaults.object(forKey: legacyListExpandedKey) != nil {
            state.filesExpanded = defaults.bool(forKey: legacyListExpandedKey)
            save(state, defaults)
        }
        return state
    }

    static func save(_ state: PaneState, _ defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(state), let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: key)
    }
}

/// UI-24: the「錄音」/「顯示方式」menus + the App-menu's「設定…」item, and
/// `CommandGroup(replacing: .newItem)` for「新錄音」(so ⌘N stops opening a
/// second WindowGroup window — see WindowModeManager's doc comment on why
/// that made the single-window NSApp.windows lookup safe).
/// Enable/disable rules follow docs/worklogs/2026-08-23-shortcuts/plan.md
/// 定稿:設定 sheet 開啟時停用 ⌘R/⌘N,錄音中的 ⌘P/⌘E 仍可用。2026-08-23 二審後
/// 追加:⌘1(切換模式)也一併停用——定稿原文沒提到這顆,但雙審都指出它會繞過
/// sheet 的視窗保護(見「切換模式」按鈕旁註解),不停用會有真實副作用,不是
/// 單純「跟規格不一致」可以放著不管的落差。
struct AppCommands: Commands {
    var controller: RecordingController
    var uiState: AppUIState
    var windowMode: WindowModeManager
    /// 筆記編輯器是不是 first responder(⌘K 的二義:連結 vs 最近錄音)。
    private var notesFocused: Bool { uiState.notes?.proxy.isFocused ?? false }

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button(L("新錄音")) { controller.newRecording() }
                .keyboardShortcut("n", modifiers: .command)
                .disabled(controller.state != .finished || uiState.showSettings)
        }
        CommandGroup(replacing: .appSettings) {
            Button(L("設定…")) { uiState.showSettings = true }
                .keyboardShortcut(",", modifiers: .command)
        }
        CommandMenu(L("錄音")) {
            Button(L("開始錄音")) { RecordingConsent.confirmThen { controller.startRecording() } }   // MAS-17
                .keyboardShortcut("r", modifiers: .command)
                // #949:CLI 在錄(別的進程持有租約)⇒ 停用(按了也只會拿到「已有錄音進行中」)。
                .disabled(!(controller.state == .idle || controller.state == .finished) || uiState.showSettings
                          || controller.externalRecording != nil)
            // 二審 Finding 3(HIG):選單原本固定印「暫停／繼續」,跟 ControlBar
            // 按鈕/help() 的動態文字對不上——仿照下面「收折/展開最近錄音」的寫法,
            // 依狀態即時換字。
            Button(controller.state == .paused ? L("繼續") : L("暫停")) {
                if controller.state == .recording { controller.pause() }
                else if controller.state == .paused { controller.resume() }
            }
            .keyboardShortcut("p", modifiers: .command)
            .disabled(!(controller.state == .recording || controller.state == .paused))
            Button(L("結束錄音")) { controller.stop() }
                .keyboardShortcut("e", modifiers: .command)
                .disabled(!(controller.state == .recording || controller.state == .paused))
            // #2438 I1:標記 ⌘⇧M(⌘M 是系統「縮到 Dock」)。
            Button(L("標記")) { uiState.addMarker(at: controller.elapsed) }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!(controller.state == .recording || controller.state == .paused))
            Divider()
            Button(L("轉逐字稿")) {
                if let last = controller.recordings.first { controller.transcribe(last) }
            }
            .keyboardShortcut("t", modifiers: .command)
            .disabled(controller.recordings.isEmpty || controller.state == .recording)
            Button(L("在 Finder 打開")) {
                NSWorkspace.shared.activateFileViewerSelecting([controller.recordingsDir])
            }
            .keyboardShortcut("o", modifiers: .command)
            Divider()
            // UI-27(v2 定稿):「從頭播放」次要動作——無 ⌘ 快捷鍵(Phase 2 再議),
            // 只在有使用中的播放器時啟用。
            Button(L("從頭播放")) { controller.restartPlayback() }
                .disabled(controller.playingURL == nil)
        }
        // #2438 I1:筆記選單——⌘B／⌘I／⌘K／⌘⇧L 只在筆記編輯器有焦點時可用;⌘K 否則給「最近錄音」。
        CommandMenu(L("筆記")) {
            Button(L("粗體")) { uiState.notes?.proxy.apply { MarkdownEditing.wrap($0, selection: $1, with: "**") } }
                .keyboardShortcut("b", modifiers: .command)
                .disabled(!notesFocused)
            Button(L("斜體")) { uiState.notes?.proxy.apply { MarkdownEditing.wrap($0, selection: $1, with: "*") } }
                .keyboardShortcut("i", modifiers: .command)
                .disabled(!notesFocused)
            Button(L("連結")) { uiState.notes?.insertLinkFromClipboard() }
                .keyboardShortcut("k", modifiers: .command)
                .disabled(!notesFocused)
            Button(L("勾選框")) { uiState.notes?.proxy.apply { MarkdownEditing.toggleCheckbox($0, selection: $1) } }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(!notesFocused)
        }
        CommandMenu(L("會議記錄")) {
            Button(L("立即更新")) { if let n = uiState.notes { Task { await n.updateMinutesNow(controller: controller) } } }
                .keyboardShortcut("u", modifiers: [.command, .shift])
                .disabled(!uiState.minutesEnabled || uiState.notes == nil || controller.state == .idle)
            Button(L("複製 Markdown")) { uiState.notes?.copyMinutesMarkdown() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(uiState.notes?.minutes.document == nil)
        }
        CommandMenu(L("逐字稿翻譯")) {   // #2612 TRL-07
            Button(L("立即翻譯")) { uiState.notes?.translation.translateNow() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(!(uiState.notes?.translation.isEnabled ?? false))
            Button(L("翻譯整份")) { if let n = uiState.notes { n.translateWholeNow(controller: controller) } }
                .disabled(!(uiState.notes?.translation.isEnabled ?? false) || controller.liveTranscript.isEmpty)
        }
        CommandMenu(L("顯示方式")) {
            // 兩份二審都點出:這顆按鈕原本沒有 .disabled(uiState.showSettings),
            // 而 App-level .commands 不像 RootView 本地按鈕那樣天生被 sheet 擋掉
            // key window(見 notes.md 決策 3)——設定 sheet 開著時按 ⌘1 仍會呼叫
            // cycle(),輕則把 setFrame() 套到錯的視窗、重則讓 sheet 的 owner view
            // (RootView)被 mini 模式整個拔掉。跟 ⌘R/⌘N 用同一套規則擋掉。
            Button(L("切換模式")) { windowMode.cycle() }
                .keyboardShortcut("1", modifiers: .command)
                .disabled(uiState.showSettings)
            Divider()
            // #2438 I1:⌘2／⌘3／⌘4 開關直欄(勾號＝開著);只在標準模式可用(窄版只剩左欄、迷你沒有欄),
            // 設定 sheet 開著時跟 ⌘1 一樣停用(開關欄會改主視窗 frame)。會議記錄後端 off ⇒ 停用(B2)。
            paneToggle(.transcript, L("逐字稿"), key: "2")
            paneToggle(.notes, L("筆記"), key: "3")
            paneToggle(.minutes, L("會議記錄"), key: "4")
                .disabled(!panesEditable || !uiState.minutesEnabled)
            Divider()
            // K1:控制欄只停左右;無快捷鍵。
            dockToggle(.left, L("控制欄靠左"))
            dockToggle(.right, L("控制欄靠右"))
            Divider()
            Button(L("逐字稿 3 分鐘／完整")) { uiState.fullTranscript.toggle() }
                .keyboardShortcut("l", modifiers: .command)
            Button(uiState.panes.filesExpanded ? L("收折最近錄音") : L("展開最近錄音")) {
                uiState.panes.filesExpanded.toggle()
            }
            .keyboardShortcut("k", modifiers: .command)
            .disabled(windowMode.mode == .mini || notesFocused)   // 筆記有焦點時 ⌘K＝連結
        }
    }
}

extension AppCommands {
    /// 直欄開關/停靠只在標準模式、且設定 sheet 沒開時可用。
    private var panesEditable: Bool { windowMode.mode == .standard && !uiState.showSettings }

    /// 勾號＝畫面上真的有這一欄(窄版／迷你、會議記錄後端 off 都不勾;偏好裡的 open 照留)。
    private func paneToggle(_ kind: PaneKind, _ title: String, key: Character) -> some View {
        Toggle(title, isOn: Binding(
            get: { windowMode.mode == .standard && uiState.panes.open.contains(kind)
                   && (kind != .minutes || uiState.minutesEnabled) },
            set: { _ in uiState.panes.toggle(kind) }))
            .keyboardShortcut(KeyEquivalent(key), modifiers: .command)
            .disabled(!panesEditable)
    }

    private func dockToggle(_ side: RemoteSide, _ title: String) -> some View {
        Toggle(title, isOn: Binding(
            get: { uiState.panes.remoteSide == side },
            set: { _ in uiState.panes.dock(side) }))
            .disabled(!panesEditable)
    }
}

/// Intercepts quit while a recording is in progress so it isn't lost. Default
/// action keeps recording; choosing to quit stops & saves first (the CAF is
/// finalized synchronously in stop(); m4a conversion resumes on next launch).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: RecordingController?
    var uiState: AppUIState?
    /// MAS-06b:controller 還沒接上前就送到的 open 事件(Launch Services 可能在第一個 view 出現前就送)。
    private var pendingOpenURLs: [URL] = []

    /// 資料夾拖到 Dock 圖示／Finder「打開檔案的應用程式」／`open -a MyParrot <資料夾>` ⇒ 當作選錄音夾(兩版共用;
    /// 沙盒版由 Launch Services 給該資料夾的 scope,`setRecordingsDir` 存成書籤)。只收資料夾,其他 URL 忽略。
    func application(_ application: NSApplication, open urls: [URL]) {
        guard controller != nil else { pendingOpenURLs.append(contentsOf: urls); return }
        applyOpenURLs(urls)
    }
    func flushPendingOpenURLs() {
        let urls = pendingOpenURLs; pendingOpenURLs = []
        applyOpenURLs(urls)
    }
    private func applyOpenURLs(_ urls: [URL]) {
        guard let c = controller else { return }
        for u in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else { continue }
            c.setRecordingsDir(u)
            uiState?.showFolderPrompt = false
            break
        }
    }

    /// BUG-27 補強(codex 獨立測試發現):terminateLater pending 期間再收到終止請求
    /// (連按 ⌘Q)若再開一個 unload Task,會對同一 termination 流程 reply 兩次。
    /// 已有流程在收尾(≤5s)時直接取消重複請求,第一個流程照常完成退出。
    private var quitInFlight = false

    /// #2438 R1:打包字型(Share Tech Mono)在第一個 view 建立前註冊。
    func applicationWillFinishLaunching(_ notification: Notification) {
        FontRegistrar.registerBundledFonts()
        AppearanceMode.applyStored()   // UI-56:外觀偏好在第一個視窗建立前套回(跟隨系統＝nil)
        AppleFMAvailability.shared.refresh()   // AFM-01:啟動先探一次系統支不支援(macOS < 26 不碰框架)
    }

    /// AFM-01:使用者可能剛去系統設定開 Apple Intelligence 或改 Siri 語言回來 ⇒ 回前景再探一次。
    func applicationDidBecomeActive(_ notification: Notification) {
        AppleFMAvailability.shared.refresh()
        // MAS-07:回前景重探書籤(資料夾在背景被搬走／刪掉／權限撤回 ⇒ 按錄音前就提示)。GitHub 版 no-op。
        if let c = controller {
            c.revalidateRecordingsFolder()
            if c.needsRecordingsFolder, uiState?.showSettings != true { uiState?.showFolderPrompt = true }
        }
    }

    /// #949 REC-39(B1):`-backgroundStart` 啟動參數 ⇒ 不開主視窗(第二段 CLI 拉起 GUI 用;第一段只做參數與不開窗)。
    /// Dock 圖示照常(activation policy 維持 .regular),只是不把視窗叫到前面:WindowGroup 的第一個視窗建好後
    /// orderOut;SwiftUI 可能在這一輪之後才建窗 ⇒ 下一輪 run loop 再收一次。controller/監看照常在跑。
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard BackgroundStart.requested else { return }
        NSApp.setActivationPolicy(.regular)
        BackgroundStart.hideWindows()
        DispatchQueue.main.async { BackgroundStart.hideWindows() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { BackgroundStart.hideWindows() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if quitInFlight { return .terminateCancel }
        uiState?.notes?.flushAll()   // #2438 NOTE-02:退出前把筆記寫下去(原子寫)
        guard let c = controller else { return .terminateNow }
        if c.state == .recording || c.state == .paused {
            let alert = NSAlert()
            alert.messageText = L("錄音還在進行中")
            alert.informativeText = L("要先結束並儲存這段錄音,還是繼續錄音?")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("繼續錄音"))    // first button = default (Return)
            alert.addButton(withTitle: L("結束錄音並離開"))
            if alert.runModal() == .alertFirstButtonReturn {
                return .terminateCancel                  // 繼續錄音
            }
            c.stop()                                     // 存檔後離開
        }
        // QUIT-12(#1697,Eric 2026-09-18):轉稿中不默默中斷——先問。預設鈕=繼續轉稿,
        // 所以誤按 ⌘Q 或直接敲 Return 都是「不要中斷」。
        if RecordingController.shouldConfirmQuitDuringTranscription(
                isTranscribing: c.isTranscribing, queuedCount: c.transcribeQueued.count) {
            let alert = NSAlert()
            alert.messageText = L("逐字稿還在轉檔中")
            alert.informativeText = L("現在離開會中斷這次轉稿(沒有續傳,下次要整段重轉)。錄音檔會留著。")
            alert.alertStyle = .warning
            alert.addButton(withTitle: L("繼續轉稿"))        // 預設鈕
            alert.addButton(withTitle: L("中斷並離開"))
            if alert.runModal() == .alertFirstButtonReturn {
                return .terminateCancel
            }
            c.markTranscriptionsInterrupted()                // QUIT-13:標「上次未完成」
        }
        // BUG-27/QUIT-06(#1078)+ 殘留(#1697):whisper context 還載著就走 exit() 會在
        // ggml 的 Metal device 全域析構撞 assert 崩潰。先叫停推理再卸載
        // (unloadWhisperForQuit 會先 requestAbort,2 秒上限);**沒卸乾淨就不能照常
        // exit()**——改用 _exit() 跳過靜態解構,這是唯一保證不 abort 的路。
        quitInFlight = true
        Task { @MainActor in
            let clean = await c.unloadWhisperForQuit()
            c.releaseRecordingsFolderAccess()   // MAS-29:security scope start／stop 配對
            if clean {
                sender.reply(toApplicationShouldTerminate: true)
            } else {
                UserDefaults.standard.synchronize()   // 跳過收尾前自己把偏好寫下去
                _exit(0)
            }
        }
        return .terminateLater
    }
}

/// #949 REC-39:`-backgroundStart` 參數(CommandLine.arguments 有這個旗標即成立;不寫偏好)。
@MainActor
enum BackgroundStart {
    static let flag = "-backgroundStart"
    static var requested: Bool { CommandLine.arguments.contains(flag) }

    /// 把目前可見的視窗收起來(orderOut:視窗物件還在、只是不顯示;使用者點 Dock 圖示會再叫出來)。
    static func hideWindows() {
        for w in NSApp.windows where w.isVisible && w.canBecomeMain { w.orderOut(nil) }
    }
}

// Shared formatting + palette.
enum MP {
    // UI-22 Phase C: 品牌色深色模式提高明度/飽和度(淺色底下的飽和色到深色底
    // 會顯髒灰);用 NSColor dynamicProvider 讓同一個 Color 依系統外觀自動切換,
    // 不用 xcassets(SwiftPM 加 resources 要動 Package.swift,越界)。
    private static func dynamicColor(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1.0)
        }))
    }

    static let blue = dynamicColor(light: (0.216, 0.541, 0.867), dark: (0.32, 0.62, 0.93))   // 你 / brand
    static let coral = dynamicColor(light: (0.847, 0.353, 0.188), dark: (0.91, 0.45, 0.30))  // 對方
    static let recRed = dynamicColor(light: (0.639, 0.176, 0.176), dark: (0.85, 0.32, 0.32))

    // Stronger, clearly-visible lines (the faint 0.5px ones were hard to read).
    static let line = Color.primary.opacity(0.22)
    static let strongLine = Color.primary.opacity(0.32)
    static func card(_ scheme: ColorScheme) -> Color { Color.primary.opacity(0.04) }

    // #2438 淺色面板底色(Eric 2026-10-19 23:39「淺色模式面板不是應該一起變成淺的?」):mockup 的規格是
    // 視窗底 --win(淺 #f3f3f1／深 #262826)＋卡片 --card(淺＝白 72%、深＝白 6%)＋內凹 --inset(淺＝黑 4%、深＝白 5%)。
    // 原本卡片用 Color.primary.opacity(0.03)(淺＝黑 3%)⇒ 白底上灰卡,跟 mockup 的「灰底上白卡」顛倒。
    private static func dynamicAlpha(light: (UInt32, Double), dark: (UInt32, Double)) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let (v, a) = isDark ? dark : light
            return NSColor(red: CGFloat((v >> 16) & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                           blue: CGFloat(v & 0xFF) / 255, alpha: a)
        }))
    }
    /// 標準／窄版視窗內容的底(mockup --win)。
    static let floor = dynamicAlpha(light: (0xF3F3F1, 1), dark: (0x262826, 1))
    /// 直欄、檔案面板的卡片底(mockup --card)。
    static let paneCard = dynamicAlpha(light: (0xFFFFFF, 0.72), dark: (0xFFFFFF, 0.06))
    /// 卡片內的內凹底(mockup --inset)。
    static let inset = dynamicAlpha(light: (0x000000, 0.04), dark: (0xFFFFFF, 0.05))

    // UI-22:8pt 網格間距 tokens——外層/卡內/row 各處各寫一個數字改成這 4 階,
    // 0-12 之間的雜數(1/2/3/6/9/10/11)就近併過來(平手取大)。
    static let spXS: CGFloat = 4
    static let spS: CGFloat = 8
    static let spM: CGFloat = 12
    static let spL: CGFloat = 16

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

/// UI-22:字級 tokens——5 階就近映射全 UI 既有的字級數字寫法
/// (9/10/11→caption;12→label;13/14→body;15/16→title;20→display),
/// 收斂成統一字級語言而非各處各寫一個 size/weight。icon-only 鈕(pip/gear)
/// 的 14pt 是視覺尺寸不是文字,刻意不收斂,見 RootView 該處註解。
enum MPFont {
    static let display = Font.system(size: 18, weight: .semibold, design: .monospaced) // 計時器(20→18 拉近級距)
    static let title   = Font.system(size: 15, weight: .semibold)   // 卡片/Sheet 標題
    static let body    = Font.system(size: 13)                      // 內文/按鈕
    static let label   = Font.system(size: 12, weight: .medium)     // 狀態/列表標題輔助
    static let caption = Font.system(size: 11)                      // 副標/meta
    /// #2438 R1:儀表板計時字型(圓盤、迷你模式、播放進度);打包字型沒註冊成功就回落 SF Mono。
    @MainActor static func timer(_ size: CGFloat) -> Font {
        FontRegistrar.registered
            ? Font.custom(FontRegistrar.shareTechMono, size: size)
            : Font.system(size: size, weight: .semibold, design: .monospaced)
    }
}

/// Shared mic-picker label: ⚠️ for Bluetooth (avoid), (iPhone) for Continuity.
/// Used by both the Settings picker and the main-screen quick picker so the
/// two never disagree about how a device is marked.
@MainActor func micLabel(_ d: AudioInputDevice) -> String {
    if d.isBluetooth { return "⚠️ \(d.name)" + L("(藍牙)") }
    if d.isContinuity { return "\(d.name)" + L("(iPhone)") }
    return d.name
}
