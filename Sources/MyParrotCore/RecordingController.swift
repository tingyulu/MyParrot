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
    public var engine: TranscriptionEngine = .appleNative
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
    private let fileTranscriber: any TranscriptionProvider
    private let live: any LiveTranscribing

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

    /// True once that channel has actually picked up sound this recording — the
    /// live "yes, your voice is being captured" confirmation during a meeting.
    public var micHasSignal: Bool { micPeak > Self.silenceThreshold }
    public var sysHasSignal: Bool { sysPeak > Self.silenceThreshold }

    public private(set) var recordingsDir: URL

    public init() {
        // Default to a visible folder the user can browse to; overridable in Settings.
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        if let saved = UserDefaults.standard.string(forKey: "recordingsDir") {
            recordingsDir = URL(fileURLWithPath: saved, isDirectory: true)
        } else {
            recordingsDir = docs.appendingPathComponent("MyParrot", isDirectory: true)
        }
        // Prefer the macOS 26 SpeechAnalyzer engine (true long-form streaming);
        // fall back to SFSpeech on older systems. Assign before any self use.
        if #available(macOS 26.0, *) {
            live = SpeechAnalyzerLiveTranscriber()
            fileTranscriber = SpeechAnalyzerFileProvider()
        } else {
            live = LiveTranscriber()
            fileTranscriber = AppleSpeechProvider()
        }
        // All stored properties are initialized below this point.
        try? FileManager.default.createDirectory(at: recordingsDir, withIntermediateDirectories: true)
        migrateLegacyRecordings(into: recordingsDir)
        if let raw = UserDefaults.standard.string(forKey: "language"),
           let lang = TranscriptionLanguage(rawValue: raw) { language = lang }
        if UserDefaults.standard.object(forKey: "inputGain") != nil {
            inputGain = min(2.0, max(0.5, Float(UserDefaults.standard.double(forKey: "inputGain"))))
        }
        aecEnabled = UserDefaults.standard.bool(forKey: "aecSoftware")
        loadRecordings()
        resumePendingConversions()
        refreshDevices()
        installDeviceListener()
        live.onUpdate = { [weak self] lines in self?.liveTranscript = lines }
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
        stopMicMonitor()   // free the mic before recording
        stopPlayback()
        let date = Date()
        let title = currentTitle.isEmpty ? "錄音" : currentTitle
        let url = recordingsDir.appendingPathComponent(Recording.fileName(date: date, title: title))
        currentURL = url

        liveTranscript = []
        deviceChangeWarning = nil
        lastError = nil
        micPeak = 0; sysPeak = 0; silentMicWarned = false
        lastMicLevelAt = Date(); micAutoRebuildCount = 0; lastMicRebuildAt = .distantPast
        mic.gain = inputGain

        // Capture plain references/values so the audio-thread callbacks never touch
        // @MainActor state (doing so crashes under Swift 6 isolation checks).
        let recorder = self.recorder
        let live = self.live
        let liveOn = self.liveTranscribeEnabled
        system.onLevel = { [weak self] v in Task { @MainActor in
            guard let self else { return }; self.otherLevel = v; self.sysPeak = max(self.sysPeak, v) } }
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
                                hasTranscript: false, savedToDrive: false,
                                isConverting: url.pathExtension == "caf")
            recordings.insert(rec, at: 0)
            convertToM4A(rec)
        }
        state = .finished
    }

    /// After stopping, convert the lossless CAF into a compact .m4a and drop the CAF.
    /// The main file is ALWAYS the untouched original. If AEC is on, additionally
    /// produce a separate `…_aec.m4a` (non-destructive) — so a bad AEC run can never
    /// damage or lose the real recording (see PRD「AEC 追查」: offline AEC currently
    /// can't reach the real 44–165ms echo delay; kept opt-in + non-destructive).
    private func convertToM4A(_ rec: Recording) {
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

    /// MVP placeholder. v1.x: upload file + transcript via official Google Drive API,
    /// transcript saved as a Google Doc, then deep-link to the NotebookLM import page.
    public func saveToDrive(_ rec: Recording) {
        if let idx = recordings.firstIndex(of: rec) { recordings[idx].savedToDrive = true }
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
                // After 8s, if your mic still hasn't picked up anything, warn — your
                // voice channel is dead (usually the wrong input device is selected).
                if self.elapsed > 8, self.micPeak < Self.silenceThreshold, !self.silentMicWarned {
                    self.silentMicWarned = true
                    self.deviceChangeWarning = self.selectedInputDevice?.isBluetooth == true
                        ? "⚠️ 你選的是藍牙麥克風,整場可能收不到聲音(常被會議 app 佔住或掉窄頻)— 請到設定改用內建或 USB 麥克風"
                        : "你的麥克風似乎沒收到聲音 — 請到設定確認「你的麥克風」選對裝置"
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
                             savedToDrive: false,
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
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(AudioObjectID.system, &address, DispatchQueue.main) { [weak self] _, _ in
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
    }
}
