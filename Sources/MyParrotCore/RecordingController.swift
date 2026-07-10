import Foundation
import Observation
import AudioToolbox
import AVFoundation
import Speech

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
    public var deviceChangeWarning: String?

    public var recordings: [Recording] = []
    public var liveTranscript: [TranscriptLine] = []
    public var isTranscribing = false
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
                deviceChangeWarning = "逐字稿引擎將於本次錄音結束後生效"
            } else {
                rebuildTranscribers()
            }
        }
    }
    /// Phase C(TR-19):錄音轉檔完成後自動用高精度引擎重轉——live 稿=會中參考,
    /// 檔案稿=記錄真相。預設開;Whisper 模型未安裝時自動略過。
    public var autoTranscribeAfterStop = true {
        didSet { defaults.set(autoTranscribeAfterStop, forKey: "autoTranscribe") }
    }
    public var liveTranscribeEnabled = true
    public var language: TranscriptionLanguage = .system { didSet { defaults.set(language.rawValue, forKey: "language") } }
    public var resolvedLocale: Locale { language.resolved() }

    // Playback (錄音檔列表)
    public var playingURL: URL?

    // Live mic monitor (設定裡即時收音測試)
    public var isMonitoring = false
    public var monitorLevel: Float = 0

    private let system = SystemAudioCapture()
    // `var` so the live mic engine can be swapped mid-recording (hot-swap, AUD-20).
    private var mic = MicCapture()
    private let monitor = MicCapture()
    private let recorder = StereoRecorder()
    // `var`:引擎可依設定切換(TR-14),rebuildTranscribers() 重建。
    private var fileTranscriber: any TranscriptionProvider
    private var live: any LiveTranscribing
    /// live+file 共用的 whisper context(單一模型載入一份)。
    private var whisperEngine: WhisperCppEngine?

    private var player: AVAudioPlayer?
    private var playbackTicker: Timer?
    private var startDate = Date()
    private var accumulated: TimeInterval = 0
    private var ticker: Timer?
    private var currentURL: URL?
    private var deviceListenerInstalled = false
    private let defaults = UserDefaults.standard
    // Peak levels seen this recording, to catch a dead channel live.
    private var micPeak: Float = 0
    private var sysPeak: Float = 0
    private var silentMicWarned = false
    /// Below this RMS a channel counts as "no signal". Shared by the live
    /// indicator and the 8-second dead-channel warning so they never disagree.
    private static let silenceThreshold: Float = 0.003
    /// AUD-28 / BUG-18 liveness watchdog. While the mic tap is delivering buffers,
    /// `mic.onLevel` fires ~12×/s — even during silence (level ≈ 0). So a *stale*
    /// timestamp means buffers stopped flowing = a dead engine/route, NOT a quiet user.
    /// We then auto-rebuild the mic (the recovery the user otherwise does by hand).
    private var lastMicLevelAt = Date()
    private var micAutoRebuildCount = 0
    private var lastMicRebuildAt = Date.distantPast
    private static let micDeadAfter: TimeInterval = 3        // no buffers this long → rebuild
    private static let micRebuildCooldown: TimeInterval = 2  // min gap between auto-rebuilds
    private static let micMaxConsecutiveRebuilds = 3         // give up & warn after this many failed in a row
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
    private static let sysSilentWarnAfter: TimeInterval = 12   // 持續無「訊號」這麼久 → 死聲道警告(可重新武裝)
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

    public init() {
        // Default to a visible folder the user can browse to; overridable in Settings.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let saved = UserDefaults.standard.string(forKey: "recordingsDir") {
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
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        migrateLegacyRecordings(into: recordingsDir)
        if let raw = UserDefaults.standard.string(forKey: "language"),
           let lang = TranscriptionLanguage(rawValue: raw) { language = lang }
        if UserDefaults.standard.object(forKey: "inputGain") != nil {
            inputGain = min(2.0, max(0.5, Float(UserDefaults.standard.double(forKey: "inputGain"))))
        }
        aecEnabled = UserDefaults.standard.bool(forKey: "aecSoftware")
        if UserDefaults.standard.object(forKey: "autoTranscribe") != nil {
            autoTranscribeAfterStop = UserDefaults.standard.bool(forKey: "autoTranscribe")
        }
        loadRecordings()
        resumePendingConversions()
        refreshDevices()
        installDeviceListener()
        live.onUpdate = { [weak self] lines in self?.liveTranscript = lines }
        if let note = built.note { deviceChangeWarning = note }
    }

    // MARK: - 逐字稿引擎建構(TR-14)

    private static func buildTranscribers(for engine: TranscriptionEngine)
        -> (live: any LiveTranscribing, file: any TranscriptionProvider,
            whisper: WhisperCppEngine?, note: String?) {
        switch engine {
        case .whisperKit:
            if let url = WhisperModelStore.activeModelURL() {
                let eng = WhisperCppEngine(modelURL: url)
                return (WhisperLiveTranscriber(engine: eng),
                        WhisperCppFileProvider(engine: eng), eng, nil)
            }
            let (l, f) = appleTranscribers()
            return (l, f, nil, "Whisper 模型未安裝 — 到設定下載後生效,暫用 macOS 原生引擎")
        case .cloud:
            // Phase B:CloudSTTAdapter 接線後替換此 fallback。
            let (l, f) = appleTranscribers()
            return (l, f, nil, "雲端引擎尚未設定,暫用 macOS 原生引擎")
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
            deviceChangeWarning = "逐字稿引擎將於本次錄音結束後生效"
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
        if let note = built.note { deviceChangeWarning = note }
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

    public func refreshDevices() {
        availableInputDevices = AudioDevices.inputDevices()
        // Keep a still-valid current selection — a manual choice (incl. a Bluetooth
        // mic for testing) or an in-session main-screen hot-swap is always respected.
        if let sel = selectedInputDevice, availableInputDevices.contains(where: { $0.id == sel.id }) { return }
        // No valid selection (e.g. fresh launch): the *Settings* choice wins. Restore
        // it by UID — the persistent default — and only soft-default if it's absent.
        if let uid = defaults.string(forKey: preferredInputUIDKey),
           let saved = availableInputDevices.first(where: { $0.uid == uid }) {
            selectedInputDevice = saved
            return
        }
        selectedInputDevice = autoSelectInput()
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
        let previous = selectedInputDevice
        selectedInputDevice = device
        // Idle/finished: nothing live to swap — the next startRecording() picks it up.
        guard state == .recording || state == .paused else { return }
        hotSwapMic(to: device, fallback: previous)
    }

    /// Swap the live mic engine to `device` WITHOUT stopping the recording. 對方 (system,
    /// left) keeps running uninterrupted; 你 (mic, right) gets a brief (~0.1–0.5s) silence
    /// while the new engine spins up — auto-aligned by StereoRecorder's silence padding,
    /// so the file stays one continuous, time-aligned stereo recording (AUD-20). On a
    /// fresh MicCapture instance to avoid stale AUHAL/format caching. Falls back to the
    /// previous device if the new one won't start, so 你 軌 is never silently lost (AUD-21).
    private func hotSwapMic(to device: AudioInputDevice, fallback: AudioInputDevice?) {
        let old = mic
        old.stop()
        // Re-arm the 8s dead-channel warning for BOTH outcomes: `old` is already stopped,
        // so micPeak must not keep the previous device's high value — otherwise the
        // silent-mic check never re-fires after a failed swap (AUD-22).
        micPeak = 0
        silentMicWarned = false
        let fresh = MicCapture()
        fresh.gain = inputGain
        fresh.onLevel = old.onLevel
        fresh.onBuffer = old.onBuffer
        do {
            try fresh.start(deviceID: device.id)
            mic = fresh
            deviceChangeWarning = "已切換麥克風為「\(device.name)」,你軌(右)會有短暫空白"
        } catch {
            // New device failed — fall back to the previous one so 你軌 isn't lost (AUD-21).
            let restore = MicCapture()
            restore.gain = inputGain
            restore.onLevel = old.onLevel
            restore.onBuffer = old.onBuffer
            if (try? restore.start(deviceID: fallback?.id)) != nil {
                mic = restore
                selectedInputDevice = fallback
                lastError = "切換到「\(device.name)」失敗,已沿用原麥克風:\(error)"
            } else {
                // BOTH the new device and the fallback failed to start: 你軌 is now dead.
                // Warn loudly (the old "已沿用原麥克風" text would be a lie) and restore the
                // device label so the picker matches reality (AUD-21/22).
                selectedInputDevice = fallback
                deviceChangeWarning = "⚠️ 切換到「\(device.name)」失敗、原麥克風也起不來,你軌(右)現在收不到音 — 請停止錄音、重選裝置再錄"
                lastError = "麥克風切換失敗,你軌已中斷:\(error)"
            }
        }
    }

    /// AUD-28 / BUG-18: rebuild the live mic on the *current* device WITHOUT a user-
    /// initiated switch — driven by the liveness watchdog (buffers stopped flowing) and by
    /// the device listener (the selected device vanished). Resolves the device by stable
    /// UID (the numeric id may have been reassigned on replug), falling back to the system
    /// default if the chosen device is gone. No fallback chain like hotSwapMic; if it fails
    /// the watchdog retries up to the consecutive cap, then the 8s warning fires.
    private func rebuildCurrentMic(reason: String) {
        let available = AudioDevices.inputDevices()
        let device = selectedInputDevice.flatMap { sel in available.first { $0.uid == sel.uid } }
                     ?? AudioDevices.defaultInputDevice()
        let old = mic
        old.stop()
        let fresh = MicCapture()
        fresh.gain = inputGain
        fresh.onLevel = old.onLevel
        fresh.onBuffer = old.onBuffer
        if (try? fresh.start(deviceID: device?.id)) != nil {
            mic = fresh
            if let device { selectedInputDevice = device }   // keep picker in sync if we fell back
            lastMicLevelAt = Date()
            deviceChangeWarning = "偵測到你的麥克風中斷(\(reason)),已自動重接「\(device?.name ?? "系統預設")」"
        } else {
            lastError = "麥克風自動重建失敗(\(reason)) — 將持續重試"
        }
    }

    /// BUG-22:對方(系統音訊)tap 的重建——比照 rebuildCurrentMic,但
    /// SystemAudioCapture 是原生 Core Audio tap+aggregate(非 AVAudioEngine),
    /// 沒有引擎自己停了的通知,靠這裡統一補:輸出裝置變更(installDeviceListener
    /// 立即觸發)或 buffer 停止流動(watchdog 逾時觸發)都走同一條路徑。
    /// stop()+start() 重用同一個 SystemAudioCapture 實例——tap/aggregate 每次
    /// start() 都建新 UUID(見 SystemAudioCapture.swift),可安全反覆重建,不必
    /// 像 MicCapture 那樣另開新實例。
    private func rebuildSystemCapture(reason: String) {
        system.stop()
        do {
            try system.start()
            // Give the rebuilt tap a fresh grace window before it can be judged
            // stale/silent again, so the bounded retries are spaced ~sysSilentRebuildAfter
            // apart (a fair recovery chance) instead of firing back-to-back (BUG-24).
            lastSysLevelAt = Date(); lastSysSignalAt = Date()
            // BUG-24:別用「已自動重新啟動」的成功語氣蓋掉稍早那句可行動的 HFP 提示。
            // 若這次重建是因「持續無聲」(silentSysWarned 已武裝),重建對 HFP 路由救不回
            // 聲音,誆稱「已重啟」會變成停到錄音結束的假安心;改成不宣稱成功的合併訊息。
            deviceChangeWarning = silentSysWarned
                ? "已嘗試自動重建對方軌,但可能仍收不到 — 若用藍牙耳機當輸出會走 HFP/電話模式而擷取不到,請改用內建喇叭或有線輸出"
                : "偵測到系統音訊擷取中斷(\(reason)),已自動重新啟動"
        } catch {
            lastError = "系統音訊自動重建失敗(\(reason)):\(error)"
        }
    }

    /// Soft-default the mic toward the most reliable source. Bluetooth forces
    /// narrowband HFP + gets grabbed by the meeting app (dead recording); iPhone
    /// Continuity drops mid-recording (research: not proven fixed even wired). So
    /// built-in/USB win over iPhone, and Bluetooth is last. Order:
    /// system default (if built-in/USB) → built-in → any built-in/USB → wired iPhone
    /// → any non-BT (wireless iPhone beats BT) → finally anything. Never hard-blocks —
    /// the user can still pick iPhone / Bluetooth manually (e.g. to test).
    private func autoSelectInput() -> AudioInputDevice? {
        func topReliable(_ d: AudioInputDevice) -> Bool { !d.isBluetooth && !d.isContinuity }
        let def = AudioDevices.defaultInputDevice()
        if let def, topReliable(def), let m = availableInputDevices.first(where: { $0.id == def.id }) { return m }
        if let builtIn = availableInputDevices.first(where: { $0.isBuiltIn && !$0.isBluetooth }) { return builtIn }
        if let usb = availableInputDevices.first(where: topReliable) { return usb }
        if let wiredPhone = availableInputDevices.first(where: { $0.isContinuityWired && !$0.isBluetooth }) { return wiredPhone }
        if let nonBT = availableInputDevices.first(where: { !$0.isBluetooth }) { return nonBT }
        return availableInputDevices.first   // only Bluetooth available — can't avoid it
    }

    // MARK: - Save directory (#6)

    public func setRecordingsDir(_ url: URL) {
        recordingsDir = url
        defaults.set(url.path, forKey: "recordingsDir")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        loadRecordings()
    }

    // MARK: - Playback (#2)

    public func togglePlay(_ rec: Recording) {
        if playingURL == rec.url { stopPlayback(); return }
        stopPlayback()
        do {
            let p = try AVAudioPlayer(contentsOf: rec.url)
            p.play()
            player = p
            playingURL = rec.url
            playbackTicker = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    if self.player?.isPlaying != true { self.stopPlayback() }
                }
            }
        } catch { lastError = "播放失敗:\(error)" }
    }

    public func stopPlayback() {
        player?.stop(); player = nil
        playbackTicker?.invalidate(); playbackTicker = nil
        playingURL = nil
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
        monitor.stop()
        monitor.gain = inputGain
        monitor.onLevel = { [weak self] v in Task { @MainActor in self?.monitorLevel = v } }
        do {
            try monitor.start(deviceID: selectedInputDevice?.id)
            isMonitoring = true
        } catch {
            // G-1 審查發現:若上面 start() 在 tap 已裝之後才失敗,`monitor` 帶著
            // 洩漏的 tap 進到這裡;`start()` 的 guard 只看 `isRunning`(此時仍
            // 是 false)擋不住重入,直接對同一顆 engine 的 bus 0 再裝一次 tap
            // 會撞 AVAudioEngine fatal exception(nullptr == Tap())。重試前先
            // stop() 讓 G-1 修好的 tapInstalled 清乾淨,同上面第一次嘗試前的
            // 防禦性 stop()。
            monitor.stop()
            // Retry on the system default device before giving up.
            do { try monitor.start(deviceID: nil); isMonitoring = true }
            catch { lastError = "麥克風測試失敗:\(error)" }
        }
    }

    public func stopMicMonitor() {
        monitor.stop(); isMonitoring = false; monitorLevel = 0
    }

    // MARK: - Controls

    public func startRecording() {
        guard state == .idle || state == .finished else { return }
        if needsEngineRebuild { rebuildTranscribers(); needsEngineRebuild = false }
        stopMicMonitor()   // free the mic before recording
        stopPlayback()
        let date = Date()
        let title = currentTitle.isEmpty ? "錄音" : currentTitle
        let url = recordingsDir.appendingPathComponent(Recording.fileName(date: date, title: title))
        currentURL = url

        liveTranscript = []
        deviceChangeWarning = nil
        lastError = nil
        micPeak = 0; sysPeak = 0; silentMicWarned = false; silentSysWarned = false
        lastMicLevelAt = Date(); micAutoRebuildCount = 0; lastMicRebuildAt = .distantPast
        lastSysLevelAt = Date(); lastSysSignalAt = Date(); sysAutoRebuildCount = 0; lastSysRebuildAt = .distantPast
        mic.gain = inputGain

        // Capture plain references/values so the audio-thread callbacks never touch
        // @MainActor state (doing so crashes under Swift 6 isolation checks).
        let recorder = self.recorder
        let live = self.live
        let liveOn = self.liveTranscribeEnabled
        system.onLevel = { [weak self] v in Task { @MainActor in
            guard let self else { return }
            self.otherLevel = v; self.sysPeak = max(self.sysPeak, v)
            // A buffer arrived → the *tap* is alive. But under Bluetooth HFP routing the
            // tap keeps delivering all-zero buffers, so buffer-arrival alone does NOT mean
            // 對方 audio is being captured (BUG-24). Track buffer-flow for the "device
            // removed → buffers stop" watchdog, but track actual SIGNAL separately.
            self.lastSysLevelAt = Date()
            if v >= Self.silenceThreshold {
                self.lastSysSignalAt = Date()
                self.sysAutoRebuildCount = 0   // reset the cap on real signal, not on silent buffers
                self.silentSysWarned = false   // re-arm: if it dies again later, warn again
            } } }
        mic.onLevel = { [weak self] v in Task { @MainActor in
            guard let self else { return }
            self.youLevel = v; self.micPeak = max(self.micPeak, v)
            // Buffers are flowing → the tap is alive. Mark liveness and clear the
            // consecutive-failure counter so the cap means "failed rebuilds in a row".
            self.lastMicLevelAt = Date(); self.micAutoRebuildCount = 0 } }
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

        do {
            try recorder.start(url: url)
            try mic.start(deviceID: selectedInputDevice?.id)
            try system.start()   // may fail without audio-capture permission — surfaced below
        } catch {
            lastError = "\(error)"
        }
        if liveTranscribeEnabled { live.start(locale: resolvedLocale) }

        accumulated = 0
        startDate = date
        state = .recording
        startTicker()
    }

    public func pause() {
        guard state == .recording else { return }
        accumulated += Date().timeIntervalSince(startDate)
        recorder.isPaused = true
        state = .paused
        stopTicker()
    }

    public func resume() {
        guard state == .paused else { return }
        startDate = Date()
        recorder.isPaused = false
        state = .recording
        startTicker()
    }

    public func stop() {
        guard state == .recording || state == .paused else { return }
        if state == .recording { accumulated += Date().timeIntervalSince(startDate) }
        stopTicker()
        system.stop()
        mic.stop()
        live.stop()
        recorder.stop()
        otherLevel = 0; youLevel = 0

        if let url = currentURL {
            let rec = Recording(id: UUID(),
                                title: currentTitle.isEmpty ? "錄音" : currentTitle,
                                url: url, date: startDate, duration: accumulated,
                                hasTranscript: false,
                                isConverting: url.pathExtension == "caf")
            recordings.insert(rec, at: 0)
            convertToM4A(rec, autoTranscribe: autoTranscribeAfterStop)
        }
        state = .finished
    }

    /// After stopping, convert the lossless CAF into a compact .m4a and drop the CAF.
    /// The main file is ALWAYS the untouched original. If AEC is on, additionally
    /// produce a separate `…_aec.m4a` (non-destructive) — so a bad AEC run can never
    /// damage or lose the real recording (see PRD「AEC 追查」: offline AEC currently
    /// can't reach the real 44–165ms echo delay; kept opt-in + non-destructive).
    private func convertToM4A(_ rec: Recording, autoTranscribe: Bool = false) {
        let caf = rec.url
        guard caf.pathExtension == "caf" else { return }
        // Guard empty/instant recordings: AVAssetExportSession fails with -11800 on a
        // ~0-frame CAF, and resumePendingConversions then re-tries it every launch
        // (recurring「轉 m4a 失敗」banner + a permanent ghost「處理中」row). Such a file
        // holds no audio, so drop it instead of trying — and clear it from the list.
        let frames = (try? AVAudioFile(forReading: caf))?.length ?? 0
        if frames < 2_400 {   // < ~0.05s @ 48k = an accidental start→stop, no content
            try? FileManager.default.removeItem(at: caf)
            recordings.removeAll { $0.id == rec.id }
            return
        }
        let m4a = caf.deletingPathExtension().appendingPathExtension("m4a")
        let doAEC = aecEnabled
        Task {
            do {
                // 1) Always export the untouched original first.
                try await AudioExport.toM4A(from: caf, to: m4a)
                if let i = recordings.firstIndex(where: { $0.id == rec.id }) {
                    recordings[i].url = m4a
                    recordings[i].isConverting = false
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
                if autoTranscribe, whisperEngine != nil,
                   let i = recordings.firstIndex(where: { $0.id == rec.id }) {
                    transcribe(recordings[i])
                }
            } catch {
                lastError = "轉 m4a 失敗:\(error)"
                if let i = recordings.firstIndex(where: { $0.id == rec.id }) {
                    recordings[i].isConverting = false
                }
            }
        }
    }

    /// Finish any CAF left un-converted by a previous crash/force-quit. Such files
    /// load with isConverting=true (see loadRecordings); kick the conversion again.
    private func resumePendingConversions() {
        for rec in recordings where rec.url.pathExtension == "caf" {
            convertToM4A(rec)
        }
    }

    public func newRecording() {
        currentTitle = ""
        elapsed = 0
        liveTranscript = []
        state = .idle
    }

    // MARK: - Per-recording actions

    public func transcribe(_ rec: Recording) {
        guard !isTranscribing else { return }
        lastError = nil
        isTranscribing = true
        Task {
            do {
                let lines = try await fileTranscriber.transcribeFile(rec.url, locale: resolvedLocale)
                liveTranscript = lines
                if let idx = recordings.firstIndex(of: rec) { recordings[idx].hasTranscript = true }
                writeTranscriptSidecar(lines, for: rec)
            } catch {
                lastError = "轉逐字稿失敗:\(error)"
            }
            isTranscribing = false
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
                let now = Date()
                if now.timeIntervalSince(self.lastMicLevelAt) > Self.micDeadAfter,
                   self.micAutoRebuildCount < Self.micMaxConsecutiveRebuilds,
                   now.timeIntervalSince(self.lastMicRebuildAt) > Self.micRebuildCooldown {
                    self.micAutoRebuildCount += 1
                    self.lastMicRebuildAt = now
                    self.rebuildCurrentMic(reason: "你軌訊號中斷")
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
                        cooldown: Self.sysRebuildCooldown, maxRebuilds: Self.sysMaxConsecutiveRebuilds) {
                    self.sysAutoRebuildCount += 1
                    self.lastSysRebuildAt = now
                    self.rebuildSystemCapture(reason: sysBufferStaleFor > Self.sysDeadAfter
                        ? "對方軌訊號中斷" : "對方軌持續無聲")
                }
                // After 8s, if your mic still hasn't picked up anything, warn — your
                // voice channel is dead (usually the wrong input device is selected).
                if self.elapsed > 8, self.micPeak < Self.silenceThreshold, !self.silentMicWarned {
                    self.silentMicWarned = true
                    self.deviceChangeWarning = self.selectedInputDevice?.isBluetooth == true
                        ? "⚠️ 你選的是藍牙麥克風,整場可能收不到聲音(常被會議 app 佔住或掉窄頻)— 請到設定改用內建或 USB 麥克風"
                        : "你的麥克風似乎沒收到聲音 — 請到設定確認「你的麥克風」選對裝置"
                }
                // 對方軌死聲道警告。BUG-24 前這裡用整場單調的 `sysPeak`,開頭只要有
                // 一瞬間收到聲就永久壓過門檻、「中途才死」偵測不到(BUG-24 實例:開頭 1 分鐘
                // 有聲、之後 31 分鐘全零卻整場無警告)。改看「距最後一次真訊號多久」,
                // 中途死也能觸發,且 onLevel 收到訊號會 re-arm `silentSysWarned`。
                if SysTrackWatchdog.shouldWarnSilent(
                        elapsed: self.elapsed, silentFor: sysSilentFor,
                        alreadyWarned: self.silentSysWarned, warnAfter: Self.sysSilentWarnAfter) {
                    self.silentSysWarned = true
                    self.deviceChangeWarning = "⚠️ 對方(系統音訊)沒收到聲音 — 若用藍牙耳機當輸出,通話會走 HFP/電話模式而擷取不到對方,請改用內建喇叭或有線輸出;並確認會議音訊在這台 Mac 上播放"
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

    private func loadRecordings() {
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
            return Recording(id: UUID(), title: url.deletingPathExtension().lastPathComponent,
                             url: url, date: date, duration: duration,
                             hasTranscript: FileManager.default.fileExists(atPath: txt.path),
                             isConverting: url.pathExtension == "caf")
        }.sorted { $0.date > $1.date }
    }

    private func writeTranscriptSidecar(_ lines: [TranscriptLine], for rec: Recording) {
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
                self.refreshDevices()
                guard self.state == .recording else { return }
                // If the device we were recording from just vanished, recover immediately
                // onto a present device (don't wait for the 3s liveness watchdog) —
                // rebuildCurrentMic resolves the now-updated selection/default (BUG-18 / AUD-28).
                if let d = recordingDevice,
                   !self.availableInputDevices.contains(where: { $0.uid == d.uid }) {
                    self.rebuildCurrentMic(reason: "選用的麥克風已移除")
                } else {
                    self.deviceChangeWarning = "偵測到音訊裝置變更,錄音續行中,請確認狀態"
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
                guard now.timeIntervalSince(self.lastSysRebuildAt) > Self.sysRebuildCooldown,
                      self.sysAutoRebuildCount < Self.sysMaxConsecutiveRebuilds else { return }
                self.sysAutoRebuildCount += 1
                self.lastSysRebuildAt = now
                self.rebuildSystemCapture(reason: "系統輸出裝置變更")
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

    /// 是否該嘗試自動重建對方軌 tap:buffer 停止流動(裝置移除)**或**持續真靜音
    /// 太久(死/HFP tap 送全零),且未達連續重建上限、距上次重建已過冷卻。
    static func shouldRebuild(bufferStaleFor: TimeInterval, silentFor: TimeInterval,
                             rebuildCount: Int, sinceLastRebuild: TimeInterval,
                             deadAfter: TimeInterval, silentAfter: TimeInterval,
                             cooldown: TimeInterval, maxRebuilds: Int) -> Bool {
        (bufferStaleFor > deadAfter || silentFor >= silentAfter)
            && rebuildCount < maxRebuilds
            && sinceLastRebuild > cooldown
    }
}
