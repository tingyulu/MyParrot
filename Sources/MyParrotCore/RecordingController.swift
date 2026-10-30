import Foundation
import IOKit.ps
import CoreGraphics
import Observation
import AudioToolbox
import AVFoundation
import Speech
import os

@MainActor
@Observable
public final class RecordingController {

    // State machine: 待錄音 → 錄音中 → 已暫停 → 結束後
    public var state: RecordingState = .idle
    public var elapsed: TimeInterval = 0

    // Live meters (0...1): 對方 (left) and 你 (right)
    public var otherLevel: Float = 0
    public var youLevel: Float = 0

    public var currentTitle: String = ""
    /// BUG-28(#1680):錄音中的警示改成結構化,GUI 依介面語言組字。
    public var warning: RecordingWarning?
    /// 繁中整句(=結構化之前寫死的字串,逐字相同)。CLI / state.json / 終端電平表
    /// 讀這個,所以 CLI 端零修改;GUI 走 `warning` 自己翻。
    public var deviceChangeWarning: String? { warning?.zhTW }

    public var recordings: [Recording] = []
    public var liveTranscript: [TranscriptLine] = []
    public var isTranscribing = false
    /// #2483 C:重轉完成(整份換掉 `liveTranscript`)就 +1;App 層靠它把會議記錄帳目重設。
    public private(set) var transcriptVersion = 0
    /// #2483 C:這個進程在停止時用即時稿寫過 sidecar 的 stem;之後重轉前會把那份 `.srt` 另存 `.live.srt`。
    private var liveSidecarStems: Set<URL> = []
    public var lastError: String?

    // Settings
    public var micPermission = false
    public var speechPermission = false
    public var inputGain: Float = 1.0 { didSet { mic.gain = inputGain; monitor.gain = inputGain; defaults.set(inputGain, forKey: "inputGain") } }
    /// Software echo cleanup (offline, post-recording). Cancels 對方 speaker echo
    /// bled into 你 when recording on speakers. Pure DSP — does NOT touch macOS
    /// voice processing, so it never ducks system audio. Off by default.
    public var aecEnabled = false { didSet { defaults.set(aecEnabled, forKey: "aecSoftware") } }
    public var selectedInputDevice: AudioInputDevice?
    public var availableInputDevices: [AudioInputDevice] = []
    public var engine: TranscriptionEngine = .appleNative {
        didSet {
            guard oldValue != engine else { return }
            defaults.set(engine.rawValue, forKey: "engine")
            if state == .recording || state == .paused {
                needsEngineRebuild = true
                warning = .engineChangeDeferred
            } else {
                rebuildTranscribers()
            }
        }
    }
    /// Phase C(TR-19):錄音轉檔完成後自動用高精度引擎重轉——live 稿=會中參考,
    /// 檔案稿=記錄真相。預設開;Whisper 模型未安裝時自動略過。
    /// #2483 E:結束後高精度重轉的時機(立刻／閒置時／不重轉);舊布林 `autoTranscribe` 由 `TranscribePolicy.migrate` 吃進來。
    public var transcribePolicy: TranscribePolicy = .whenIdle {
        didSet { defaults.set(transcribePolicy.rawValue, forKey: TranscribePolicy.key) }
    }
    /// 相容舊呼叫端(CLI、設定頁條件):true＝會重轉(立刻或閒置時),設 false＝不重轉、設 true＝閒置時。
    public var autoTranscribeAfterStop: Bool {
        get { transcribePolicy != .never }
        set { transcribePolicy = newValue ? .whenIdle : .never }
    }
    /// #2483 E(TRX-07):等機器閒置再高精度重轉的那幾筆。
    public private(set) var pendingHighAccuracy: Set<UUID> = []
    private var idleTranscribeTimer: Timer?
    public var liveTranscribeEnabled = true
    public var language: TranscriptionLanguage = .system { didSet { defaults.set(language.rawValue, forKey: "language") } }
    public var resolvedLocale: Locale { language.resolved() }

    // Playback (錄音檔列表)
    public var playingURL: URL?
    // UI-27/28 (2026-08-23): 播放進度 + 列內即時雙聲道電平。
    /// 播放器狀態:`playing`/`paused`/`ended`(播完 → UI 顯示 ↻ 重播,3 秒後收回)。
    public enum PlaybackPhase: Sendable { case playing, paused, ended }
    public var playbackPhase: PlaybackPhase = .playing
    public var playbackTime: TimeInterval = 0
    public var playbackDuration: TimeInterval = 0
    /// 檔案左(對方)/右(你)聲道即時電平,標度同錄音 rmsLevel(線性 ×4, 0…1)。
    public var playbackOtherLevel: Float = 0
    public var playbackYouLevel: Float = 0
    // UI-28b:波形縮圖快取(同 session 重播不重算);失敗/逾時的 URL 記在 waveformFailed,
    // UI 停在純進度列並標「波形不可用」,不重試、不報錯框(設計稿 v2 降級條款)。
    public private(set) var waveforms: [URL: Waveform] = [:]
    public private(set) var waveformFailed: Set<URL> = []
    private var waveformInFlight: Set<URL> = []

    // Live mic monitor (設定裡即時收音測試)
    public var isMonitoring = false
    public var monitorLevel: Float = 0

    private let system = SystemAudioCapture()
    // `var` so the live mic engine can be swapped mid-recording (hot-swap, AUD-20).
    private var mic = MicCapture()
    // `var`(AUD-38 F6):每次開麥克風測試都建新實例,不在 tap 可能還在跑時改寫舊實例的 closure。
    private var monitor = MicCapture()
    private let recorder = StereoRecorder()
    // `var`:引擎可依設定切換(TR-14),rebuildTranscribers() 重建。
    private var fileTranscriber: any TranscriptionProvider
    private var live: any LiveTranscribing
    /// live+file 共用的 whisper context(單一模型載入一份)。
    private var whisperEngine: WhisperCppEngine?

    private var player: AVAudioPlayer?
    private var playbackTicker: Timer?
    /// 檔案 URL → 穩定的 Recording.id(跨 loadRecordings 重掃不變)。
    private var recordingIDs: [URL: UUID] = [:]
    private var startDate = Date()
    private var accumulated: TimeInterval = 0
    private var ticker: Timer?
    var currentURL: URL?
    /// 目前這段錄音(停止後:剛發布)的**頂層**檔名——CLI 回報路徑、筆記 sidecar 掛名用(#892 後檔名可能帶後綴,
    /// 不能再用命名規則重算)。#949 起錄音中實際寫的是 `.myparrot/inprogress/<sessionId>/audio.caf`,
    /// 這裡是停止時要發布到的頂層名字;發布成功後換成真正落地的路徑。
    public var currentRecordingURL: URL? { currentURL }

    // MARK: #949 第一段:唯一 writer 租約＋inprogress(邏輯在 RecordingController+Lease.swift)
    /// 這個 controller 開錄時寫進租約/state.json 的身分:GUI＝"gui"(預設)、CLI 開錄前設 "cli"。
    public var leaseOwner: String = "gui"
    var leaseHolder: RecordingLeaseHolder?
    /// 目前(或剛結束)這場的 sessionId(inprogress 目錄名、租約、state.json 共用)。
    public internal(set) var sessionId: String?
    /// 錄音中實際寫的檔:`<recordingsDir>/.myparrot/inprogress/<sessionId>/audio.caf`;發布後清成 nil。
    var inprogressURL: URL?
    /// 最近一次開錄被租約擋下的原因(CLI 組 refused 事件用);開錄成功時清掉。
    public internal(set) var lastLeaseError: LeaseError?
    var lastHeartbeatAt = Date.distantPast
    var ownerTimer: Timer?
    /// 本進程正在轉 m4a 的 caf(loadRecordings 用來分辨「處理中」與「殘檔」)。
    var activeConversions: Set<URL> = []
    /// 這個進程收割端復原過的錄音(CLI `list` 印 `recovered` 事件用)。
    public internal(set) var recoveredRecordings: [RecoveredRecording] = []
    /// 最近一次 `stop()` 真的發布並建立的那一筆(發布失敗＝nil)。CLI 收尾用它找自己的檔,不拿 `recordings.first`。
    public private(set) var lastStoppedRecordingID: UUID?
    /// 這場的標記數(App 層 ⌘⇧M 累計;寫進 state.json 給非 owner 端看)。
    public var markerCount: Int = 0
    /// 外部指令(commands/)裡 Core 沒有對應方法的(`mark`)交給 App 層處理(`AppUIState.addMarker`)。
    public var onExternalCommand: ((RecordingCommand) -> Void)?
    var lastCommandPoll = Date.distantPast
    /// REC-35:別的進程(CLI)正在錄音時的狀態——自己不是 owner 且租約 alive(或舊版 CLI 的 record.pid 活著)才有值。
    /// 規格寫 `public private(set)`;邏輯在 +Lease.swift 的 extension,所以是 internal(set)。
    public internal(set) var externalRecording: ExternalRecording?
    var externalWatcher: ExternalRecordingWatcher?
    /// 錄音資料夾頂層檔名快照(監看事件/保底輪詢時比對,有變才重掃列表)。
    var recordingsDirSignature: [String] = []
    var accumulatedElapsed: TimeInterval { accumulated }
    var segmentStart: Date { startDate }
    private var deviceListenerInstalled = false
    private let defaults = UserDefaults.standard
    // Peak levels seen this recording, to catch a dead channel live.
    private var micPeak: Float = 0
    private var sysPeak: Float = 0
    private var silentMicWarned = false
    /// Below this RMS a channel counts as "no signal". Shared by the live
    /// indicator and the 8-second dead-channel warning so they never disagree.
    private static let silenceThreshold: Float = 0.003
    // MARK: - CAL-08/09/11(#2407):死軌告警與「沒人說話」量尺
    /// G1(Eric 2026-10-17 14:59):起錄後這麼久某軌**從頭到尾**無訊號 → `onDeadTrackAlarm`;3 分鐘(DEBUG 通道可改短驗證)。
    public var deadTrackAlarmAfter: TimeInterval = 180
    /// C2(Eric 2026-10-17 14:25):兩軌連續沒人說話這麼久 → `onSilenceStopSuggested`;30 分鐘,只提醒不自動停。
    public var silenceStopAfter: TimeInterval = 30 * 60 { didSet { silenceRule.after = silenceStopAfter } }
    private var micDeadAlarmed = false
    private var sysDeadAlarmed = false
    /// I1:兩把尺——死軌用 `silenceThreshold`,「沒人說話」用自適應底噪 +12 dB(SpeechActivityEstimator)。
    private var micSpeech = SpeechActivityEstimator()
    private var sysSpeech = SpeechActivityEstimator()
    private var silenceRule = SilenceStopRule()
    private var speechSinceTick = false
    /// 這一場最後一次建議停的時刻(狀態 JSON/測試用);nil＝還沒建議過。
    public private(set) var silenceStopSuggestedAt: Date?
    /// 這一場告警過的死軌(狀態 JSON/測試用)。
    public private(set) var deadTrackAlarms: [RecordingTrack] = []
    /// App 層掛通知:某軌 3 分鐘無訊號。
    public var onDeadTrackAlarm: ((RecordingTrack) -> Void)?
    /// App 層掛通知:30 分鐘沒人說話。
    public var onSilenceStopSuggested: (() -> Void)?
    /// 目前兩軌「有人說話」門檻與底噪(設定頁/狀態 JSON 用)。
    public var speechGauge: (micFloor: Float, micThreshold: Float, sysFloor: Float, sysThreshold: Float) {
        (micSpeech.noiseFloor, micSpeech.speechThreshold, sysSpeech.noiseFloor, sysSpeech.speechThreshold)
    }
    /// AUD-28 / BUG-18 liveness watchdog. While the mic tap is delivering buffers,
    /// `mic.onLevel` fires ~12×/s — even during silence (level ≈ 0). So a *stale*
    /// timestamp means buffers stopped flowing = a dead engine/route, NOT a quiet user.
    /// We then auto-rebuild the mic (the recovery the user otherwise does by hand).
    private var lastMicLevelAt = Date()
    private var micAutoRebuildCount = 0
    private var lastMicRebuildAt = Date.distantPast
    // 門檻(3 秒無 buffer／冷卻 2 秒／連續 3 次／連續流動 10 秒才歸零)只有一份,在 `MicWatchdogPolicy`(AUD-38)。

    // MARK: AUD-38(#2529)切麥／重建非阻塞
    /// 切麥或自動重建進行中:UI 禁用麥克風選單＋小轉圈,看門狗不計時。
    public private(set) var isSwitchingMic = false
    /// 被 MicCapture 震盪鎖住的裝置 uid;換裝置就清掉。非 nil 時看門狗不重建。
    private var micLockedUID: String?
    /// 這一輪你軌 buffer 開始連續流動的時間(看門狗計數歸零用)。
    private var micFlowSince: Date?
    /// 每次切麥／重建／停止錄音遞增;completion 帶回的世代不符就丟掉(連新引擎一起 stop,避免孤兒引擎)。
    private var micSwapGeneration = 0
    /// 麥克風測試(monitor)的世代:stopMicMonitor 之後才回來的 completion 不得把 isMonitoring 設回 true。
    private var monitorGeneration = 0
    /// 沒選裝置(跟系統預設)時被鎖,`micLockedUID` 存這個哨兵值——要非 nil 看門狗才會停手;
    /// 任何真實 uid 都 ≠ 它,所以選到任何裝置或重建落到真實裝置都算「換裝置」而解鎖。
    private static let micLockedDefaultSentinel = "<default>"
    /// 切麥／重建成功後的無聲警告緩衝:這個時間之前不判「你的麥克風沒收到聲音」(切換中也不判)。
    private var micSilenceGraceUntil = Date.distantPast
    /// AUD-38 F5:切麥／重建建出來、completion 還沒回來的實例;停錄時一併 stop,避免晚到的引擎餵進下一場。
    private var inflightMics: [MicCapture] = []
    /// AUD-39:裝置清單背景刷新的世代;較舊的結果回來就丟掉。
    private var refreshGeneration = 0
    /// AUD-39:對方軌 tap 重建進行中(看門狗與輸出裝置 listener 不再觸發);世代丟掉停錄後才回來的結果。
    private var isRebuildingSys = false
    private var sysRebuildGeneration = 0

    // MARK: - TR-27 / #976:Whisper 模型閒置自動釋放
    /// 閒置多久後把 whisper context 還給系統。實測(2026-08-25,GUI release fc5eff4):
    /// 啟動基準 RSS 125MB → 轉一次稿衝到 3.75GB → 完成 +60s 仍 3.69GB,因為
    /// `WhisperCppEngine` 的 context 活到 actor deinit(=app 結束),`unload()` 從來
    /// 沒有呼叫端。釋放後下次用到會由 `ensureLoaded()` 自動重載(turbo ~2-4s),
    /// 所以這是純粹的記憶體↔首次延遲取捨,不影響功能。
    /// 預設 5 分鐘;`whisperIdleUnloadSec` 可覆蓋,**0 = 停用自動釋放**。
    /// Eric 2026-10-20 15:12:「閒置 5 分鐘有點久,先縮到 3 分」(會後重轉完 3.8 GB 多扛太久)。
    nonisolated private static let whisperIdleUnloadDefaultSec: TimeInterval = 180
    private var whisperIdleTimer: Timer?

    /// 閒置逾時秒數:UserDefaults 有設就用(0=停用→nil),否則用預設。純函式,SelfTest 覆蓋。
    /// 負值視同未設定(不讓打錯的值把功能靜默關掉)。
    nonisolated static func resolveWhisperIdleSec(_ raw: Double?) -> TimeInterval? {
        guard let raw else { return whisperIdleUnloadDefaultSec }
        if raw == 0 { return nil }              // 明確停用
        guard raw > 0 else { return whisperIdleUnloadDefaultSec }   // 負值=無效,回預設
        return raw
    }

    /// 現在可不可以釋放 whisper context。純函式,SelfTest 覆蓋。
    /// 三道閘:①正在轉稿 ②佇列還有待轉 ③錄音/暫停中且開著即時逐字稿——
    /// live 與 file 共用**同一份** context(`buildTranscribers` 把同一個 engine 傳給兩者),
    /// 錄音中釋放會讓下一塊即時逐字稿卡在重載。
    /// #2483 E(TRX-08):還有待閒置重轉的筆就不卸(否則閒置時要重載 3.7 GB);其餘照 `canUnloadWhisper`。
    nonisolated static func canUnloadWhisperWithPending(isTranscribing: Bool, queuedCount: Int, state: RecordingState,
                                                        liveTranscribeEnabled: Bool, pendingCount: Int) -> Bool {
        if pendingCount > 0 { return false }
        return canUnloadWhisper(isTranscribing: isTranscribing, queuedCount: queuedCount, state: state,
                                liveTranscribeEnabled: liveTranscribeEnabled)
    }

    nonisolated static func canUnloadWhisper(isTranscribing: Bool, queuedCount: Int,
                                 state: RecordingState, liveTranscribeEnabled: Bool) -> Bool {
        if isTranscribing || queuedCount > 0 { return false }
        if liveTranscribeEnabled && (state == .recording || state == .paused) { return false }
        return true
    }

    // MARK: #2483 E 閒置時高精度重轉

    private func startIdleTranscribeTimer() {
        guard idleTranscribeTimer == nil else { return }
        idleTranscribeTimer = Timer.scheduledTimer(withTimeInterval: IdleTranscribePolicy.checkInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.idleTranscribeTick(force: false) }
        }
    }

    /// 每 30 秒:條件齊(沒在錄、沒在轉、接電、閒置 ≥120 秒)就挑一筆已轉完 m4a 的待轉筆重轉。DEBUG `transcribe-idle force` 走 force。
    public func idleTranscribeTick(force: Bool) {
        if pendingHighAccuracy.isEmpty { idleTranscribeTimer?.invalidate(); idleTranscribeTimer = nil; return }
        let ok = force || IdleTranscribePolicy.shouldRun(state: state, isTranscribing: isTranscribing, onAC: Self.isOnACPower(),
                                                         idleSeconds: Self.secondsSinceLastUserInput(), pendingCount: pendingHighAccuracy.count)
        guard ok else { return }
        guard let rec = recordings.first(where: { pendingHighAccuracy.contains($0.id) && !$0.isConverting && $0.url.pathExtension != "caf" }) else { return }
        pendingHighAccuracy.remove(rec.id)
        transcribe(rec)
    }

    /// 列表右鍵「現在重轉」。
    public func transcribeNow(_ rec: Recording) {
        pendingHighAccuracy.remove(rec.id)
        transcribe(rec)
    }

    public nonisolated static func isOnACPower() -> Bool {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeRetainedValue() as String? else { return true }
        return type == kIOPMACPowerKey
    }

    public nonisolated static func secondsSinceLastUserInput() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    /// 排定閒置釋放(重排會取消前一個)。呼叫點:轉稿結束、錄音停止。
    private func scheduleWhisperUnload() {
        whisperIdleTimer?.invalidate(); whisperIdleTimer = nil
        guard whisperEngine != nil else { return }
        let raw = defaults.object(forKey: "whisperIdleUnloadSec") as? Double
        guard let sec = Self.resolveWhisperIdleSec(raw) else { return }   // 0 = 使用者停用
        whisperIdleTimer = Timer.scheduledTimer(withTimeInterval: sec, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.unloadWhisperIfIdle() }
        }
    }

    /// 取消待釋放(呼叫點:開始轉稿、開始錄音)。
    private func cancelWhisperUnload() {
        whisperIdleTimer?.invalidate(); whisperIdleTimer = nil
    }

    /// BUG-27(#1078):whisper context 還載著時 app 走 `exit()` 的 C++ 全域析構,
    /// ggml 的 Metal device registry 清理會在 `ggml_metal_rsets_free` 撞
    /// GGML_ASSERT → SIGABRT(修前實測:載 context 後 quit 必炸,未載則乾淨;
    /// 8/24-25 那 15 份 ips 全是此款)。退出前顯式 unload 讓 exit 析構走乾淨路。
    /// 轉稿進行中 quit 時 unload 會排在整段轉稿之後——最多等 5 秒,逾時照退
    /// (維持原本會炸的現狀,但不讓使用者退個 app 卡數分鐘)。
    /// ⚠️ race 不可用 TaskGroup:closure 返回前會隱式等所有 child,而「等 whisper
    /// actor 空出」不是取消點、whisper_full 也不檢查取消 ⇒ cancelAll 救不了,
    /// 轉稿中 quit 照樣卡到轉完(codex 獨立測試抓到的第一版錯誤)。改用兩個
    /// unstructured Task 對同一 continuation 賽跑:逾時 Task 不經 whisper actor,
    /// 5 秒必 resume;unload Task 逾時後仍在背景跑完,不被任何人等待。
    /// #1697:先叫停推理再卸載。`unload()` 是 actor 隔離的,轉稿中排在
    /// `whisper_full` 後面 ⇒ 不先中斷就一定逾時,逾時後 `exit()` 會撞 ggml 靜態
    /// 解構 abort(實測轉稿中退出 6 輪當 4 次)。**回傳 true=真的卸乾淨了**;
    /// 回 false 代表還沒收乾淨,呼叫端要改走「跳過靜態解構直接結束」那條路,
    /// 🚫 不可以照常 exit()。
    @discardableResult
    public func unloadWhisperForQuit(timeout: TimeInterval = 2) async -> Bool {
        cancelWhisperUnload()
        guard let engine = whisperEngine else { return true }
        engine.requestAbort()          // nonisolated:不必等 actor 空出來
        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            quitUnloadContinuation = cont
            Task { @MainActor in
                await engine.unload()
                self.resumeQuitUnload(cleanly: true)
            }
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                self.resumeQuitUnload(cleanly: false)
            }
        }
    }

    private var quitUnloadContinuation: CheckedContinuation<Bool, Never>?

    /// 兩個 race Task 都會到這裡;nil 檢查=先到者 resume、後到者 no-op(防 double-resume)。
    private func resumeQuitUnload(cleanly: Bool = true) {
        quitUnloadContinuation?.resume(returning: cleanly)
        quitUnloadContinuation = nil
    }

    /// 逾時到點的實際釋放。閘沒過就重排一次,不是默默放棄(否則轉稿剛好卡在
    /// 逾時那一刻,這次釋放就永遠不會再發生)。
    private func unloadWhisperIfIdle() {
        whisperIdleTimer = nil
        guard let engine = whisperEngine else { return }
        guard Self.canUnloadWhisperWithPending(isTranscribing: isTranscribing,
                                               queuedCount: transcribeQueued.count,
                                               state: state,
                                               liveTranscribeEnabled: liveTranscribeEnabled,
                                               pendingCount: pendingHighAccuracy.count) else {
            scheduleWhisperUnload()
            return
        }
        Task { await engine.unload() }
    }
    /// BUG-22:對方(系統音訊)tap 是原生 Core Audio Process Tap + 私有 aggregate
    /// device(非 AVAudioEngine),沒有「引擎自己停了」的系統通知可監聽,且錄音
    /// 開始時只讀一次當下的預設輸出裝置、之後裝置變了也不會跟——2026-07-07 實
    /// 例:AirPods 錄音中連上、預設輸出切走,tap 繼續對著沒人在用的舊裝置,對方
    /// 軌整段真靜音。比照 BUG-18 補同一套「buffer 停止流動 → 自動重建」看門狗。
    private var lastSysLevelAt = Date()
    private var sysAutoRebuildCount = 0
    private var lastSysRebuildAt = Date.distantPast
    private var silentSysWarned = false
    private static let sysDeadAfter: TimeInterval = 5        // aggregate/tap 重建較慢,門檻比麥克風寬鬆些
    private static let sysRebuildCooldown: TimeInterval = 2
    private static let sysMaxConsecutiveRebuilds = 3
    /// BUG-24:AUD-32 的看門狗只看「buffer 有沒有停止流動」,但藍牙 HFP/SCO(電話
    /// 模式)路由下 Process Tap 會**持續送出全零 buffer**——IOProc 沒停、`onLevel`
    /// 照樣以 level≈0 觸發,所以 `lastSysLevelAt` 一直被刷新、看門狗全盲。實例:
    /// 2026-07-09 一場真實面談,對方軌開頭 1 分鐘有聲、第 3 分鐘起整整 31 分鐘數位零。
    /// 故另記「最後一次真的收到訊號」的時間,看門狗與死聲道警告都改判這個(而非
    /// buffer 到達)。搭配去單調的 `sysPeak`(見 8s 警告)才能偵測「中途才死」。
    private var lastSysSignalAt = Date()
    /// BUG-28:只在收到真訊號時更新,**重建 tap 不重設**。`lastSysSignalAt` 每次重建
    /// 都會被重設成現在(給新 tap 寬限期),拿它算「連續安靜 60 秒」會被 20 秒一次的
    /// 重建切斷、實際要等到約 120 秒。再跳門檻改判這個。
    private var lastSysRealSignalAt = Date()
    /// BUG-28/B2:這一場是否曾經「因為對方軌恢復聲音」自動收起過橫幅。
    private var sysWarningAutoDismissed = false
    private static let sysSilentWarnAfter: TimeInterval = 12   // 持續無「訊號」這麼久 → 死聲道警告(可重新武裝)
    private static let sysSilentRewarnAfter: TimeInterval = 60  // 自動收起過一次後,要連續這麼久沒真訊號才再跳(Eric 2026-09-18 題 C 選 60s)
    private static let sysSilentRebuildAfter: TimeInterval = 20 // 更久的真靜音才嘗試重建(避免自然對話停頓誤觸;HFP 重建救不回,警告才是主力)

    /// True once that channel has actually picked up sound this recording — the
    /// live "yes, this side is being captured" confirmation dot in the UI.
    public var micHasSignal: Bool { micPeak > Self.silenceThreshold }
    /// BUG-24:對方軌的健康指示燈**不能只看整場單調 `sysPeak`**——BUG-24 情境下開頭
    /// 那 1 分鐘的聲音會把 `sysPeak` 頂過門檻、之後整場全零卻仍顯示綠燈「收音中」,
    /// 跟同時武裝的死聲道警告自相矛盾(使用者看綠燈以為沒事)。所以一旦看門狗判定
    /// 對方軌持續無聲(`silentSysWarned`)就把燈熄掉;下次收到真訊號會 re-arm(見
    /// `system.onLevel`),燈再亮。
    public var sysHasSignal: Bool { sysPeak > Self.silenceThreshold && !silentSysWarned }

    public private(set) var recordingsDir: URL

    /// MAS-06／07(#2646):錄音夾的書籤狀態。商店版由 `RecordingsFolderAccess.probe`＋`classify` 決定;
    /// GitHub 版與 CLI 永遠 `.valid(recordingsDir)`(不走書籤,路徑字串照舊)。
    public private(set) var recordingsFolderState: RecordingsFolderAccess.State = .unset
    /// 商店版:目前 `startAccessingSecurityScopedResource` 中的 URL;換資料夾／重探／退出時 stop(MAS-29 配對)。
    private var scopedFolderURL: URL?
    public static let recordingsDirBookmarkKey = "recordingsDirBookmark"
    /// 商店版:沒有可用的錄音夾(未選／搬走／刪除／權限撤回)⇒ UI 要先讓人選,`startRecording` 會擋。GitHub 版永遠 false。
    public var needsRecordingsFolder: Bool { BuildFlavor.usesSecurityScopedRecordingsDir && recordingsFolderState.needsUserAction }
    /// Core 繁中句(GUI 依介面語言重組,見 CoreMessageL10n)。
    public nonisolated static let folderRequiredMessage = "請先選擇錄音資料夾"

    /// - Parameter explicitDir: CLI 用:直接指定錄音資料夾(config.json 的 recordingsDir),**不讀也不寫**
    ///   UserDefaults 的 `recordingsDir`。#949:舊寫法先 `init()` 再 `setRecordingsDir`,init 當下會先掃一次
    ///   偏好裡的舊資料夾(並跑收割)——CLI 指向示範夾時仍會碰到別的資料夾。GUI 不傳(照舊讀偏好/argument domain)。
    public init(recordingsDir explicitDir: URL? = nil) {
        // Default to a visible folder the user can browse to; overridable in Settings.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let explicitDir {
            recordingsDir = explicitDir
        } else if BuildFlavor.usesSecurityScopedRecordingsDir {
            // MAS-06:沙盒下只能用使用者選過、以 app-scoped bookmark 記住的資料夾。沒有可用的 ⇒ 先指向容器內的
            // 佔位夾(列表會是空的),`needsRecordingsFolder` 讓錄音鍵被擋、UI 跳選擇器——🚫 不會靜默錄進容器。
            // probe 回來的可用 URL 已 startAccessing;stale 的書籤由 revalidateRecordingsFolder(onAppear)重存。
            let (probe, accessing) = RecordingsFolderAccess.probe(bookmark: UserDefaults.standard.data(forKey: Self.recordingsDirBookmarkKey))
            let st = RecordingsFolderAccess.classify(probe)
            recordingsFolderState = st
            if let usable = st.usableURL {
                recordingsDir = usable
                scopedFolderURL = accessing
            } else {
                recordingsDir = docs.appendingPathComponent("MyParrot", isDirectory: true)
            }
        } else if let saved = UserDefaults.standard.string(forKey: "recordingsDir") {
            recordingsDir = URL(fileURLWithPath: saved, isDirectory: true)
        } else {
            recordingsDir = docs.appendingPathComponent("MyParrot", isDirectory: true)
        }
        // 逐字稿引擎依設定選(TR-14):Whisper 本地/雲端/Apple 原生;所選引擎
        // 不可用(模型未裝/key 未設)自動回退 Apple。Assign before any self use.
        let savedEngine = UserDefaults.standard.string(forKey: "engine")
            .flatMap(TranscriptionEngine.init(rawValue:)) ?? .appleNative
        engine = savedEngine
        let built = Self.buildTranscribers(for: savedEngine)
        live = built.live
        fileTranscriber = built.file
        whisperEngine = built.whisper
        // All stored properties are initialized below this point.
        MyParrotPaths.currentRecordingsDir = recordingsDir   // C2:協定檔(租約/state/commands)跟著錄音夾走,要在任何 lease/reap 之前
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        // 舊 Application Support 位置的一次性搬家只屬於 GUI(用偏好資料夾時);CLI 指定資料夾不搬;商店版沒選夾時不搬(佔位夾不是目的地)。
        if !BuildFlavor.usesSecurityScopedRecordingsDir || explicitDir != nil { recordingsFolderState = .valid(recordingsDir) }
        if explicitDir == nil, !needsRecordingsFolder { migrateLegacyRecordings(into: recordingsDir) }
        if let raw = UserDefaults.standard.string(forKey: "language"),
           let lang = TranscriptionLanguage(rawValue: raw) { language = lang }
        if UserDefaults.standard.object(forKey: "inputGain") != nil {
            inputGain = min(2.0, max(0.5, Float(UserDefaults.standard.double(forKey: "inputGain"))))
        }
        aecEnabled = UserDefaults.standard.bool(forKey: "aecSoftware")
        // #2417 CORR-01 → #2438 MDL-02:先把舊鍵 `correctionBackend` 遷到 `model.correction`(舊鍵保留),
        // 再依登錄表解析;鍵不存在/值不認得/本建置不提供 ⇒ 關閉。
        correctionBackend = Self.loadCorrectionBackend(defaults: UserDefaults.standard)
        correctionModel = UserDefaults.standard.string(forKey: "correctionModel") ?? ""
        // MAS-12:上次下載中途留下的孤兒 .part(mtime 超過 10 分鐘)啟動時清掉;正在下載的不會被碰。
        let orphans = WhisperModelStore.removeOrphanParts()
        if !orphans.isEmpty { print("[whisper] removed orphan .part: \(orphans)") }
        codexModel = UserDefaults.standard.string(forKey: "codexModel") ?? ""
        if UserDefaults.standard.object(forKey: "autoTranscribe") != nil {
            transcribePolicy = TranscribePolicy.migrate(raw: UserDefaults.standard.string(forKey: TranscribePolicy.key),
                                                        legacy: UserDefaults.standard.object(forKey: TranscribePolicy.legacyKey) as? Bool)
        }
        loadRecordings()
        loadInterrupted()            // #1697:標記對照現況修剪(檔案沒了/已轉好就清掉)
        resumePendingConversions()
        refreshDevicesSync()   // AUD-39:開場這一次維持同步——CLI 建好 controller 立刻讀 availableInputDevices
        installDeviceListener()
        live.onUpdate = { [weak self] lines in self?.liveTranscript = lines }
        if let note = built.note { warning = note }
    }

    // MARK: - 逐字稿引擎建構(TR-14)

    private static func buildTranscribers(for engine: TranscriptionEngine)
        -> (live: any LiveTranscribing, file: any TranscriptionProvider,
            whisper: WhisperCppEngine?, note: RecordingWarning?) {
        switch engine {
        case .whisperKit:
            if let url = WhisperModelStore.activeModelURL() {
                let eng = WhisperCppEngine(modelURL: url)
                return (WhisperLiveTranscriber(engine: eng),
                        WhisperCppFileProvider(engine: eng), eng, nil)
            }
            let (l, f) = appleTranscribers()
            return (l, f, nil, .whisperModelMissing)
        case .cloud:
            // Phase B:CloudSTTAdapter 接線後替換此 fallback。
            let (l, f) = appleTranscribers()
            return (l, f, nil, .cloudNotConfigured)
        case .appleNative:
            let (l, f) = appleTranscribers()
            return (l, f, nil, nil)
        }
    }

    private static func appleTranscribers() -> (any LiveTranscribing, any TranscriptionProvider) {
        if #available(macOS 26.0, *) {
            return (SpeechAnalyzerLiveTranscriber(), SpeechAnalyzerFileProvider())
        } else {
            return (LiveTranscriber(), AppleSpeechProvider())
        }
    }

    /// 設定頁模型變更後重建引擎(錄音中不動,下次開錄前生效)。
    public func reloadTranscriptionEngine() {
        guard state != .recording, state != .paused else {
            needsEngineRebuild = true
            warning = .engineChangeDeferred
            return
        }
        rebuildTranscribers()
    }
    private var needsEngineRebuild = false

    /// 引擎切換(僅 idle/finished 呼叫;錄音中由 didSet 延後)。
    private func rebuildTranscribers() {
        let built = Self.buildTranscribers(for: engine)
        live = built.live
        fileTranscriber = built.file
        whisperEngine = built.whisper
        live.onUpdate = { [weak self] lines in self?.liveTranscript = lines }
        if let note = built.note { warning = note }
    }

    // MARK: - Permissions (requested up-front on launch)

    public func requestPermissions() async {
        let micOK = await AVCaptureDevice.requestAccess(for: .audio)
        let speechOK = await Self.requestSpeechAuthorization()
        micPermission = micOK
        speechPermission = speechOK
    }

    // nonisolated: SFSpeech calls back on a background queue, so the continuation
    // must NOT inherit @MainActor isolation (otherwise Swift's isolation assert
    // crashes the app). We hop back to the main actor via `await` afterwards.
    private nonisolated static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
        }
    }

    /// AUD-39:**非阻塞**刷新裝置清單。`AudioDevices.inputDevices()` 逐顆讀裝置屬性(名稱、傳輸類型…),
    /// 藍牙狀態變動時會等 HAL;搬到背景 utility 佇列,結果回 main 套用。較舊的結果(refreshGeneration
    /// 不符)丟掉。開場那一次用 `refreshDevicesSync()`。
    public func refreshDevices() { refreshDevices(then: nil) }

    /// `then`:套用完清單後(main)要做的事——listener 用它判斷錄音中的裝置是否消失。
    private func refreshDevices(then: (@MainActor @Sendable () -> Void)?) {
        refreshGeneration += 1
        let gen = refreshGeneration
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let list = AudioDevices.inputDevices()
            let def = AudioDevices.defaultInputDevice()
            Task { @MainActor in
                guard let self, gen == self.refreshGeneration else { return }
                self.applyDeviceList(list, defaultDevice: def)
                then?()
            }
        }
    }

    /// 開場用的同步版(CLI 的 `record`／互動選單建好 controller 就讀 `availableInputDevices`、GUI 第一畫面要有選擇)。
    private func refreshDevicesSync() {
        applyDeviceList(AudioDevices.inputDevices(), defaultDevice: AudioDevices.defaultInputDevice())
    }

    /// 套用裝置清單＋選擇邏輯(main;不再打 CoreAudio)。
    private func applyDeviceList(_ list: [AudioInputDevice], defaultDevice: AudioInputDevice?) {
        availableInputDevices = list
        // Keep a still-valid current selection — a manual choice (incl. a Bluetooth
        // mic for testing) or an in-session main-screen hot-swap is always respected.
        if let sel = selectedInputDevice, list.contains(where: { $0.id == sel.id }) { return }
        // No valid selection (e.g. fresh launch): the *Settings* choice wins. Restore
        // it by UID — the persistent default — and only soft-default if it's absent.
        if let uid = defaults.string(forKey: preferredInputUIDKey),
           let saved = list.first(where: { $0.uid == uid }) {
            selectedInputDevice = saved
            return
        }
        selectedInputDevice = autoSelectInput(defaultDevice: defaultDevice)
    }

    private let preferredInputUIDKey = "preferredInputUID"

    /// Settings picker → the **persistent** default mic. Remembered across relaunch by
    /// device UID (BUG-13: selection was never persisted before). If recording, also
    /// hot-swaps live so the change takes effect immediately.
    public func setPreferredInputDevice(_ device: AudioInputDevice?) {
        if let device {
            defaults.set(device.uid, forKey: preferredInputUIDKey)
            applyMicSelection(device)
        } else {
            defaults.removeObject(forKey: preferredInputUIDKey)
            selectedInputDevice = nil
        }
    }

    /// Main-screen picker → a **transient** override for this session only. Does NOT
    /// persist (UI-15: on relaunch the Settings choice is authoritative). If recording,
    /// swaps the live mic without stopping the recording.
    public func switchMic(to device: AudioInputDevice) {
        applyMicSelection(device)
    }

    private func applyMicSelection(_ device: AudioInputDevice) {
        let live = state == .recording || state == .paused
        // AUD-38:切換中再選 ⇒ 忽略(UI 已禁用,這是保險);不先改 selectedInputDevice,選單才不會跟實際不符。
        if live && isSwitchingMic {
            os_log("MyParrot mic: 切換中,忽略再次選擇 %{public}@", device.name)
            return
        }
        let previous = selectedInputDevice
        selectedInputDevice = device
        if device.uid != micLockedUID { micLockedUID = nil }   // AUD-38:換裝置解鎖
        // Idle/finished: nothing live to swap — the next startRecording() picks it up.
        guard live else { return }
        hotSwapMic(to: device, fallback: previous)
    }

    /// Swap the live mic engine to `device` WITHOUT stopping the recording. 對方 (system,
    /// left) keeps running uninterrupted; 你 (mic, right) gets a brief (~0.1–0.5s) silence
    /// while the new engine spins up — auto-aligned by StereoRecorder's silence padding,
    /// so the file stays one continuous, time-aligned stereo recording (AUD-20). On a
    /// fresh MicCapture instance to avoid stale AUHAL/format caching. Falls back to the
    /// previous device if the new one won't start, so 你 軌 is never silently lost (AUD-21).
    private func hotSwapMic(to device: AudioInputDevice, fallback: AudioInputDevice?) {
        guard !isSwitchingMic else {
            os_log("MyParrot mic: 切換中,忽略再次切換到 %{public}@", device.name)
            return
        }
        isSwitchingMic = true
        micSwapGeneration += 1
        let gen = micSwapGeneration
        scheduleSwitchTimeout(gen)
        // G5:先記住舊實例是不是震盪鎖住的(鎖住＝引擎已停、不收音),再清鎖。
        let oldWasLocked = micLockedUID != nil
        micLockedUID = nil
        let old = mic
        old.suspendSelfHeal()   // G1:old 照錄,但它的自癒不再排進共用佇列跟 fresh.prepare 搶
        micFlowSince = nil
        let fresh = makeMic(like: old)
        inflightMics.append(fresh)
        // AUD-39 先建後拆:fresh 先 prepare(保持器、等系統預設輸入、建 AUHAL、裝 tap,藍牙下可能好幾秒),
        // 這段期間 old 照錄;prepare 好了才 stop old、run fresh——你軌空檔只剩「拆 old＋start fresh」。
        fresh.prepare(deviceID: device.id, isBluetooth: device.isBluetooth, avoidDeviceID: nil) { [weak self] error in
            Task { @MainActor in
                guard let self else { fresh.stop(); return }
                guard gen == self.micSwapGeneration,
                      self.state == .recording || self.state == .paused else {
                    self.inflightMics.removeAll { $0 === fresh }
                    fresh.stop()
                    // 逾時作廢、old 還是現役且沒有新的切換 ⇒ old 繼續錄,恢復它的自癒。
                    if self.mic === old, !self.isSwitchingMic { old.resumeSelfHeal() }
                    return
                }
                if let error {
                    self.inflightMics.removeAll { $0 === fresh }
                    if oldWasLocked {
                        // G5:old 是鎖死的(不收音)⇒ 不能「沿用」,走 restore 鏈在原裝置上起新實例。
                        old.stop()
                        self.restoreFallbackMic(old: old, fallback: fallback, failedDevice: device, error: error, gen: gen)
                        return
                    }
                    // prepare 失敗:old 沒動、還在錄 ⇒ 你軌沒斷;選單退回原裝置、照舊文案告知(AUD-21 的結果)。
                    old.resumeSelfHeal()
                    self.micPeak = 0
                    self.silentMicWarned = false
                    self.selectedInputDevice = fallback
                    self.lastError = "切換到「\(device.name)」失敗,已沿用原麥克風:\(error)"
                    self.finishMicSwitch(succeeded: true)   // old 健康且繼續錄 ⇒ 看門狗從現在計時
                    return
                }
                // Re-arm the 8s dead-channel warning for BOTH outcomes: `old` is about to stop,
                // so micPeak must not keep the previous device's high value — otherwise the
                // silent-mic check never re-fires after a failed swap (AUD-22).
                self.micPeak = 0
                self.silentMicWarned = false
                old.stop()   // 立刻靜音;共用佇列上拆完 old 才輪到 fresh.run
                fresh.run { [weak self] error in
                    Task { @MainActor in
                        guard let self else { fresh.stop(); return }
                        self.inflightMics.removeAll { $0 === fresh }
                        guard gen == self.micSwapGeneration,
                              self.state == .recording || self.state == .paused else { fresh.stop(); return }
                        guard let error else {
                            self.mic = fresh
                            self.warning = .micSwitched(device: device.name)
                            self.finishMicSwitch(succeeded: true)
                            return
                        }
                        // run 失敗時 old 已停 ⇒ 走原本的 fallback:在原裝置上重開,你軌才不會斷(AUD-21)。
                        self.restoreFallbackMic(old: old, fallback: fallback, failedDevice: device, error: error, gen: gen)
                    }
                }
            }
        }
    }

    /// AUD-21 的 fallback 鏈:old 已停(run 失敗,或 G5 鎖死的 old),在原裝置上起新實例。
    /// 成功 ⇒ 沿用原麥克風(`micLockedUID` 保持 nil);再失敗 ⇒ `.micSwitchFailed`。
    private func restoreFallbackMic(old: MicCapture, fallback: AudioInputDevice?, failedDevice device: AudioInputDevice,
                                    error: Error, gen: Int) {
        let restore = makeMic(like: old)
        inflightMics.append(restore)
        restore.start(deviceID: fallback?.id, isBluetooth: fallback?.isBluetooth ?? false) { [weak self] restoreError in
            Task { @MainActor in
                guard let self else { restore.stop(); return }
                self.inflightMics.removeAll { $0 === restore }
                guard gen == self.micSwapGeneration,
                      self.state == .recording || self.state == .paused else { restore.stop(); return }
                if restoreError == nil {
                    self.mic = restore
                    self.selectedInputDevice = fallback
                    self.lastError = "切換到「\(device.name)」失敗,已沿用原麥克風:\(error)"
                    self.finishMicSwitch(succeeded: true)
                } else {
                    // BOTH the new device and the fallback failed to start: 你軌 is now dead.
                    // Warn loudly (the old "已沿用原麥克風" text would be a lie) and restore the
                    // device label so the picker matches reality (AUD-21/22).
                    self.selectedInputDevice = fallback
                    self.warning = .micSwitchFailed(device: device.name)
                    self.lastError = "麥克風切換失敗,你軌已中斷:\(error)"
                    self.finishMicSwitch(succeeded: false)
                }
            }
        }
    }

    /// AUD-38:錄音用的新 MicCapture——gain 用目前設定,onLevel／onBuffer 從 `old` 搬,掛震盪鎖回呼。
    /// (monitor 不走這裡:它不設 onLocked。)
    private func makeMic(like old: MicCapture?) -> MicCapture {
        let m = MicCapture()
        m.gain = inputGain
        if let old {
            m.onLevel = old.onLevel
            m.onBuffer = old.onBuffer
        }
        wireLockHandler(m)
        return m
    }

    /// 震盪鎖回呼:只認目前在用的那個實例、還在錄音中、而且不在切換中(停錄、已換掉的舊實例、
    /// 切麥途中舊實例晚到的通知都不算,否則會把鎖記到新選的裝置上;AUD-38 F3)。
    private func wireLockHandler(_ m: MicCapture) {
        m.onLocked = { [weak self, weak m] in
            Task { @MainActor in
                guard let self, let m, self.mic === m, !self.isSwitchingMic,
                      self.state == .recording || self.state == .paused else { return }
                self.handleMicLocked()
            }
        }
    }

    /// 切麥／重建結束(成功、fallback、雙失敗都要叫)。成功＝有一個新引擎在跑,看門狗從現在重新計時;
    /// `resetRebuildCount` 只給使用者手動切麥用——自動重建成功不歸零,計數只在 buffer 連續流動 10 秒後歸零(§2.5)。
    private func finishMicSwitch(succeeded: Bool, resetRebuildCount: Bool = true) {
        isSwitchingMic = false
        micFlowSince = nil
        if succeeded {
            lastMicLevelAt = Date()
            micSilenceGraceUntil = Date().addingTimeInterval(8)   // 新引擎重新給 8 秒緩衝再判無聲
            if resetRebuildCount { micAutoRebuildCount = 0 }
        }
    }

    /// AUD-38 F4:切麥／重建／開錄的 start 超過 `MicWatchdogPolicy.switchTimeout` 還沒回來 ⇒ 遞增世代讓晚到的
    /// completion 作廢(它會 stop 自己的新引擎)、結束切換狀態(選單解禁、看門狗恢復計時)、報錯。
    private func scheduleSwitchTimeout(_ gen: Int) {
        let startedAt = Date()
        DispatchQueue.main.asyncAfter(deadline: .now() + MicWatchdogPolicy.switchTimeout) { [weak self] in
            Task { @MainActor in
                guard let self, self.isSwitchingMic, gen == self.micSwapGeneration,
                      MicWatchdogPolicy.switchTimedOut(startedAt: startedAt, now: Date()) else { return }
                self.micSwapGeneration += 1
                self.finishMicSwitch(succeeded: false)
                self.lastError = "麥克風切換逾時（\(Int(MicWatchdogPolicy.switchTimeout)) 秒），請重選裝置"
                os_log("MyParrot mic: 切換逾時(%ld 秒),作廢這一輪 start", Int(MicWatchdogPolicy.switchTimeout))
            }
        }
    }

    /// AUD-38:MicCapture 震盪鎖觸發(藍牙 HFP 格式 20 秒內反覆切換)⇒ 記住鎖住的裝置、跳橫幅、看門狗不再重建。
    private func handleMicLocked() {
        micLockedUID = selectedInputDevice?.uid ?? Self.micLockedDefaultSentinel
        warning = .micBluetoothUnstable(device: selectedInputDevice?.name ?? "藍牙麥克風")
        isSwitchingMic = false
        youLevel = 0
    }

    /// AUD-28 / BUG-18: rebuild the live mic on the *current* device WITHOUT a user-
    /// initiated switch — driven by the liveness watchdog (buffers stopped flowing) and by
    /// the device listener (the selected device vanished). Resolves the device by stable
    /// UID (the numeric id may have been reassigned on replug), falling back to the system
    /// default if the chosen device is gone. No fallback chain like hotSwapMic; if it fails
    /// the watchdog retries up to the consecutive cap, then the 8s warning fires.
    private func rebuildCurrentMic(reason: MicRebuildReason, avoidDeviceID: AudioDeviceID? = nil) {
        guard !isSwitchingMic else {
            os_log("MyParrot mic: 切換中,略過自動重建(%{public}@)", reason.zhTW)
            return
        }
        isSwitchingMic = true
        micSwapGeneration += 1
        let gen = micSwapGeneration
        scheduleSwitchTimeout(gen)
        micFlowSince = nil
        // G1:自動重建時 old 已經死了(沒 buffer／裝置消失),立刻停掉,不等 prepare;先建後拆只留給使用者切麥。
        mic.stop()
        // AUD-39:裝置解析(逐顆讀屬性)在背景做,回 main 才 prepare/run。
        let selected = selectedInputDevice
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let available = AudioDevices.inputDevices()
            let device = selected.flatMap { sel in available.first { $0.uid == sel.uid } }
                         ?? AudioDevices.defaultInputDevice()
            Task { @MainActor in
                guard let self, gen == self.micSwapGeneration,
                      self.state == .recording || self.state == .paused else { return }
                self.rebuildMic(on: device, reason: reason, avoidDeviceID: avoidDeviceID, gen: gen)
            }
        }
    }

    /// `rebuildCurrentMic` 的後半(main):先建後拆。
    private func rebuildMic(on device: AudioInputDevice?, reason: MicRebuildReason, avoidDeviceID: AudioDeviceID?, gen: Int) {
        let old = mic
        let fresh = makeMic(like: old)
        inflightMics.append(fresh)
        // AUD-39 等預設輸入:`avoidDeviceID`＝剛消失的裝置(listener 帶入),建 AUHAL 前等系統預設輸入
        // 換掉它(BUG-35 真機 20.5 秒)。old 在 rebuildCurrentMic 已先停(G1);prepare 失敗 ⇒ 下一輪看門狗再試。
        fresh.prepare(deviceID: device?.id, isBluetooth: device?.isBluetooth ?? false,
                      avoidDeviceID: avoidDeviceID) { [weak self] error in
            Task { @MainActor in
                guard let self else { fresh.stop(); return }
                guard gen == self.micSwapGeneration,
                      self.state == .recording || self.state == .paused else {
                    self.inflightMics.removeAll { $0 === fresh }
                    fresh.stop()
                    return
                }
                if let error {
                    self.inflightMics.removeAll { $0 === fresh }
                    self.lastError = "麥克風自動重建失敗(\(reason.zhTW)) — 將持續重試"
                    os_log("MyParrot mic: 自動重建 prepare 失敗:%{public}@", "\(error)")
                    self.finishMicSwitch(succeeded: false)
                    return
                }
                fresh.run { [weak self] error in
                    Task { @MainActor in
                        guard let self else { fresh.stop(); return }
                        self.inflightMics.removeAll { $0 === fresh }
                        guard gen == self.micSwapGeneration,
                              self.state == .recording || self.state == .paused else { fresh.stop(); return }
                        if error == nil {
                            self.mic = fresh
                            if let device { self.selectedInputDevice = device }   // keep picker in sync if we fell back
                            // 落到別顆裝置＝換裝置解鎖;鎖的是哨兵值(系統預設)時,任何真實 uid 都算不同。
                            if device?.uid != self.micLockedUID { self.micLockedUID = nil }
                            self.warning = .micReconnected(reason: reason, device: device?.name)
                            self.finishMicSwitch(succeeded: true, resetRebuildCount: false)
                        } else {
                            self.lastError = "麥克風自動重建失敗(\(reason.zhTW)) — 將持續重試"
                            self.finishMicSwitch(succeeded: false)
                        }
                    }
                }
            }
        }
    }

    /// BUG-22:對方(系統音訊)tap 的重建——比照 rebuildCurrentMic,但
    /// SystemAudioCapture 是原生 Core Audio tap+aggregate(非 AVAudioEngine),
    /// 沒有引擎自己停了的通知,靠這裡統一補:輸出裝置變更(installDeviceListener
    /// 立即觸發)或 buffer 停止流動(watchdog 逾時觸發)都走同一條路徑。
    /// stop()+start() 重用同一個 SystemAudioCapture 實例——tap/aggregate 每次
    /// start() 都建新 UUID(見 SystemAudioCapture.swift),可安全反覆重建,不必
    /// 像 MicCapture 那樣另開新實例。
    private func rebuildSystemCapture(reason: SysRebuildReason) {
        // AUD-39:拆建 tap＋aggregate 在 SystemAudioCapture 的序列佇列上做(藍牙狀態變動時會等 HAL),
        // 重建中看門狗／輸出裝置 listener 不再觸發。stop 與 start 依序排進同一條序列佇列;
        // 期間若停錄,停錄的 stop 排在後面、世代不符的結果直接丟掉。
        isRebuildingSys = true
        sysRebuildGeneration += 1
        let gen = sysRebuildGeneration
        let startedAt = DispatchTime.now()
        scheduleSysRebuildTimeout(gen)   // G4
        os_log("MyParrot sys: rebuild 開始 reason=%{public}@", reason.zhTW)   // AUD-39 M1
        system.stop()
        system.start { [weak self] error in
            Task { @MainActor in
                guard let self, gen == self.sysRebuildGeneration else { return }
                self.isRebuildingSys = false
                self.finishSystemRebuild(reason: reason, error: error, startedAt: startedAt)
            }
        }
    }

    /// AUD-40(BUG-36):對方軌看門狗要重建前(buffer 停流或持續無聲),先在 SystemAudioCapture 的佇列上查目標輸出
    /// 裝置在不在跑。閒置 ⇒ 略過(不跳橫幅、不加計數,`lastSysLevelAt`／`lastSysSignalAt` 推到現在,下一輪再看);
    /// 在跑或讀不到 ⇒ 照舊重建(BUG-24 HFP 全零時輸出裝置在跑,行為不變)。
    /// 檢查期間借用 `isRebuildingSys` 當互斥(看門狗與輸出 listener 不疊),世代照遞增。
    private func checkOutputThenRebuild(reason: SysRebuildReason) {
        isRebuildingSys = true
        sysRebuildGeneration += 1
        let gen = sysRebuildGeneration
        system.checkOutputRunning { [weak self] running in
            Task { @MainActor in
                guard let self, gen == self.sysRebuildGeneration else { return }
                self.isRebuildingSys = false
                switch SysTrackWatchdog.staleAction(outputRunning: running) {
                case .skipIdle:
                    // 題 P1:兩個計時都推到現在,停流與持續無聲兩條路徑都要等下一輪才再看(lastSysRealSignalAt 不動,BUG-28)。
                    self.lastSysLevelAt = Date()
                    self.lastSysSignalAt = Date()
                    os_log("MyParrot sys: 輸出裝置閒置,略過重建(%{public}@)", reason.zhTW)
                case .rebuild:
                    self.sysAutoRebuildCount += 1
                    self.lastSysRebuildAt = Date()
                    self.rebuildSystemCapture(reason: reason)
                }
            }
        }
    }

    /// AUD-39 D(G4):對方軌 start 超過 `SysTrackWatchdog.rebuildTimeout` 還沒回來 ⇒ 結束「重建中」(看門狗恢復)、
    /// 世代 +1 讓晚到的結果作廢、報錯。
    private func scheduleSysRebuildTimeout(_ gen: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + SysTrackWatchdog.rebuildTimeout) { [weak self] in
            Task { @MainActor in
                guard let self, self.isRebuildingSys, gen == self.sysRebuildGeneration else { return }
                self.isRebuildingSys = false
                self.sysRebuildGeneration += 1
                self.lastError = "對方軌重建逾時（\(Int(SysTrackWatchdog.rebuildTimeout)) 秒）"
                os_log("MyParrot sys: rebuild 逾時(%ld 秒)", Int(SysTrackWatchdog.rebuildTimeout))
            }
        }
    }

    private func finishSystemRebuild(reason: SysRebuildReason, error: Error?, startedAt: DispatchTime) {
        // AUD-39 M1:從開始重建到結果回 main 的總耗時(含排隊、拆、建)。
        os_log("MyParrot sys: rebuild 完成 reason=%{public}@ ok=%ld %ldms", reason.zhTW, error == nil ? 1 : 0,
               Int((DispatchTime.now().uptimeNanoseconds &- startedAt.uptimeNanoseconds) / 1_000_000))
        if let error {
            lastError = "系統音訊自動重建失敗(\(reason.zhTW)):\(error)"
            return
        }
        // Give the rebuilt tap a fresh grace window before it can be judged
        // stale/silent again, so the bounded retries are spaced ~sysSilentRebuildAfter
        // apart (a fair recovery chance) instead of firing back-to-back (BUG-24).
        lastSysLevelAt = Date(); lastSysSignalAt = Date()
        // BUG-24:別用「已自動重新啟動」的成功語氣蓋掉稍早那句可行動的 HFP 提示。
        // 若這次重建是因「持續無聲」(silentSysWarned 已武裝),重建對 HFP 路由救不回
        // 聲音,誆稱「已重啟」會變成停到錄音結束的假安心;改成不宣稱成功的合併訊息。
        // BUG-28/B2 題 C:自動收起後的靜音觀察期內,持續無聲觸發的重建不再跳
        // 橫幅——否則 20 秒的重建會先跳出來,60 秒的再跳門檻等於白設。
        if let banner = SysTrackWatchdog.rebuildBanner(
                silentWarned: silentSysWarned, reason: reason,
                inRewarnGrace: sysWarningAutoDismissed && !silentSysWarned) {
            warning = banner
        }
    }

    /// Soft-default the mic toward the most reliable source. Bluetooth forces
    /// narrowband HFP + gets grabbed by the meeting app (dead recording); iPhone
    /// Continuity drops mid-recording (research: not proven fixed even wired). So
    /// built-in/USB win over iPhone, and Bluetooth is last. Order:
    /// system default (if built-in/USB) → built-in → any built-in/USB → wired iPhone
    /// → any non-BT (wireless iPhone beats BT) → finally anything. Never hard-blocks —
    /// the user can still pick iPhone / Bluetooth manually (e.g. to test).
    private func autoSelectInput(defaultDevice def: AudioInputDevice?) -> AudioInputDevice? {
        func topReliable(_ d: AudioInputDevice) -> Bool { !d.isBluetooth && !d.isContinuity }
        if let def, topReliable(def), let m = availableInputDevices.first(where: { $0.id == def.id }) { return m }
        if let builtIn = availableInputDevices.first(where: { $0.isBuiltIn && !$0.isBluetooth }) { return builtIn }
        if let usb = availableInputDevices.first(where: topReliable) { return usb }
        if let wiredPhone = availableInputDevices.first(where: { $0.isContinuityWired && !$0.isBluetooth }) { return wiredPhone }
        if let nonBT = availableInputDevices.first(where: { !$0.isBluetooth }) { return nonBT }
        return availableInputDevices.first   // only Bluetooth available — can't avoid it
    }

    // MARK: - Save directory (#6)

    /// Core 繁中句:錄音／暫停中不換夾(C2 後協定檔跟著夾走,換了會把心跳／state／commands 拆到兩夾;二審指出)。
    public nonisolated static let folderChangeBlockedMessage = "錄音中不能更換錄音資料夾"

    public func setRecordingsDir(_ url: URL) {
        guard state == .idle || state == .finished else { lastError = Self.folderChangeBlockedMessage; return }
        if BuildFlavor.usesSecurityScopedRecordingsDir {
            // MAS-06:NSOpenPanel／拖到圖示／`open -a` 給的 URL 自帶 scope。二審後的交換順序:先 start 新 token,
            // start 失敗或寫不進 ⇒ 放掉新 token、不 commit、舊夾原樣(state=denied 讓 UI 提示);成功 ⇒ 存書籤、
            // commit 新夾,最後無條件 stop 舊 token(同路徑也一樣,start/stop 一對一)。書籤建不起來只影響下次啟動。
            let granted = url.startAccessingSecurityScopedResource()
            guard granted, RecordingsFolderAccess.canWrite(in: url) else {
                if granted { url.stopAccessingSecurityScopedResource() }
                recordingsFolderState = .denied(url)
                lastError = "沒有權限寫入所選的資料夾"
                return
            }
            if let data = try? RecordingsFolderAccess.makeBookmark(for: url) {
                defaults.set(data, forKey: Self.recordingsDirBookmarkKey)
            } else {
                defaults.removeObject(forKey: Self.recordingsDirBookmarkKey)
                print("[MAS] bookmarkData failed for \(url.lastPathComponent)")
            }
            if let old = scopedFolderURL { old.stopAccessingSecurityScopedResource() }
            scopedFolderURL = url
            recordingsFolderState = .valid(url)
        } else {
            recordingsFolderState = .valid(url)
        }
        recordingsDir = url
        MyParrotPaths.currentRecordingsDir = url   // C2
        defaults.set(url.path, forKey: "recordingsDir")   // 商店版只供顯示;真相是書籤
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        loadRecordings()
        reapInprogress()   // #949:新資料夾裡租約已死的 inprogress 也復原
        externalWatcher?.setDirectories(Self.watchDirectories(for: url))   // #949:監看跟著換;C2 三個位置一起(二審:之前漏了舊位置)
        refreshExternal()
    }

    /// MAS-07:回前景／啟動後重探一次書籤(資料夾被搬走 ⇒ stale 重存;被刪／權限撤回 ⇒ 請重選),錄音中不動。
    /// GitHub 版什麼都不做。
    public func revalidateRecordingsFolder() {
        guard BuildFlavor.usesSecurityScopedRecordingsDir, state == .idle || state == .finished else { return }
        let (probe, accessing) = RecordingsFolderAccess.probe(bookmark: defaults.data(forKey: Self.recordingsDirBookmarkKey))
        let st = RecordingsFolderAccess.classify(probe)
        if let old = scopedFolderURL { old.stopAccessingSecurityScopedResource() }   // probe 已對可用 URL 重新 startAccessing
        scopedFolderURL = accessing
        recordingsFolderState = st
        guard let usable = st.usableURL else { return }
        if usable.standardizedFileURL != recordingsDir.standardizedFileURL {
            recordingsDir = usable
            MyParrotPaths.currentRecordingsDir = usable   // C2
            externalWatcher?.setDirectories(Self.watchDirectories(for: usable))
            loadRecordings()
        }
        if case .stale = st, let data = try? RecordingsFolderAccess.makeBookmark(for: usable) {
            defaults.set(data, forKey: Self.recordingsDirBookmarkKey)
            recordingsFolderState = .valid(usable)
        }
    }

    /// 退出前放掉 scope(MAS-29 start／stop 配對);GitHub 版 no-op。
    public func releaseRecordingsFolderAccess() {
        scopedFolderURL?.stopAccessingSecurityScopedResource()
        scopedFolderURL = nil
    }

    // MARK: - Playback (#2)

    /// 列的主鈕:沒在播 → 開播;播放中 → 暫停;已暫停 → 續播;播完(ended) → 從頭重播。
    public func togglePlay(_ rec: Recording) {
        if playingURL == rec.url {
            switch playbackPhase {
            case .playing: pausePlayback()
            case .paused: resumePlayback()
            case .ended: restartPlayback()
            }
            return
        }
        stopPlayback()
        do {
            let p = try AVAudioPlayer(contentsOf: rec.url)
            p.isMeteringEnabled = true
            p.prepareToPlay()
            // 二審:play() 失敗(輸出裝置不可用等)原本照樣進 .playing,下個 tick 被當成
            // 「播完」顯示 ↻——改成明確報錯、不進播放狀態。
            guard p.play() else { lastError = "播放失敗:音訊輸出無法啟動"; return }
            player = p
            playingURL = rec.url
            playbackPhase = .playing
            playbackTime = 0
            playbackDuration = p.duration
            startPlaybackTicker()
        } catch { lastError = "播放失敗:\(error)" }
    }

    /// 暫停:時間與電平都「凍結」在當下(UI-28 驗收 (b);三鏡頭審抓到原本把電平歸零);
    /// ticker 一併停掉,不讓 10Hz Timer 在暫停期間空轉(同審)。
    public func pausePlayback() {
        guard let p = player, playbackPhase == .playing else { return }
        p.pause()
        playbackPhase = .paused
        playbackTime = p.currentTime
        playbackTicker?.invalidate(); playbackTicker = nil
    }

    public func resumePlayback() {
        guard let p = player, playbackPhase == .paused else { return }
        guard p.play() else { lastError = "播放失敗:音訊輸出無法啟動"; return }
        playbackPhase = .playing
        if playbackTicker == nil { startPlaybackTicker() }
    }

    /// 從頭播放(右鍵選單/「錄音」選單/播完後的 ↻)。
    public func restartPlayback() {
        guard let p = player else { return }
        p.currentTime = 0
        playbackTime = 0
        if playbackPhase != .playing {
            guard p.play() else { lastError = "播放失敗:音訊輸出無法啟動"; return }
            playbackPhase = .playing
        }
        if playbackTicker == nil { startPlaybackTicker() }
    }

    /// 點擊/拖曳進度列。暫停中 seek 只移位置不自動續播;播完後 seek 視同重播起點。
    public func seek(to t: TimeInterval) {
        guard let p = player else { return }
        let clamped = max(0, min(t, max(0, p.duration - 0.05)))
        p.currentTime = clamped
        playbackTime = clamped
        if playbackPhase == .ended, p.play() { playbackPhase = .playing; if playbackTicker == nil { startPlaybackTicker() } }
    }

    /// 播放列出現時呼叫:背景算波形(utility 優先序、分段讀檔),10 秒沒算完視同失敗。
    /// 已有/失敗中/算到一半都直接 return,冪等。
    /// 二審(UI-28b):不能把同步的 analyze 放進 withTaskGroup 跟 sleep 賽跑——group 會
    /// 隱含等到 analyze 真的跑完才返回,「10 秒逾時」是假的,慢碟/iCloud 佔位檔會讓
    /// 該 URL 永遠卡在 inFlight。改成:analyze 走獨立 detached Task,逾時另開一個
    /// Task 先標失敗;analyze 若之後還是算完了,結果照收(把「波形不可用」換回波形)。
    public func requestWaveform(for url: URL) {
        if waveforms[url] != nil || waveformFailed.contains(url) || waveformInFlight.contains(url) { return }
        waveformInFlight.insert(url)
        // UI-28c:先讀落檔快取(key 含大小+mtime,同名重錄自然失效),沒有才算、算完寫回。
        let analyzeTask = Task.detached(priority: .utility) { () -> Waveform? in
            if let cached = WaveformCache.load(for: url) { return cached }
            guard let w = try? WaveformAnalyzer.analyze(url: url) else { return nil }
            WaveformCache.save(w, for: url)
            return w
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard let self, self.waveformInFlight.contains(url) else { return }
            self.waveformInFlight.remove(url)
            self.waveformFailed.insert(url)
        }
        Task { @MainActor [weak self] in
            let result = await analyzeTask.value
            guard let self else { return }
            let wasInFlight = self.waveformInFlight.remove(url) != nil
            if let result {
                self.waveforms[url] = result
                self.waveformFailed.remove(url)      // 逾時後補算完:換回波形
            } else if wasInFlight {
                self.waveformFailed.insert(url)
            }
        }
    }

    public func stopPlayback() {
        player?.stop(); player = nil
        playbackTicker?.invalidate(); playbackTicker = nil
        playingURL = nil
        playbackPhase = .playing
        playbackTime = 0; playbackDuration = 0
        playbackOtherLevel = 0; playbackYouLevel = 0
    }

    /// 0.1s:進度每秒至少走 10 次才不顯得卡;兩個 Float + 一個 TimeInterval 的更新,
    /// 成本可忽略(UI-28 驗收 (d) CPU <3%)。
    private func startPlaybackTicker() {
        playbackTicker?.invalidate()
        playbackTicker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.playbackTick() }
        }
    }

    private func playbackTick() {
        guard let p = player else { stopPlayback(); return }
        switch playbackPhase {
        case .paused:
            return
        case .ended:
            return
        case .playing:
            if p.isPlaying {
                playbackTime = p.currentTime
                p.updateMeters()
                // averagePower 是 dBFS(≤0);轉線性 RMS 再 ×4,與錄音路徑同標度。
                func lin(_ ch: Int) -> Float {
                    guard ch < p.numberOfChannels else { return 0 }
                    let db = p.averagePower(forChannel: ch)
                    guard db.isFinite, db > -120 else { return 0 }
                    return min(1, powf(10, db / 20) * 4)
                }
                playbackOtherLevel = lin(0)
                // 單聲道檔:右條跟左條同值,不顯示「你沒聲音」的假象。
                playbackYouLevel = p.numberOfChannels > 1 ? lin(1) : playbackOtherLevel
            } else {
                // 播完(AVAudioPlayer 播到底會自己 stop)→ ended:主鈕變 ↻,
                // 進度停在尾端,3 秒後若使用者沒動作就收回。
                playbackPhase = .ended
                playbackTime = p.duration
                playbackOtherLevel = 0; playbackYouLevel = 0
                playbackTicker?.invalidate(); playbackTicker = nil
                let url = playingURL
                Task { @MainActor [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let self, self.playingURL == url, self.playbackPhase == .ended else { return }
                    self.stopPlayback()
                }
            }
        }
    }

    // MARK: - Live mic monitor for the sensitivity test (#5)

    /// Level shown by the Settings sensitivity meter: the live recording mic level
    /// while recording, otherwise the standalone monitor level. Either way it moves.
    public var meterLevel: Float { state == .recording ? youLevel : monitorLevel }
    public var meterActive: Bool { state == .recording || isMonitoring }

    public func startMicMonitor() {
        // While recording, the meter reflects the live recording level (youLevel),
        // so we don't spin up a second engine fighting for the same mic.
        guard !isMonitoring, state != .recording else { return }
        monitorGeneration += 1
        let gen = monitorGeneration
        monitor.stop()
        monitor = MicCapture()   // AUD-38 F6:新實例,closure 在 start 前設好、之後不改寫
        monitor.gain = inputGain
        monitor.onLevel = { [weak self] v in Task { @MainActor in self?.monitorLevel = v } }
        // AUD-38:非阻塞 start;isMonitoring 只在世代沒變(期間沒有 stopMicMonitor／重新 start)時才動。
        let monitor = self.monitor
        monitor.start(deviceID: selectedInputDevice?.id, isBluetooth: selectedInputDevice?.isBluetooth ?? false) { [weak self] error in
            Task { @MainActor in
                guard let self, gen == self.monitorGeneration else { return }
                guard error != nil else { self.isMonitoring = true; return }
                // G-1 審查發現:若 start 在 tap 已裝之後才失敗,對同一顆 engine 的 bus 0 再裝一次 tap
                // 會撞 AVAudioEngine fatal exception(nullptr == Tap())。重試前先 stop() 讓
                // tapInstalled 清乾淨(MicCapture.start 失敗路徑現在也會自己清,這裡留著當保險)。
                monitor.stop()
                // Retry on the system default device before giving up.
                // AUD-39 D(G2):MicCapture 單次使用,stop 過的實例不能再 start ⇒ 重試用新實例。
                let retry = MicCapture()
                retry.gain = self.inputGain
                retry.onLevel = { [weak self] v in Task { @MainActor in self?.monitorLevel = v } }
                self.monitor = retry
                retry.start(deviceID: nil, isBluetooth: false) { [weak self] retryError in
                    Task { @MainActor in
                        guard let self, gen == self.monitorGeneration else { return }
                        if let retryError { self.lastError = "麥克風測試失敗:\(retryError)" } else { self.isMonitoring = true }
                    }
                }
            }
        }
    }

    public func stopMicMonitor() {
        monitorGeneration += 1
        monitor.stop(); isMonitoring = false; monitorLevel = 0
    }

    // MARK: - Controls

    public func startRecording() {
        guard state == .idle || state == .finished else { return }
        // MAS-07:商店版沒有可用的錄音夾就不開錄(訊息給 UI,🚫 不靜默錄進容器)。GitHub 版 needsRecordingsFolder 永遠 false。
        if needsRecordingsFolder { lastError = Self.folderRequiredMessage; return }
        let date = Date()
        let title = currentTitle.isEmpty ? "錄音" : currentTitle
        // #892:同分鐘同標題不再覆蓋——探測到同 stem 既有檔就加「 2」「 3」後綴。
        // #949:這是停止時要**發布**到的頂層名字;錄音中實際寫在 inprogress(發布時再探一次避讓)。
        let url = recordingsDir.appendingPathComponent(
            Recording.uniqueFileName(date: date, title: title, in: recordingsDir))
        // #949 REC-30/31:先取全域租約,取不到＝開錄失敗(lastError「已有錄音進行中」、state 不變、不建檔),
        // 在停麥克風測試/停播放這些副作用之前就擋下。
        let sid = UUID().uuidString
        let audioURL = Self.inprogressURL(dir: recordingsDir, sessionId: sid)
        guard beginLease(sessionId: sid, name: url.deletingPathExtension().lastPathComponent, audioURL: audioURL) else { return }
        if needsEngineRebuild { rebuildTranscribers(); needsEngineRebuild = false }
        stopMicMonitor()   // free the mic before recording
        stopPlayback()
        // UI-28b 二審:保險再踢一次該 URL 的波形快取(理論上已不會撞名)。#949:用最終頂層 URL(列表與播放器認的是它)。
        waveforms.removeValue(forKey: url); waveformFailed.remove(url); waveformInFlight.remove(url)
        currentURL = url

        liveTranscript = []
        warning = nil
        lastError = nil
        micPeak = 0; sysPeak = 0; silentMicWarned = false; silentSysWarned = false
        lastMicLevelAt = Date(); micAutoRebuildCount = 0; lastMicRebuildAt = .distantPast
        micFlowSince = nil; micLockedUID = nil; micSilenceGraceUntil = .distantPast   // AUD-38
        lastSysLevelAt = Date(); lastSysSignalAt = Date(); sysAutoRebuildCount = 0; lastSysRebuildAt = .distantPast
        lastSysRealSignalAt = Date(); sysWarningAutoDismissed = false
        micDeadAlarmed = false; sysDeadAlarmed = false; deadTrackAlarms = []
        micSpeech.reset(); sysSpeech.reset(); silenceRule.reset(); speechSinceTick = false; silenceStopSuggestedAt = nil
        // AUD-38 F1/F6:每場錄音用新實例(上一場的在 stop() 已停),onLevel／onBuffer 在 start 前設好、之後不改寫。
        mic = makeMic(like: nil)

        // Capture plain references/values so the audio-thread callbacks never touch
        // @MainActor state (doing so crashes under Swift 6 isolation checks).
        let recorder = self.recorder
        let live = self.live
        let liveOn = self.liveTranscribeEnabled
        system.onLevel = { [weak self] v in Task { @MainActor in
            guard let self else { return }
            self.otherLevel = v; self.sysPeak = max(self.sysPeak, v)
            if self.sysSpeech.observe(level: v, at: self.elapsed) { self.speechSinceTick = true }   // CAL-09
            // A buffer arrived → the *tap* is alive. But under Bluetooth HFP routing the
            // tap keeps delivering all-zero buffers, so buffer-arrival alone does NOT mean
            // 對方 audio is being captured (BUG-24). Track buffer-flow for the "device
            // removed → buffers stop" watchdog, but track actual SIGNAL separately.
            self.lastSysLevelAt = Date()
            if v >= Self.silenceThreshold {
                self.lastSysSignalAt = Date()
                self.lastSysRealSignalAt = Date()   // BUG-28:重建不會重設這個,才算得準「真的安靜多久」
                self.sysAutoRebuildCount = 0   // reset the cap on real signal, not on silent buffers
                self.silentSysWarned = false   // re-arm: if it dies again later, warn again
                // BUG-28/B2(Eric 2026-09-17):對方軌恢復真訊號 → 自動收起「沒收到聲音」
                // 類的橫幅(其他警示與對方軌無關,不動)。收起過一次就進再跳觀察期。
                if self.warning?.clearsWhenSysSignalReturns == true {
                    self.warning = nil
                    self.sysWarningAutoDismissed = true
                }
            } } }
        mic.onLevel = { [weak self] v in Task { @MainActor in
            guard let self else { return }
            self.youLevel = v; self.micPeak = max(self.micPeak, v)
            if self.micSpeech.observe(level: v, at: self.elapsed) { self.speechSinceTick = true }   // CAL-09
            // Buffers are flowing → the tap is alive. Mark liveness. AUD-38:連續重建計數只在 buffer
            // **連續**流動 ≥10 秒才歸零(不再每個 buffer 就歸零,否則「建起來流 1 秒又死」永遠碰不到上限);
            // 跟上一個 buffer 隔超過「判死」門檻＝流動中斷過,連續流動從這個 buffer 重新起算。
            let now = Date()
            if self.micFlowSince == nil || now.timeIntervalSince(self.lastMicLevelAt) > MicWatchdogPolicy.deadAfter {
                self.micFlowSince = now
            }
            self.lastMicLevelAt = now
            if MicWatchdogPolicy.shouldResetCount(flowSince: self.micFlowSince, now: now) { self.micAutoRebuildCount = 0 } } }
        // Gate the live transcriber on the recorder's pause flag too, so pausing
        // also stops transcribing (otherwise paused speech is still transcribed
        // and the transcript timeline drifts from the saved audio).
        system.onBuffer = { b in
            recorder.feedSystem(b)
            if liveOn, !recorder.isPaused { live.appendSystem(b) }
        }
        mic.onBuffer = { b in
            recorder.feedMic(b)
            if liveOn, !recorder.isPaused { live.appendMic(b) }
        }

        // #949 REC-33:錄音寫檔失敗不再被吞——第一次失敗經 lastError 回 UI 橫幅/CLI。
        recorder.onError = { [weak self] err in
            Task { @MainActor in self?.lastError = "錄音寫檔失敗:\(err)(之後的音訊可能沒存到,請停止後檢查檔案)" }
        }
        do {
            try recorder.start(url: audioURL)   // #949:寫 inprogress,停止時才發布到頂層 `url`
            // AUD-38:麥克風非阻塞啟動,失敗在 completion 回報(不擋 system.start)。沒選裝置時解析成系統預設
            // 那一顆,預設輸入是藍牙也能起 HFP 保持器。上面 stopMicMonitor() 也是非阻塞:monitor 已立刻靜音,
            // 與錄音引擎可能短暫並存(macOS 允許同一顆麥多個客戶端)。
            // AUD-38 F1:開錄的 start 也算「切換中」——藍牙裝置要等保持器＋建引擎好幾秒,期間看門狗不計時、
            // 無聲警告不判,否則 3 秒就被當成死引擎重建。
            let dev: AudioInputDevice?
            if let sel = selectedInputDevice {
                dev = sel
            } else {
                // AUD-39:只有沒選裝置時才在 main 查一次系統預設輸入,記耗時。
                let t0 = Date()
                dev = AudioDevices.defaultInputDevice()
                os_log("MyParrot mic: 開錄未選裝置,查系統預設輸入 %ldms", Int(Date().timeIntervalSince(t0) * 1000))
            }
            isSwitchingMic = true
            micSwapGeneration += 1
            let gen = micSwapGeneration
            scheduleSwitchTimeout(gen)
            mic.start(deviceID: dev?.id, isBluetooth: dev?.isBluetooth ?? false) { [weak self] error in
                Task { @MainActor in
                    // 不用 stop 這個引擎:它就是 self.mic,停錄的 stop() 會處理。
                    guard let self, gen == self.micSwapGeneration,
                          self.state == .recording || self.state == .paused else { return }
                    if let error {
                        self.lastError = "麥克風啟動失敗：\(error)"
                        self.finishMicSwitch(succeeded: false)
                    } else {
                        self.finishMicSwitch(succeeded: true)
                    }
                }
            }
            // AUD-39:對方軌 tap 非阻塞啟動(may fail without audio-capture permission — 失敗在 completion 回報,不擋錄音)。
            // G4:開錄這次 start 也算「對方軌重建中」——看門狗不觸發、有 20 秒逾時。
            isRebuildingSys = true
            sysRebuildGeneration += 1
            let sysGen = sysRebuildGeneration
            scheduleSysRebuildTimeout(sysGen)
            system.start { [weak self] error in
                Task { @MainActor in
                    guard let self, sysGen == self.sysRebuildGeneration else { return }
                    self.isRebuildingSys = false
                    if let error {
                        self.lastError = "系統音訊擷取啟動失敗：\(error)"
                    } else {
                        self.lastSysLevelAt = Date(); self.lastSysSignalAt = Date()   // 同 finishSystemRebuild
                    }
                }
            }
        } catch {
            lastError = "\(error)"
        }
        if liveTranscribeEnabled { live.start(locale: resolvedLocale) }
        cancelWhisperUnload()   // TR-27:錄音中(即時逐字稿)不釋放模型

        accumulated = 0
        startDate = date
        state = .recording
        beginRecordingActivity()   // BUG-30:從這裡到 stop() 不讓系統閒置睡眠
        startTicker()
        markerCount = 0
        startOwnerTimer()          // #949:租約心跳＋GUI owner 寫 state.json(錄音＋暫停期間都跑)
        writeOwnerState()
    }

    public func pause() {
        guard state == .recording else { return }
        accumulated += Date().timeIntervalSince(startDate)
        elapsed = accumulated
        recorder.isPaused = true
        state = .paused
        stopTicker()
        writeOwnerState()          // #949:狀態變化當下就寫,不等 0.5 秒
    }

    public func resume() {
        guard state == .paused else { return }
        startDate = Date()
        recorder.isPaused = false
        state = .recording
        startTicker()
        writeOwnerState()
    }

    public func stop() {
        guard state == .recording || state == .paused else { return }
        if state == .recording { accumulated += Date().timeIntervalSince(startDate) }
        stopTicker()
        endRecordingActivity()     // BUG-30
        sysRebuildGeneration += 1; isRebuildingSys = false   // AUD-39:在飛的對方軌重建結果作廢
        system.stop()              // AUD-39:非阻塞,當下靜音
        // AUD-38:切換中途停錄 ⇒ 遞增世代,晚到的 start completion 會把它的新引擎 stop 掉、不得換掉 `mic`。
        micSwapGeneration += 1; isSwitchingMic = false; micFlowSince = nil
        inflightMics.forEach { $0.stop() }; inflightMics.removeAll()   // AUD-38 F5
        mic.stop()
        live.stop()
        recorder.stop()
        otherLevel = 0; youLevel = 0

        // #949 REC-31:recorder 已 finalize ⇒ inprogress 原子發布到頂層 → 刪 inprogress 目錄 → 釋放租約。
        // 發布失敗:租約照放、檔案留在 inprogress 給收割規則復原(lastError 已設),這裡不建列表項。
        lastStoppedRecordingID = nil
        if let url = publishAndEndLease() {
            // 標題用檔名主幹(含日期時間、可能帶「 2」後綴),與 loadRecordings 重掃後一致——
            // 原本只放「錄音」,列表同時出現「錄音」與「2026-08-23 2228 錄音」兩種寫法。
            let rec = Recording(id: recordingIDs[url] ?? UUID(),
                                title: url.deletingPathExtension().lastPathComponent,
                                url: url, date: startDate, duration: accumulated,
                                hasTranscript: false,
                                isConverting: url.pathExtension == "caf")
            recordingIDs[url] = rec.id   // #949:監看重掃列表時沿用同一個 id(選取/轉檔回寫都靠它)
            recordings.insert(rec, at: 0)
            lastStoppedRecordingID = rec.id
            // #2483 C(TRX-01):停止當下先把即時稿落檔,不管後面重不重轉、重轉成不成功,永遠有一份稿。
            let finalLines = liveTranscript.filter(\.isFinal)
            if !finalLines.isEmpty {
                writeTranscriptSidecar(finalLines, for: rec)
                recordings[0].hasTranscript = true
                liveSidecarStems.insert(SidecarSet.stem(of: rec.url))   // 發布後的頂層路徑(#949 inprogress 之後 url 是暫存)
                transcriptSource = rec
            }
            convertToM4A(rec, autoTranscribe: transcribePolicy == .immediately)
            // #2483 E(TRX-07):閒置時才重轉 ⇒ 先進待轉清單,列表標「待高精度重轉」,每 30 秒看一次條件。
            if transcribePolicy == .whenIdle, engine == .whisperKit {
                pendingHighAccuracy.insert(rec.id)
                startIdleTranscribeTimer()
            }
        }
        state = .finished
        scheduleWhisperUnload()   // TR-27:停止錄音後開始計閒置
    }

    /// After stopping, convert the lossless CAF into a compact .m4a and drop the CAF.
    /// The main file is ALWAYS the untouched original. If AEC is on, additionally
    /// produce a separate `…_aec.m4a` (non-destructive) — so a bad AEC run can never
    /// damage or lose the real recording (see PRD「AEC 追查」: offline AEC currently
    /// can't reach the real 44–165ms echo delay; kept opt-in + non-destructive).
    func convertToM4A(_ rec: Recording, autoTranscribe: Bool = false) {
        let caf = rec.url
        guard caf.pathExtension == "caf" else { return }
        // #949:本進程正在轉的 caf(loadRecordings 重掃時顯示「處理中」,不當成殘檔)。
        guard !activeConversions.contains(caf) else { return }
        activeConversions.insert(caf)
        if let i = recordings.firstIndex(where: { $0.id == rec.id }) {
            recordings[i].isConverting = true
            recordings[i].needsManualRepair = false
        }
        // Guard empty/instant recordings: AVAssetExportSession fails with -11800 on a
        // ~0-frame CAF(轉檔會一直失敗、列表留一筆永遠「處理中」)。
        // #949 REC-33:以前這裡直接 removeItem——別的進程正在寫的活檔被誤判成空檔時就這樣不見了。
        // 現在搬到 `.myparrot/quarantine/` 並回錯誤(UI 橫幅/CLI exit 4),不刪。
        let frames = (try? AVAudioFile(forReading: caf))?.length ?? 0
        if ConversionPolicy.decide(frames: frames) == .quarantine {
            activeConversions.remove(caf)
            do {
                _ = try ConversionPolicy.quarantine(caf, dir: caf.deletingLastPathComponent())
                lastError = ConversionPolicy.quarantineMessage(frames: frames)
            } catch {
                lastError = ConversionPolicy.quarantineMessage(frames: frames) + "(搬移失敗,檔案留在原處:\(error))"
            }
            recordings.removeAll { $0.id == rec.id }
            transcribeQueued.remove(rec.id)
            return
        }
        let m4a = caf.deletingPathExtension().appendingPathExtension("m4a")
        let doAEC = aecEnabled
        Task {
            defer { activeConversions.remove(caf) }
            do {
                // 1) Always export the untouched original first.
                try await AudioExport.toM4A(from: caf, to: m4a)
                recordingIDs[m4a] = rec.id   // #949:caf→m4a 換檔後重掃列表仍是同一列
                if let i = recordings.firstIndex(where: { $0.id == rec.id }) {
                    recordings[i].url = m4a
                    recordings[i].isConverting = false
                    recordings[i].needsManualRepair = false
                }
                // 2) If AEC is on, produce a SEPARATE …_aec.m4a from a copy; the
                //    original m4a above is preserved either way. cleanEcho returns
                //    false (writes nothing) when no echo is detected (headphones) —
                //    then we skip the _aec file entirely so a clean track isn't doubled.
                if doAEC {
                    let dir = caf.deletingLastPathComponent()
                    let stem = caf.deletingPathExtension().lastPathComponent
                    let aecCaf = dir.appendingPathComponent(stem + "_aec.caf")
                    let aecM4a = dir.appendingPathComponent(stem + "_aec.m4a")
                    let echoFound = try await Task.detached(priority: .utility) {
                        try EchoCleanup.cleanEcho(from: caf, to: aecCaf)   // heavy DSP off main actor
                    }.value
                    if echoFound {
                        try await AudioExport.toM4A(from: aecCaf, to: aecM4a)
                        try? FileManager.default.removeItem(at: aecCaf)
                        loadRecordings()   // surface the new _aec file in the list
                    }
                }
                try? FileManager.default.removeItem(at: caf)
                // Phase C(TR-19):剛錄完的檔自動跑高精度重轉(僅 Whisper 引擎可用
                // 且來自「停止錄音」路徑——resumePendingConversions 不觸發,避免
                // 每次啟動無預警吃 CPU)。
                // 轉檔中按過 ⌘T 的 → 現在補跑(與自動高精度二擇一,同一筆不跑兩次)。
                // 若此刻另一筆正在轉,transcribe() 會把它留在佇列、轉完再 drain。
                let queued = transcribeQueued.contains(rec.id)
                if (queued || (autoTranscribe && whisperEngine != nil)),
                   let i = recordings.firstIndex(where: { $0.id == rec.id }) {
                    transcribeQueued.remove(rec.id)
                    transcribe(recordings[i])
                }
            } catch {
                lastError = "轉 m4a 失敗:\(error)"
                transcribeQueued.remove(rec.id)
                if let i = recordings.firstIndex(where: { $0.id == rec.id }) {
                    recordings[i].isConverting = false
                    recordings[i].needsManualRepair = true   // #949:caf 留著,列表標未完成(手動修復)
                }
            }
        }
    }

    /// #949 REC-32 改寫:舊版「頂層看到 .caf 就轉(轉完刪 caf)」會把別的進程正在寫的活檔轉掉再刪——
    /// 這是 GUI×CLI 毀檔的真兇。現在頂層 `.caf` 只讀不動(loadRecordings 標 `needsManualRepair`,
    /// 24 小時後才給手動「修復」);只收割 `.myparrot/inprogress/` 裡租約已死的那幾場(規則見 `ReapPolicy`)。
    private func resumePendingConversions() {
        reapInprogress()
    }

    public func newRecording() {
        currentTitle = ""
        elapsed = 0
        liveTranscript = []
        state = .idle
    }

    // MARK: - Per-recording actions

    /// 轉檔(caf→m4a)還沒完成時就按了轉逐字稿的那幾筆——轉檔完成後自動接著轉稿。
    /// BUG(Eric 2026-08-23 22:52 截圖):停止錄音後立刻 ⌘T,transcribe 拿到的還是 .caf,
    /// 轉檔結束會把 caf 刪掉 → SpeechAnalyzer 讀到一半檔案消失,
    /// `com.apple.coreaudio.avfaudio 2003334207('wht?')`。
    public private(set) var transcribeQueued: Set<UUID> = []
    /// UI-33(Eric 2026-08-24):正在轉逐字稿的那一筆——列表列就地顯示狀態
    /// (訊息跟著主體,不再放逐字稿區頂端)。
    public private(set) var transcribingID: UUID? = nil

    // MARK: - #2411 BUG-30 錄音/轉稿中不讓系統閒置睡眠
    /// 錄音(含暫停)與檔案轉稿各持一個 activity token;結束/失敗一律 end。只擋系統閒置
    /// 睡眠,不擋螢幕變暗。長會議沒人碰鍵盤時,沒有這個會被安靜地切斷(Shiyin 研究 A)。
    private var recordingActivity: NSObjectProtocol?
    private var transcribeActivity: NSObjectProtocol?
    private func beginRecordingActivity() {
        guard recordingActivity == nil else { return }
        recordingActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                                  reason: "MyParrot recording")
    }
    private func endRecordingActivity() {
        if let a = recordingActivity { ProcessInfo.processInfo.endActivity(a) }
        recordingActivity = nil
    }
    private func beginTranscribeActivity() {
        guard transcribeActivity == nil else { return }
        transcribeActivity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated],
                                                                   reason: "MyParrot transcription")
    }
    private func endTranscribeActivity() {
        if let a = transcribeActivity { ProcessInfo.processInfo.endActivity(a) }
        transcribeActivity = nil
    }
    /// 給 SelfTest/CLI 看的狀態(不暴露 token)。
    public var isHoldingSleepAssertion: Bool { recordingActivity != nil || transcribeActivity != nil }

    // MARK: - #2417 逐字稿校正層(狀態;流程在 RecordingController+Correction.swift)

    /// 後端選單(CORR-01):鍵不存在＝關閉。關閉時整個校正模組不建立、不 spawn 任何行程。
    /// #2438 MDL-02:讀寫改走登錄表的 `model.correction`(舊鍵 `correctionBackend` 不再寫、也不刪)。
    /// 保留 stored property(SwiftUI 觀察行為不變);值沒變不寫。
    public var correctionBackend: CorrectionBackend = .off {
        didSet {
            guard correctionBackend != oldValue else { return }
            Self.saveCorrectionBackend(correctionBackend, defaults: defaults)
        }
    }
    /// MDL-02 純函式(SelfTest 用獨立 suite 驗,不碰真偏好):啟動時的初值＝先遷移舊鍵,再依登錄表解析。
    public nonisolated static func loadCorrectionBackend(defaults: UserDefaults) -> CorrectionBackend {
        ModelBackendRegistry.migrateLegacyKeys(defaults: defaults)
        return CorrectionBackend(rawValue: ModelBackendRegistry.selected(for: .correction, defaults: defaults).id) ?? .off
    }
    /// MDL-02 純函式:寫 `model.correction`(本建置不提供的後端 ⇒ 寫 off)。
    public nonisolated static func saveCorrectionBackend(_ backend: CorrectionBackend, defaults: UserDefaults) {
        ModelBackendRegistry.select(backend.rawValue, for: .correction, defaults: defaults)
    }
    /// CORR-14:指定 `--model` 檔位;空字串＝跟 CLI 預設走。
    public var correctionModel: String = "" {
        didSet { defaults.set(correctionModel, forKey: "correctionModel") }
    }
    /// #2418 CDX-08:Codex CLI 的 `-m` 檔位(校正與會議記錄共用,與 Claude 的欄位分開——兩家檔名不同);空字串＝跟 CLI 預設走。
    public var codexModel: String = "" {
        didSet { defaults.set(codexModel, forKey: "codexModel") }
    }
    /// 畫面上這份逐字稿屬於哪一筆錄音(轉稿成功或從 .srt 載入時設定);校正改寫 sidecar 用。
    public internal(set) var transcriptSource: Recording?
    public internal(set) var correctionSuggestions: [PendingCorrection] = []
    public internal(set) var isCheckingTranscript = false
    public internal(set) var lastCorrectionUsage: CorrectionUsage?
    /// 測試注入(假 CLI 腳本/假供應商);nil＝依 `correctionBackend` 組。
    public var correctionProviderOverride: (any CorrectionProvider)?

    /// #1697(Eric 2026-09-18 題 B 選 2):上次被「轉稿中退出」中斷的那幾筆。
    /// 只做標記**不自動重轉**——重轉要整段重跑(whisper 沒有續傳),什麼時候花
    /// 這個時間由使用者決定。存的是檔案路徑,重開後對照現況修剪。
    public private(set) var interruptedTranscripts: Set<URL> = []
    private static let interruptedKey = "interruptedTranscripts"

    /// 純函式:退出前要不要先問使用者(轉稿中或還有排隊的都算)。
    public nonisolated static func shouldConfirmQuitDuringTranscription(isTranscribing: Bool, queuedCount: Int) -> Bool {
        isTranscribing || queuedCount > 0
    }

    /// 純函式:存下來的路徑 vs 現況 → 還該留著的路徑。
    /// 檔案不在了、或那筆已經有逐字稿了 ⇒ 標記沒有意義,清掉不留孤兒。
    nonisolated static func pruneInterrupted(saved: [String], stillPending: (String) -> Bool) -> [String] {
        Array(Set(saved.filter(stillPending))).sorted()
    }

    private func loadInterrupted() {
        let saved = defaults.stringArray(forKey: Self.interruptedKey) ?? []
        let kept = Self.pruneInterrupted(saved: saved) { path in
            let url = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { return false }
            let txt = url.deletingPathExtension().appendingPathExtension("txt")
            return !FileManager.default.fileExists(atPath: txt.path)
        }
        interruptedTranscripts = Set(kept.map { URL(fileURLWithPath: $0) })
        if kept.count != saved.count { defaults.set(kept, forKey: Self.interruptedKey) }
    }

    private func saveInterrupted() {
        defaults.set(interruptedTranscripts.map(\.path).sorted(), forKey: Self.interruptedKey)
    }

    /// 退出流程確認「中斷並離開」後呼叫:把正在轉與排隊中的那幾筆記下來。
    public func markTranscriptionsInterrupted() {
        var urls: [URL] = []
        if let id = transcribingID, let rec = recordings.first(where: { $0.id == id }) { urls.append(rec.url) }
        for id in transcribeQueued {
            if let rec = recordings.first(where: { $0.id == id }) { urls.append(rec.url) }
        }
        guard !urls.isEmpty else { return }
        interruptedTranscripts.formUnion(urls)
        saveInterrupted()
    }

    /// 這筆轉完了(或檔案沒了)⇒ 標記功成身退。
    private func clearInterrupted(_ url: URL) {
        guard interruptedTranscripts.contains(url) else { return }
        interruptedTranscripts.remove(url)
        saveInterrupted()
    }

    /// 這筆上次有沒有被中斷過(UI 顯示「上次未完成」用)。
    public func wasInterrupted(_ rec: Recording) -> Bool {
        interruptedTranscripts.contains(rec.url) && !rec.hasTranscript
    }

    public func transcribe(_ rec: Recording) {
        // UI-33 二審:同一筆已在轉 → 忽略(否則會排進佇列,轉完又原樣重轉一次)。
        guard transcribingID != rec.id else { return }
        // 忙碌中(另一筆在轉)或檔案還在轉檔 → 排隊;轉完/轉檔完由 drainTranscribeQueue
        // 接手(v0.3.0 GPT 二審:原本 isTranscribing 時直接 return,排隊的那筆會永久遺失)。
        if isTranscribing || rec.isConverting || rec.url.pathExtension == "caf" {
            transcribeQueued.insert(rec.id)
            lastError = nil
            return
        }
        lastError = nil
        isTranscribing = true
        transcribingID = rec.id
        beginTranscribeActivity()   // BUG-30:轉稿中不讓系統閒置睡眠
        cancelWhisperUnload()   // TR-27:轉稿期間不釋放模型
        Task {
            // 二審(both):狀態清理集中 defer——日後任何分支提早 return 也不會留下
            // 永久「轉稿中」;isTranscribing/transcribingID 兩份狀態永遠成對清。
            defer {
                isTranscribing = false
                transcribingID = nil
                endTranscribeActivity()   // BUG-30:成功/失敗都解除
                drainTranscribeQueue()
                // TR-27:這一輪結束就排閒置釋放;drain 若接了下一筆,那筆的
                // cancelWhisperUnload() 會把這個排程蓋掉,不會誤釋放。
                scheduleWhisperUnload()
            }
            do {
                let raw = try await fileTranscriber.transcribeFile(rec.url, locale: resolvedLocale)
                // #2483 C(TRX-02/03):重轉前把即時稿另存 .live.srt(只對這個進程停止時落檔的那份),
                // 再把會中接受的校正重套到新稿;沒接回的只提示一次、不擋。
                let stem = SidecarSet.stem(of: rec.url)
                if liveSidecarStems.contains(stem) {
                    let srt = SidecarSet.url(stem: stem, ext: "srt"), live = TranscriptHandoff.liveURL(stem: stem)
                    if FileManager.default.fileExists(atPath: srt.path), !FileManager.default.fileExists(atPath: live.path) {
                        try? FileManager.default.copyItem(at: srt, to: live)
                    }
                    liveSidecarStems.remove(stem)
                }
                var lines = raw
                let accepted = TranscriptHandoff.load(stem: stem)
                if !accepted.isEmpty {
                    let r = TranscriptHandoff.reapply(accepted, to: raw)
                    lines = r.lines
                    if r.unmatched > 0 { lastError = "\(r.unmatched) 則校正沒接回高精度稿(原文找不到)" }
                }
                liveTranscript = lines
                transcriptVersion += 1
                transcriptSource = rec            // #2417:校正層要知道這份稿屬於哪筆
                correctionSuggestions = []
                if let idx = recordings.firstIndex(of: rec) { recordings[idx].hasTranscript = true }
                writeTranscriptSidecar(lines, for: rec)
                clearInterrupted(rec.url)       // #1697:轉完了,「上次未完成」標記清掉
            } catch {
                lastError = "轉逐字稿失敗:\(error)"
            }
        }
    }

    /// 佇列裡第一筆「已轉檔完成」的錄音接著轉;其餘留著等各自的轉檔完成。
    private func drainTranscribeQueue() {
        guard !isTranscribing else { return }
        for id in transcribeQueued {
            if let rec = recordings.first(where: { $0.id == id }), !rec.isConverting, rec.url.pathExtension != "caf" {
                transcribeQueued.remove(id)
                transcribe(rec)
                return
            }
        }
    }

    // MARK: - Internals

    private func startTicker() {
        ticker?.invalidate()
        ticker = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                self.elapsed = self.accumulated + Date().timeIntervalSince(self.startDate)
                // AUD-28 / BUG-18 liveness watchdog: buffers stopped flowing (mic.onLevel
                // went stale) → the engine/route died and AVAudioEngine didn't recover.
                // Auto-rebuild on the current device (capped consecutive attempts, each on
                // a cooldown) so 你軌 comes back without the user manually switching mics.
                // AUD-38:切換中不計時、被震盪鎖住不重建(門檻見 MicWatchdogPolicy)。
                let now = Date()
                if MicWatchdogPolicy.shouldRebuild(sinceLastBuffer: now.timeIntervalSince(self.lastMicLevelAt),
                                                   count: self.micAutoRebuildCount,
                                                   sinceLastRebuild: now.timeIntervalSince(self.lastMicRebuildAt),
                                                   switching: self.isSwitchingMic, locked: self.micLockedUID != nil) {
                    self.micAutoRebuildCount += 1
                    self.lastMicRebuildAt = now
                    self.rebuildCurrentMic(reason: .signalLost)
                }
                // BUG-22/BUG-24:對方(系統音訊)tap 看門狗。兩種死法都補救:
                //   ① buffer 停止流動(裝置移除、開錄瞬間 system.start() 靜默拋錯)
                //   ② buffer 仍在流但持續全零(BUG-24:藍牙 HFP 路由,tap 送數位零)
                // ①用 buffer 新鮮度、②用「訊號」新鮮度。②門檻較寬(20s)避免自然
                // 對話停頓誤觸;HFP 情境重建救不回聲音(下方警告才是主力),但對「裝置
                // glitch 送零」這種非 HFP 的死法,上限內重建仍可能救活。
                let sysBufferStaleFor = now.timeIntervalSince(self.lastSysLevelAt)
                let sysSilentFor = now.timeIntervalSince(self.lastSysSignalAt)
                if SysTrackWatchdog.shouldRebuild(
                        bufferStaleFor: sysBufferStaleFor, silentFor: sysSilentFor,
                        rebuildCount: self.sysAutoRebuildCount,
                        sinceLastRebuild: now.timeIntervalSince(self.lastSysRebuildAt),
                        deadAfter: Self.sysDeadAfter, silentAfter: Self.sysSilentRebuildAfter,
                        cooldown: Self.sysRebuildCooldown, maxRebuilds: Self.sysMaxConsecutiveRebuilds,
                        rebuilding: self.isRebuildingSys) {
                    // AUD-40(BUG-36)＋題 P1:不論 buffer 停流還是持續無聲,先查輸出裝置在不在跑——
                    // 閒置(沒聲音在播)時 tap 本來就不送 buffer／只有零值,不算 tap 死。
                    self.checkOutputThenRebuild(reason: sysBufferStaleFor > Self.sysDeadAfter
                        ? .signalLost : .persistentSilence)
                }
                // After 8s, if your mic still hasn't picked up anything, warn — your
                // voice channel is dead (usually the wrong input device is selected).
                // AUD-38:切換中不判;切換成功後再給 8 秒緩衝(micSilenceGraceUntil)。
                if self.elapsed > 8, self.micPeak < Self.silenceThreshold, !self.silentMicWarned,
                   !self.isSwitchingMic, now >= self.micSilenceGraceUntil {
                    self.silentMicWarned = true
                    self.warning = self.selectedInputDevice?.isBluetooth == true
                        ? .micSilentBluetooth : .micSilent
                }
                // 對方軌死聲道警告。BUG-24 前這裡用整場單調的 `sysPeak`,開頭只要有
                // 一瞬間收到聲就永久壓過門檻、「中途才死」偵測不到(BUG-24 實例:開頭 1 分鐘
                // 有聲、之後 31 分鐘全零卻整場無警告)。改看「距最後一次真訊號多久」,
                // 中途死也能觸發,且 onLevel 收到訊號會 re-arm `silentSysWarned`。
                // BUG-28/題 C:自動收起過一次之後,同一場要連續安靜 60 秒才再跳
                // (實測一般會議每 3~5 分鐘就有一次 12 秒以上的自然停頓,照 12 秒
                // 會一直閃)。用不受 tap 重建重設的 lastSysRealSignalAt 才算得準。
                let silentInputs = SysTrackWatchdog.silentWarnInputs(
                    autoDismissed: self.sysWarningAutoDismissed,
                    silentFor: sysSilentFor,
                    realSilentFor: now.timeIntervalSince(self.lastSysRealSignalAt),
                    warnAfter: Self.sysSilentWarnAfter, rewarnAfter: Self.sysSilentRewarnAfter)
                if SysTrackWatchdog.shouldWarnSilent(
                        elapsed: self.elapsed, silentFor: silentInputs.silentFor,
                        alreadyWarned: self.silentSysWarned, warnAfter: silentInputs.warnAfter) {
                    self.silentSysWarned = true
                    self.warning = .sysSilent
                }
                // CAL-08(G1):起錄 3 分鐘內某軌從頭到尾無訊號 → 通知(每軌一次)。「從頭到尾」＝該軌開錄以來的最大值仍在死軌門檻下。
                if DeadTrackRule.shouldAlarm(elapsed: self.elapsed, everHadSignal: self.micPeak > Self.silenceThreshold,
                                             alreadyAlarmed: self.micDeadAlarmed, after: self.deadTrackAlarmAfter) {
                    self.micDeadAlarmed = true; self.deadTrackAlarms.append(.mic); self.onDeadTrackAlarm?(.mic)
                }
                if DeadTrackRule.shouldAlarm(elapsed: self.elapsed, everHadSignal: self.sysPeak > Self.silenceThreshold,
                                             alreadyAlarmed: self.sysDeadAlarmed, after: self.deadTrackAlarmAfter) {
                    self.sysDeadAlarmed = true; self.deadTrackAlarms.append(.system); self.onDeadTrackAlarm?(.system)
                }
                // CAL-11(C2):兩軌連續 30 分鐘沒人說話 → 建議停(只提醒;再有人說話會重新武裝)。暫停時 ticker 不跑、elapsed 不走,自然不計。
                let spoke = self.speechSinceTick
                self.speechSinceTick = false
                if self.silenceRule.observe(anySpeech: spoke, at: self.elapsed) {
                    self.silenceStopSuggestedAt = Date()
                    self.onSilenceStopSuggested?()
                }
            }
        }
    }

    private func stopTicker() { ticker?.invalidate(); ticker = nil }

    /// One-time move of recordings from the old ~/Library/Application Support location
    /// to the new visible default. Skips files that already exist at the target.
    private func migrateLegacyRecordings(into target: URL) {
        let appSup = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let legacy = appSup.appendingPathComponent("MyParrot/Recordings", isDirectory: true)
        guard legacy.standardizedFileURL != target.standardizedFileURL,
              let files = try? FileManager.default.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)
        else { return }
        for f in files where ["m4a", "caf", "txt"].contains(f.pathExtension) {
            let dest = target.appendingPathComponent(f.lastPathComponent)
            if !FileManager.default.fileExists(atPath: dest.path) {
                try? FileManager.default.moveItem(at: f, to: dest)
            }
        }
    }

    func loadRecordings() {
        guard let urls = try? FileManager.default.contentsOfDirectory(at: recordingsDir,
                                                                      includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        recordings = urls.filter { ["m4a", "caf"].contains($0.pathExtension) }.compactMap { url in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let date = (attrs?[.modificationDate] as? Date) ?? Date()
            let txt = url.deletingPathExtension().appendingPathExtension("txt")
            // Recording length, read cheaply from the file header (0 if unreadable).
            let duration: TimeInterval = {
                guard let f = try? AVAudioFile(forReading: url), f.processingFormat.sampleRate > 0 else { return 0 }
                return Double(f.length) / f.processingFormat.sampleRate
            }()
            // UI-27 三鏡頭審:每次重掃都 mint 新 UUID 會讓 ForEach 把列當成新物件、
            // 丟掉列內 @State(拖曳中的 seek 位置);同一 URL 沿用同一個 id。
            let stableID = recordingIDs[url] ?? UUID()
            recordingIDs[url] = stableID
            // #949 REC-32:頂層 .caf 只有「本進程正在轉」的才算處理中;其餘是殘檔(舊版 writer 的活檔或中斷檔),
            // 只讀不動、標 needsManualRepair(不再自動轉)。
            let isCaf = url.pathExtension == "caf"
            let converting = isCaf && activeConversions.contains(url)
            return Recording(id: stableID, title: url.deletingPathExtension().lastPathComponent,
                             url: url, date: date, duration: duration,
                             hasTranscript: FileManager.default.fileExists(atPath: txt.path),
                             isConverting: converting, needsManualRepair: isCaf && !converting)
        }.sorted { $0.date > $1.date }
    }

    // MARK: - #2438 UI-53／UI-54 檔案面板:改名、移到垃圾桶
    // 檔案動作本體是 `SidecarSet` 的靜態函式(測試不必實例化本類別);這裡只負責鎖、收尾狀態、重掃列表。

    /// 同 stem 的所有衍生檔一起改名(`SidecarSet.renamePlan`＋`performRename`,中途失敗會回滾)。
    /// 錄音中/暫停中那場、轉檔中、轉稿中、排隊中、或正在「檢查逐字稿」的那筆 ⇒ 丟 `SidecarError.locked`。
    /// 播放中那筆先停播。成功後沿用同一個列 id(選取不跳)、改掉「上次未完成」與校正來源的舊路徑,再重掃列表。
    /// 回傳錄音檔的新 URL(App 層把筆記指過去;列 id 不保證沿用)。
    @discardableResult
    public func rename(_ rec: Recording, to title: String) throws -> URL {
        if sidecarLocked(rec) { throw SidecarError.locked }
        let stem = SidecarSet.stem(of: rec.url)
        let plan: [SidecarSet.Move]
        switch SidecarSet.renamePlan(stem: stem, newTitle: title) {
        case .failure(let e): throw e
        case .success(let p): plan = p
        }
        if playingURL == rec.url { stopPlayback() }
        try SidecarSet.performRename(plan)
        let newURL = plan.first(where: { $0.from == rec.url })?.to ?? rec.url
        if let audio = plan.first(where: { $0.from == rec.url }) {
            if let id = recordingIDs.removeValue(forKey: rec.url) { recordingIDs[audio.to] = id }
            if interruptedTranscripts.remove(rec.url) != nil {
                interruptedTranscripts.insert(audio.to)
                saveInterrupted()
            }
            if transcriptSource?.url == rec.url {
                transcriptSource?.url = audio.to
                transcriptSource?.title = audio.to.deletingPathExtension().lastPathComponent
            }
        }
        loadRecordings()
        return newURL
    }

    /// 同 stem 的所有衍生檔移到垃圾桶(`FileManager.trashItem`,可救回;絕不 `removeItem`)。
    /// 鎖的條件同 `rename`。播放中那筆先停播;若它是校正來源 ⇒ 清掉來源與建議(避免之後寫回已丟掉的檔)。
    public func trash(_ rec: Recording) throws {
        if sidecarLocked(rec) { throw SidecarError.locked }
        let urls = SidecarSet.trashPlan(stem: SidecarSet.stem(of: rec.url))
        guard !urls.isEmpty else { throw SidecarError.notFound }
        if playingURL == rec.url { stopPlayback() }
        try SidecarSet.performTrash(urls)
        recordingIDs.removeValue(forKey: rec.url)
        if interruptedTranscripts.remove(rec.url) != nil { saveInterrupted() }
        if transcriptSource?.url == rec.url {
            transcriptSource = nil
            correctionSuggestions = []
        }
        loadRecordings()
    }

    /// UI-53/54:這筆現在能不能改名／丟垃圾桶(給右鍵選單 disabled 用;report-M2 裁示 4)。
    public func isFileActionLocked(_ rec: Recording) -> Bool { sidecarLocked(rec) }

    /// 把控制器狀態換算成 `SidecarSet.isLocked` 的輸入。
    private func sidecarLocked(_ rec: Recording) -> Bool {
        let stemOf = { (id: UUID) in self.recordings.first(where: { $0.id == id }).map { SidecarSet.stem(of: $0.url) } }
        let recordingStem = (state == .recording || state == .paused) ? currentURL.map(SidecarSet.stem(of:)) : nil
        let converting = Set(recordings.filter { $0.isConverting || $0.url.pathExtension == "caf" }
                                       .map { SidecarSet.stem(of: $0.url) })
        let checking = isCheckingTranscript && transcriptSource?.url == rec.url
        return checking || SidecarSet.isLocked(stem: SidecarSet.stem(of: rec.url),
                                               recordingStem: recordingStem,
                                               transcribingStem: transcribingID.flatMap(stemOf),
                                               queuedStems: Set(transcribeQueued.compactMap(stemOf)),
                                               convertingStems: converting)
    }

    func writeTranscriptSidecar(_ lines: [TranscriptLine], for rec: Recording) {
        let base = rec.url.deletingPathExtension()
        let body = lines.map { "\($0.isYou ? "你" : "對方"): \($0.text)" }.joined(separator: "\n")
        try? body.write(to: base.appendingPathExtension("txt"), atomically: true, encoding: .utf8)
        // Timed SRT alongside the plain text (TR-12).
        try? SRT.make(from: lines).write(to: base.appendingPathExtension("srt"), atomically: true, encoding: .utf8)
    }

    private func installDeviceListener() {
        guard !deviceListenerInstalled else { return }
        deviceListenerInstalled = true
        var inputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID.system, &inputAddress, DispatchQueue.main) { [weak self] _, _ in
            Task { @MainActor in
                guard let self else { return }
                // Snapshot the device we're actually recording from BEFORE refreshDevices(),
                // which may re-point `selectedInputDevice` to a present device when the old
                // one's id is gone — that would hide the vanish from the check below.
                let recordingDevice = self.selectedInputDevice
                // AUD-39:清單在背景刷新;「錄音中的裝置消失了沒」要等新清單套用後(main)再判。
                self.refreshDevices { [weak self] in
                    guard let self, self.state == .recording else { return }
                    // If the device we were recording from just vanished, recover immediately
                    // onto a present device (don't wait for the 3s liveness watchdog) —
                    // rebuildCurrentMic resolves the now-updated selection/default (BUG-18 / AUD-28).
                    if let d = recordingDevice,
                       !self.availableInputDevices.contains(where: { $0.uid == d.uid }) {
                        self.rebuildCurrentMic(reason: .deviceRemoved, avoidDeviceID: d.id)   // AUD-39:等預設輸入換掉它
                    } else {
                        self.warning = .deviceChanged
                    }
                }
            }
        }
        // BUG-22:對方(系統音訊)tap 綁的是「錄音開始那一刻」的預設輸出裝置,
        // 完全沒監聽後續變化——實錄中 AirPods 錄音中途連上、預設輸出切走,
        // tap 繼續對著沒人在用的舊裝置錄,對方軌整段真靜音。加對稱的輸出
        // 裝置監聽,變了就立即重建 tap(不必等 watchdog 逾時)。
        var outputAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID.system, &outputAddress, DispatchQueue.main) { [weak self] _, _ in
            Task { @MainActor in
                guard let self, self.state == .recording else { return }
                // 審查發現:這條路徑原本完全繞過 watchdog 的節流,藍牙裝置握手
                // 期間常見連續幾次裝置變更通知,會無節流地反覆拆建真的 tap/
                // aggregate。跟 watchdog 共用同一組計數/冷卻,總重建次數才是
                // 真正有上限。
                let now = Date()
                guard !self.isRebuildingSys,   // AUD-39:重建中不再疊一次
                      now.timeIntervalSince(self.lastSysRebuildAt) > Self.sysRebuildCooldown,
                      self.sysAutoRebuildCount < Self.sysMaxConsecutiveRebuilds else { return }
                self.sysAutoRebuildCount += 1
                self.lastSysRebuildAt = now
                self.rebuildSystemCapture(reason: .outputDeviceChanged)
            }
        }
    }
}

/// BUG-24:對方(系統音訊)軌看門狗的**純決策邏輯**,抽出來讓 SelfTest 不必起真
/// timer/tap 就能驗(對照 BUG-24 前只看 buffer 到達、被藍牙 HFP「流動但全零」打穿
/// 的舊行為)。所有輸入都是「距某事件多久」的秒數,無副作用、與 @MainActor 狀態無關。
enum SysTrackWatchdog {
    /// 是否該跳對方軌「死聲道」警告:錄音已過起步期(>8s)、距最後一次**真訊號**
    /// 已超過門檻、且尚未警告過(警告 latch 在收到訊號時 re-arm)。用「距訊號多久」
    /// 而非整場單調 peak,才能偵測「開頭有聲、中途才死」(BUG-24 的實例)。
    static func shouldWarnSilent(elapsed: TimeInterval, silentFor: TimeInterval,
                                 alreadyWarned: Bool, warnAfter: TimeInterval) -> Bool {
        elapsed > 8 && silentFor >= warnAfter && !alreadyWarned
    }

    /// BUG-28/題 C:無聲警告該用哪組(距多久、門檻多久)。自動收起過一次之後改看
    /// 「距最後一次真訊號」(不被 tap 重建重設)與較長的再跳門檻;沒收起過就照舊。
    static func silentWarnInputs(autoDismissed: Bool, silentFor: TimeInterval,
                                 realSilentFor: TimeInterval,
                                 warnAfter: TimeInterval, rewarnAfter: TimeInterval)
        -> (silentFor: TimeInterval, warnAfter: TimeInterval) {
        autoDismissed ? (realSilentFor, rewarnAfter) : (silentFor, warnAfter)
    }

    /// BUG-28:重建對方軌之後要跳哪一條橫幅(nil=不跳)。
    /// ① 已武裝無聲警告 → 不宣稱成功的合併訊息(BUG-24 的取捨,維持原行為)。
    /// ② 再跳觀察期內、且這次重建是因為持續無聲 → 不跳(否則 20 秒的重建會蓋過
    ///    60 秒的再跳門檻)。
    /// ③ 其他(裝置移除、輸出裝置變更…) → 照舊報「已自動重新啟動」。
    static func rebuildBanner(silentWarned: Bool, reason: SysRebuildReason,
                              inRewarnGrace: Bool) -> RecordingWarning? {
        if silentWarned { return .sysRebuildMaybeStillSilent }
        if inRewarnGrace, reason == .persistentSilence { return nil }
        return .sysRestarted(reason: reason)
    }

    /// 是否該嘗試自動重建對方軌 tap:buffer 停止流動(裝置移除)**或**持續真靜音
    /// 太久(死/HFP tap 送全零),且未達連續重建上限、距上次重建已過冷卻。
    /// AUD-39 D(G4):對方軌 start／重建最多等多久(秒)。
    static let rebuildTimeout: TimeInterval = 20

    /// AUD-40(BUG-36):buffer 停流時該怎麼辦。
    enum StaleAction: Equatable { case skipIdle, rebuild }
    /// 輸出裝置沒在跑(false)＝沒聲音在播、tap 本來就不送 buffer ⇒ 略過;在跑(true)或讀不到(nil)⇒ 重建。
    static func staleAction(outputRunning: Bool?) -> StaleAction {
        outputRunning == false ? .skipIdle : .rebuild
    }

    static func shouldRebuild(bufferStaleFor: TimeInterval, silentFor: TimeInterval,
                             rebuildCount: Int, sinceLastRebuild: TimeInterval,
                             deadAfter: TimeInterval, silentAfter: TimeInterval,
                             cooldown: TimeInterval, maxRebuilds: Int, rebuilding: Bool) -> Bool {
        guard !rebuilding else { return false }   // AUD-39:重建中(tap 正在佇列上拆建)不再觸發
        return (bufferStaleFor > deadAfter || silentFor >= silentAfter)
            && rebuildCount < maxRebuilds
            && sinceLastRebuild > cooldown
    }
}
