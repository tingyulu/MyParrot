import Foundation
import AVFoundation
import ArgumentParser
import MyParrotCore
import os
#if canImport(Darwin)
import Darwin
#endif

/// `myparrot record`(§4.3)。前景執行:TTY 畫電平表,pipe/`--json` 印事件流。
/// 人類 Ctrl-C 或另一終端 `myparrot stop` 都能收掉。
struct RecordCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "record",
        abstract: "開始錄音(前景執行;Ctrl-C 或另開終端 `myparrot stop` 結束)"
    )

    @Option(name: .long, help: "會議名稱(存進檔名,預設「錄音」)") var name: String?
    @Option(name: .long, help: "麥克風:裝置 UID 或名稱關鍵字") var mic: String?
    @Flag(name: .long, help: "開錄前強制重選麥克風選單(忽略已存的 config)") var pickMic = false
    @Option(name: .long, help: "逐字稿引擎:apple|whisper") var engine: String?
    @Flag(name: .long, help: "停止後不自動轉逐字稿") var noTranscribe = false
    @Option(name: .long, help: "最長錄音時間,如 30s/10m/4h,到點自動停止") var maxDuration: String?
    @Flag(name: .long, help: "輸出 JSONL 事件流(stdout 一行一 JSON,非 TTY 時建議搭配)") var json = false
    @Flag(name: .long, help: "只印錯誤與最終結果行") var quiet = false

    mutating func run() async throws {
        var maxDurationSec: TimeInterval?
        if let raw = maxDuration {
            guard let sec = parseDuration(raw) else {
                Output.errLine("錯誤:--max-duration 格式無效「\(raw)」,範例:30s / 10m / 4h")
                MPExitCode.argumentError.terminate()
            }
            maxDurationSec = sec
        }
        if let engine, resolveEngineFlag(engine) == nil {
            Output.errLine("錯誤:--engine 只接受 apple|whisper,收到「\(engine)」")
            MPExitCode.argumentError.terminate()
        }

        let opts = RecordOptions(name: name ?? "", mic: mic, pickMic: pickMic,
                                 engine: engine, noTranscribe: noTranscribe,
                                 maxDurationSec: maxDurationSec, json: json, quiet: quiet)
        await RecordSession.start(options: opts)
    }
}

/// `--engine` 旗標值驗證(純函式,SelfTest)。回傳 nil = 不合法字串。
func resolveEngineFlag(_ raw: String) -> String? {
    ["apple", "whisper"].contains(raw) ? raw : nil
}

/// `30s` / `10m` / `4h` / 純數字(=秒)→ 秒數(純函式,SelfTest)。
func parseDuration(_ raw: String) -> TimeInterval? {
    let s = raw.trimmingCharacters(in: .whitespaces)
    guard !s.isEmpty else { return nil }
    var numPart = ""
    var unit = ""
    for ch in s {
        if ch.isNumber || ch == "." { numPart.append(ch) } else { unit.append(ch) }
    }
    guard let n = Double(numPart), n > 0 else { return nil }
    switch unit.lowercased() {
    case "", "s", "sec", "secs": return n
    case "m", "min", "mins": return n * 60
    case "h", "hr", "hrs": return n * 3600
    default: return nil
    }
}

/// #949 REC-37:GUI 在錄時 `record` 的拒絕訊息(純函式)。elapsed 以 h:mm:ss 呈現。
func guiRecordingRefusal(name: String, elapsed: Double) -> String {
    // 文案照 brief §3／§5.9 原文(全形標點;GUI 字串表同一句)。
    "MyParrot app 正在錄音：\(name)（\(clockString(elapsed))），用 app 或 myparrot stop 結束"
}

/// 秒數 → `h:mm:ss`(純函式)。
func clockString(_ t: Double) -> String {
    let s = max(0, Int(t))
    return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
}

/// 別人(另一個 owner)這場錄了多久:state.json 是同一場(sessionId 相同)就用它寫的 elapsed(扣掉暫停),
/// 否則用租約 startedAt 到現在估。
func externalElapsed(_ lease: RecordingLease, state: RecordingStateFile? = StateStore.readState(), now: Date = Date()) -> Double {
    if let s = state, !lease.sessionId.isEmpty, s.sessionId == lease.sessionId { return s.elapsed }
    guard let started = ISO8601.date(lease.startedAt) else { return 0 }
    return max(0, now.timeIntervalSince(started))
}

/// 裝置比對(旗標/config 存的字串 → 實際裝置)。優先比對穩定的 `uid`(BUG-13 教訓:
/// 數字 `id` 在拔插/重開機後會重編,不能拿來持久化比對),其次名稱包含(方便
/// `--mic airpods` 這種人手打的用法),最後才嘗試當數字 id 解析。純函式。
func findDevice(key: String, in devices: [AudioInputDevice]) -> AudioInputDevice? {
    if let byUID = devices.first(where: { $0.uid == key }) { return byUID }
    let lower = key.lowercased()
    if let byName = devices.first(where: { $0.name.lowercased().contains(lower) }) { return byName }
    if let idNum = UInt32(key), let byID = devices.first(where: { $0.id == idNum }) { return byID }
    return nil
}

/// `run()` 解析完的旗標,傳給 `@MainActor` 的 session driver(值型別,Sendable,
/// 跨 actor 傳遞零負擔)。
struct RecordOptions: Sendable {
    var name: String
    var mic: String?
    var pickMic: Bool
    var engine: String?
    var noTranscribe: Bool
    var maxDurationSec: TimeInterval?
    var json: Bool
    var quiet: Bool
}

/// 修 2a(2026-08-10):訊號處理狀態獨立於 `@MainActor` 的 `RecordSession`,故意
/// 不用 `@MainActor` 隔離——修 1 的死鎖情境證實 main 執行緒可能永久卡在
/// CoreAudio HAL `StartIO`(`AVAudioEngine.start()` 對 mutex 永久等待);若訊號
/// handler 仍靠舊版那樣 `Task { @MainActor in ... }` 派工到 main run loop,main
/// 死了訊號就跟著死(Eric 2026-08-10 真 Terminal 實測:SIGINT 對卡死的進程完全
/// 無效,只能被 Terminal 直接砍掉)。改成訊號 handler 掛在獨立背景 queue、狀態
/// 全部收在這裡(不碰 actor、不 hop 到 main),第三次直接在這個背景執行緒
/// cleanup+exit,不等 main 回應。鎖的用法比照 Core `LiveTranscriber.Stream`
/// 既有的 `OSAllocatedUnfairLock` 慣例。
private final class SignalCoordinator: @unchecked Sendable {
    private struct State { var count = 0; var stopRequested = false }
    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// 主迴圈(main actor)讀這個旗標決定要不要開始收尾——讀取本身跨執行緒安全
    /// (鎖保護),不需要額外隔離。
    var stopRequested: Bool { lock.withLock { $0.stopRequested } }

    /// 非訊號來源的停止請求(如 `--max-duration` 到點),不計入訊號次數、不印
    /// 訊號類訊息。
    func requestStop() { lock.withLock { $0.stopRequested = true } }

    /// 在訊號背景 queue 同步執行——**絕不** hop 到 main actor,main 死掉時這裡
    /// 仍要能動。第 1 次=設 stopRequested 讓主迴圈自己收尾;第 2 次=僅提示;
    /// 第 3 次=不再信任主迴圈還活著,直接在這個背景執行緒清檔+結束程序。
    func handleSignal() {
        let count: Int = lock.withLock { state in
            state.count += 1
            if state.count == 1 { state.stopRequested = true }
            return state.count
        }
        switch count {
        case 1:
            Output.errLine("\n收到中斷,正在收尾…")
        case 2:
            Output.errLine("正在收尾,再按一次強制放棄(可能損檔)")
        default:
            Output.errLine("強制結束(可能損檔;main 執行緒可能已卡死,於訊號背景執行緒直接清檔結束)")
            StateStore.cleanup()
            exit(130)
        }
    }
}

/// 修 2b(2026-08-10):啟動/存活看門狗。獨立於 `@MainActor`,理由同
/// `SignalCoordinator`——要能在 main 徹底卡死(修 1 那類死鎖,或未來任何未預期
/// 的迴歸)時仍然動作,不能靠 main run loop 排程檢查自己。主迴圈每 tick 呼叫
/// `beat()` 更新心跳;背景 timer 每 2 秒檢查一次,心跳停滯超過門檻就印診斷、
/// 清檔、`exit(4)`(對映既有 `MPExitCode.recordingFailed`,語意上這確實是一種
/// 錄音失敗)。門檻預設 10 秒,`MYPARROT_WATCHDOG_SEC` 可覆蓋——供測試用短門檻
/// 驗證看門狗真的會觸發,不用真的卡 10 秒。
private final class Watchdog: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: Date())
    private let thresholdSec: TimeInterval
    private var timerSource: DispatchSourceTimer?

    init() {
        let envValue = ProcessInfo.processInfo.environment["MYPARROT_WATCHDOG_SEC"]
        thresholdSec = envValue.flatMap(TimeInterval.init) ?? 10
    }

    /// 主迴圈每 tick 呼叫,更新心跳時間戳。
    func beat() { lock.withLock { $0 = Date() } }

    /// 啟動背景 timer。呼叫端應在可能發生長時間阻塞的操作(如
    /// `controller.startRecording()`)之前呼叫,連同一次 `beat()` 一起,這樣連
    /// 「啟動階段就卡死」也能被抓到,不是只保障進了主迴圈之後。
    func start() {
        let queue = DispatchQueue(label: "tw.uncle.myparrot.watchdog")
        let src = DispatchSource.makeTimerSource(queue: queue)
        src.schedule(deadline: .now() + 2, repeating: 2)
        src.setEventHandler { [weak self] in self?.check() }
        src.resume()
        timerSource = src
    }

    /// 正常結束錄音迴圈後呼叫,停止監看(後製階段的長時間輪詢不算「凍結」,
    /// 不應被看門狗誤殺)。
    func stop() {
        timerSource?.cancel()
        timerSource = nil
    }

    private func check() {
        let last = lock.withLock { $0 }
        let staleFor = Date().timeIntervalSince(last)
        guard staleFor > thresholdSec else { return }
        let pid = ProcessInfo.processInfo.processIdentifier
        Output.errLine("""
        🐶 看門狗:主執行緒疑似凍結(已 \(Int(staleFor))s 無心跳,門檻 \(Int(thresholdSec))s)。
        建議對此 pid 執行 `sample \(pid) 2 -f <path>` 抓 stack 診斷根因(常見成因:
        CoreAudio HAL StartIO 死鎖,見 MicCapture.rebuildAfterConfigurationChange())。
        本進程即將強制結束,避免無限卡死。
        """)
        StateStore.cleanup()
        exit(4)
    }
}

/// 一場錄音的完整生命週期驅動者。`@MainActor` 因為要碰 `RecordingController`。
/// `start(options:)` 跑到底直接 `exit()`,不回傳(前景進程職責就是跑完這一場)。
@MainActor
final class RecordSession {
    private let controller: RecordingController
    private let signalCoordinator = SignalCoordinator()
    private let watchdog = Watchdog()
    private var maxDurationHit = false
    /// Keep the dispatch sources alive for the process lifetime.
    private var sigintSource: DispatchSourceSignal?
    private var sigtermSource: DispatchSourceSignal?

    /// #949:錄音資料夾在建 controller 時就指定(不先掃偏好裡的舊資料夾)。
    private init(recordingsDir: URL) {
        controller = RecordingController(recordingsDir: recordingsDir)
    }

    static func start(options: RecordOptions) async {
        // #949 REC-37:租約被別人持有 ⇒ 直接拒絕,連 controller 都不建(不掃資料夾、不請麥克風)。
        refuseIfLeaseHeld(json: options.json)
        let session = RecordSession(recordingsDir: resolvedRecordingsDir(CLIConfigStore.load()))
        await session.run(options: options)
    }

    /// 已有錄音中 → exit 4(§2.2)。舊 CLI(只有 record.pid)與新版租約兩種都擋。
    private static func refuseIfLeaseHeld(json: Bool) {
        if let active = StateStore.activePID() {
            Output.errLine("已有錄音進行中(pid \(active)),用 myparrot stop 結束")
            MPExitCode.recordingFailed.terminate()
        }
        switch RecordingLeaseHolder.inspect() {
        case .alive(let lease): refuse(lease: lease, json: json)
        case .unreadable(let e):
            Output.errLine("讀不到錄音租約(\(String(cString: strerror(e)))),為免兩邊同時錄音,不開錄")
            MPExitCode.recordingFailed.terminate()
        case .none, .dead: return
        }
    }

    /// REC-37:GUI 在錄 ⇒「MyParrot app 正在錄音：<name>（<elapsed>），用 app 或 myparrot stop 結束」＋ `refused` 事件;
    /// 另一個 CLI ⇒ 同今天(訊息含 pid)。都 exit `recordingFailed`(4)。
    private static func refuse(lease: RecordingLease, json: Bool) -> Never {
        let elapsed = externalElapsed(lease)
        if lease.owner == "gui" {
            Output.errLine(guiRecordingRefusal(name: lease.name, elapsed: elapsed))
            if json { Output.refused(reason: "gui-recording", lease: lease, elapsed: elapsed) }
        } else {
            Output.errLine("已有錄音進行中(pid \(lease.pid)),用 myparrot stop 結束")
            if json { Output.refused(reason: lease.owner == "cli" ? "cli-recording" : "recording", lease: lease, elapsed: elapsed) }
        }
        MPExitCode.recordingFailed.terminate()
    }

    private func run(options: RecordOptions) async {
        var config = CLIConfigStore.load()
        let jsonMode = options.json
        let quiet = options.quiet

        let recordingsDir = controller.recordingsDir
        controller.leaseOwner = "cli"   // #949:租約/state.json 標 owner=cli
        // CLI 只請麥克風——不走 controller.requestPermissions():它連帶呼叫
        // SFSpeechRecognizer.requestAuthorization,而 bare CLI 的 __info_plist 在
        // TCC 的 usage-description 查找路徑上讀不到(2026-08-10 實測:嵌了 plist
        // 照樣 SIGABRT)。CLI 轉錄走 SpeechAnalyzer/whisper,本就零語音辨識 TCC
        // (decisions.md D7),不請求不影響任何功能。
        controller.micPermission = await AVCaptureDevice.requestAccess(for: .audio)
        controller.refreshPermissionStatus()   // PERM-01
        // PERM-12(#2673):麥克風被拒／受限 ⇒ 一行提示後照常錄(只錄對方);🚫 不加互動確認(CLI 可能在腳本裡跑)。
        if PermissionHints.recordGateBlocks(mic: controller.micAuthorization) {
            let hint = "麥克風權限未開啟,這段只會錄到對方;開啟:open \"\(PermissionKind.microphone.settingsURL.absoluteString)\""
            if jsonMode { Output.jsonEvent(["event": "warning", "message": hint]) } else { Output.errLine("⚠️ " + hint) }
        }

        // 引擎/語言(旗標 > config > 預設)。
        let engineRaw = options.engine ?? config.engine
        controller.engine = resolveEngine(engineRaw)
        if let langRaw = config.language, let lang = parseLanguage(langRaw) {
            controller.language = lang
        }
        // 偏離 plan §4.3 字面(「autoTranscribeAfterStop 照設定」):實測 Core 只有
        // whisper 引擎+已裝模型時才會在這個旗標下自動重轉(convertToM4A 的
        // Phase C 分支),apple 引擎完全不會自動產生逐字稿。CLI 要對所有引擎都
        // 兌現「錄完自動轉逐字稿」,故改由 CLI 自己在 stop 後明確呼叫
        // `controller.transcribe()`,並把這個旗標固定關掉,避免 whisper 情境
        // 下被 Core 重複觸發一次多餘的轉錄。細節見 notes.md。
        controller.autoTranscribeAfterStop = false

        // 麥克風解析:旗標 > config > (TTY 互動選單) > 系統預設。
        await resolveMic(options: options, config: &config)

        controller.currentTitle = options.name

        let pid = Int32(ProcessInfo.processInfo.processIdentifier)
        do {
            try StateStore.writePID(pid)
        } catch {
            Output.errLine("寫 pidfile 失敗:\(error)")
            MPExitCode.recordingFailed.terminate()
        }

        installSignalHandlers()
        // 修 2b:看門狗在 `startRecording()` 之前就啟動+打第一次心跳,這樣連
        // 「啟動階段本身就卡死」(修 1 那類死鎖最典型的發生時機)都在監看範圍內,
        // 不是只保障進了主迴圈之後。
        watchdog.start()
        watchdog.beat()

        controller.startRecording()
        let startedAt = Date()
        // 只驗 state——`recordings` 在 stop() 前不會有本場錄音,拿它當啟動判準
        // 會在「全新空目錄」誤判失敗(2026-08-10 復現台實測:state=recording 卻
        // exit 4;執行者審查時也獨立標記過同一問題)。
        guard controller.state == .recording else {
            // #949:只清自己的 record.pid——state.json 此刻可能是 GUI owner 的,不能一起刪。
            StateStore.removePIDFile(ifPID: pid)
            // 開錄前檢查過租約,這裡還被擋＝同秒競爭輸了(O_EXCL 只有一個成功)⇒ 一樣走 refused。
            if case .held(let existing)? = controller.lastLeaseError {
                Self.refuse(lease: existing ?? .placeholder, json: jsonMode)
            }
            Output.errLine("錄音未能啟動(state=\(controller.state))\(controller.lastError.map { ":\($0)" } ?? "")")
            MPExitCode.recordingFailed.terminate()
        }
        // startRecording() 尚未把新 Recording 放進 recordings(那是 stop() 才做的)。
        // 用 controller 內部算出的檔案路徑:currentURL 是 private,改用命名規則重算。
        // #892:與 controller 同一套防撞名規則——但 controller 已經先建了檔,這裡若再探測
        // 會多算一個後綴;改用 controller 真正開的檔(currentRecordingURL)。
        let plannedAudioPath = (controller.currentRecordingURL
            ?? recordingsDir.appendingPathComponent(Recording.fileName(date: startedAt, title: options.name)))
            .path

        if jsonMode {
            Output.jsonEvent(["event": "started", "audioPath": plannedAudioPath,
                              "name": options.name, "pid": Int(pid)])
        } else if !quiet {
            Output.infoLine("🦜 開始錄音 → \(plannedAudioPath)")
            Output.infoLine("(Ctrl-C 結束;另開終端可用 `myparrot stop`)")
        }

        await recordingLoop(options: options, startedAt: startedAt, jsonMode: jsonMode, quiet: quiet)
        // 後製階段(轉檔/轉錄輪詢)本來就會長時間不「tick」,不算凍結,故正常
        // 結束錄音迴圈後就停看門狗,不要在 finishAndPostProcess 裡誤殺。
        watchdog.stop()

        let exitCode = await finishAndPostProcess(options: options, config: config, jsonMode: jsonMode, quiet: quiet)
        StateStore.cleanup()
        exitCode.terminate()
    }

    // MARK: - Mic resolution

    private func resolveMic(options: RecordOptions, config: inout CLIConfigSchema) async {
        let devices = controller.availableInputDevices
        if let key = options.mic {
            guard let device = findDevice(key: key, in: devices) else {
                Output.errLine("警告:找不到符合「\(key)」的麥克風,使用系統預設")
                return
            }
            controller.setPreferredInputDevice(device)
            return
        }
        if let savedKey = config.mic, !options.pickMic {
            if let device = findDevice(key: savedKey, in: devices) {
                controller.setPreferredInputDevice(device)
            } else {
                Output.errLine("警告:config 記錄的麥克風「\(savedKey)」目前找不到,使用系統預設")
            }
            return
        }
        // 只有 TTY(人)且沒有旗標/config 記錄(或 --pick-mic 強制)時才彈選單。
        // 非 TTY/agent 情境絕不等輸入(clig.dev 原則)。
        guard Output.isStdinTTY, Output.isStdoutTTY, !options.json else { return }
        switch MicPicker.pick(devices: devices) {
        case .device(let device):
            controller.setPreferredInputDevice(device)
            config.mic = device.uid
            try? CLIConfigStore.save(config)
        case .systemDefault, .noInput:
            return
        }
    }

    // MARK: - Signal handling

    private func installSignalHandlers() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        // 修 2a:訊號 queue 從 `.main` 改成獨立背景 queue,handler 直接呼叫
        // `signalCoordinator.handleSignal()`(不透過 actor)——main 執行緒卡死
        // 時(修 1 那類死鎖)訊號仍要能收得到、收得掉。詳細理由見
        // `SignalCoordinator` 型別上方註解。
        //
        // ⚠️ 陷阱(真跑撞到,記下來):`{ [signalCoordinator] in
        // signalCoordinator.handleSignal() }` 這種閉包字面值,即使只捕捉一個
        // Sendable 值、完全不碰 `self`,**只要它是寫在 `@MainActor` 方法內部**,
        // Swift 6 仍會把這個閉包推斷成 MainActor-isolated(隱式繼承外層 actor)。
        // 這個閉包實際上被 GCD 在背景 queue 呼叫時,編譯器插入的 isolation
        // 檢查會直接觸發 `SIGTRAP`(`dispatch_assert_queue_fail`)——真的測到
        // 這支 crash log,不是理論推演。改成傳「bound method reference」
        // (`signalCoordinator.handleSignal`,非閉包字面值)才會拿到
        // `SignalCoordinator`(一個沒有 actor 隔離的 plain class)本身的
        // nonisolated 方法,不會意外繼承 `RecordSession` 的 MainActor。
        let queue = DispatchQueue(label: "tw.uncle.myparrot.signal")
        let sigint = DispatchSource.makeSignalSource(signal: SIGINT, queue: queue)
        sigint.setEventHandler(handler: signalCoordinator.handleSignal)
        sigint.resume()
        sigintSource = sigint

        let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: queue)
        sigterm.setEventHandler(handler: signalCoordinator.handleSignal)
        sigterm.resume()
        sigtermSource = sigterm
    }

    // MARK: - Main loop(§4.3:主迴圈)

    private func recordingLoop(options: RecordOptions, startedAt: Date, jsonMode: Bool, quiet: Bool) async {
        var previousLineCount = 0
        var lastSecondTick = Date.distantPast
        var lastStateWrite = Date.distantPast
        var lastOtherSignalAt = Date()
        var lastYouSignalAt = Date()
        var lastWarningSent: String?

        while true {
            try? await Task.sleep(nanoseconds: 100_000_000)   // 10Hz
            watchdog.beat()   // 修 2b:每 tick 回報「main 還活著」

            if controller.otherLevel > 0.003 { lastOtherSignalAt = Date() }
            if controller.youLevel > 0.003 { lastYouSignalAt = Date() }

            if let maxSec = options.maxDurationSec, controller.elapsed >= maxSec, !signalCoordinator.stopRequested {
                signalCoordinator.requestStop()
                maxDurationHit = true
                if !quiet { Output.errLine("已達 --max-duration \(Int(maxSec))s,自動停止") }
            }

            guard controller.state == .recording || controller.state == .paused else { break }

            if signalCoordinator.stopRequested {
                writeState(state: "stopping", startedAt: startedAt, audioPath: nil,
                          name: options.name, warning: controller.deviceChangeWarning)
                controller.stop()
                break
            }

            let now = Date()
            // #949 REC-34:owner 每 0.5 秒寫 state.json(GUI 的橫幅/`status` 讀它)。
            if now.timeIntervalSince(lastStateWrite) >= 0.5 {
                lastStateWrite = now
                writeState(state: controller.state == .paused ? "paused" : "recording", startedAt: startedAt,
                          audioPath: nil, name: options.name, warning: controller.deviceChangeWarning)
            }
            if now.timeIntervalSince(lastSecondTick) >= 1.0 {
                lastSecondTick = now
                // #949 REC-36:每 1 秒收一次 commands/(GUI 橫幅的停止／暫停／繼續、`myparrot stop` 給 GUI 以外的情境)。
                pollCommands(jsonMode: jsonMode)
                if jsonMode && !quiet {
                    Output.jsonEvent([
                        "event": "level", "other": Double(controller.otherLevel), "you": Double(controller.youLevel),
                        "otherSignal": controller.sysHasSignal, "youSignal": controller.micHasSignal,
                        "elapsed": controller.elapsed
                    ])
                }
                if jsonMode, let warning = controller.deviceChangeWarning, warning != lastWarningSent {
                    lastWarningSent = warning
                    Output.jsonEvent(["event": "warning", "message": warning])
                }
            }

            if !jsonMode && !quiet && Output.isStdoutTTY {
                let frame = Meter.Frame(
                    otherLevel: controller.otherLevel, youLevel: controller.youLevel,
                    otherHasSignal: controller.sysHasSignal, youHasSignal: controller.micHasSignal,
                    otherSilentFor: Date().timeIntervalSince(lastOtherSignalAt),
                    youSilentFor: Date().timeIntervalSince(lastYouSignalAt),
                    elapsed: controller.elapsed, name: options.name,
                    warning: controller.deviceChangeWarning, lastError: controller.lastError)
                let (text, count) = Meter.render(frame, useColor: Output.useColor, previousLineCount: previousLineCount)
                print(text)
                previousLineCount = count
            }
        }
        if !jsonMode && !quiet && Output.isStdoutTTY { print("") }
    }

    /// CLI owner 收指令:stop ⇒ 走跟 Ctrl-C 同一條收尾(requestStop);pause/resume ⇒ controller;
    /// mark ⇒ 只印一行事件(CLI 沒有筆記);title ⇒ 改 currentTitle(檔名開錄時已定,不改檔名)。
    private func pollCommands(jsonMode: Bool) {
        guard let sid = controller.sessionId else { return }
        let started = controller.heldLease.flatMap { ISO8601.date($0.startedAt) } ?? Date.distantPast
        for cmd in RecordingCommandStore.pending() {
            if let why = RecordingCommand.rejection(cmd, sessionId: sid, sessionStartedAt: started) {
                RecordingCommandStore.complete(cmd.requestId, ok: false, result: why)
                continue
            }
            var ok = true
            var result = cmd.cmd
            switch cmd.cmd {
            case "stop":
                signalCoordinator.requestStop()
                result = "stopping"
                if !jsonMode { Output.errLine("\n收到停止指令(來自 app 或另一個 myparrot),正在收尾…") }
            case "pause":
                controller.pause(); ok = controller.state == .paused; result = ok ? "paused" : "not recording"
            case "resume":
                controller.resume(); ok = controller.state == .recording; result = ok ? "recording" : "not paused"
            case "mark":
                result = "marked"
            case "title":
                if let t = cmd.args["title"] { controller.currentTitle = t }
                result = controller.currentTitle
            default:
                ok = false; result = "不支援的指令:\(cmd.cmd)"
            }
            if jsonMode { Output.jsonEvent(["event": "command", "cmd": cmd.cmd, "requestId": cmd.requestId, "ok": ok]) }
            RecordingCommandStore.complete(cmd.requestId, ok: ok, result: result)
            if cmd.cmd == "stop" { break }
        }
    }

    private func writeState(state: String, startedAt: Date, audioPath: String?, name: String, warning: String?) {
        // #949 REC-34:舊欄位一個不少(舊 CLI 讀得懂)＋ owner／sessionId／elapsed／paused／markers／protocolVersion。
        let s = CLIRecordingState(
            pid: Int32(ProcessInfo.processInfo.processIdentifier),
            startedAt: ISO8601.string(startedAt),
            audioPath: audioPath ?? controller.inprogressAudioPath ?? "",
            name: name,
            state: state,
            levels: .init(other: Double(controller.otherLevel), you: Double(controller.youLevel),
                         otherSignal: controller.sysHasSignal, youSignal: controller.micHasSignal),
            warning: warning,
            updatedAt: ISO8601.string(),
            owner: "cli", sessionId: controller.sessionId ?? "", elapsed: controller.liveElapsed,
            paused: controller.state == .paused, markers: controller.markerCount
        )
        try? StateStore.writeState(s)
    }

    // MARK: - Post-processing(§4.3:等後處理完成→hook→輸出→清檔)

    private func finishAndPostProcess(options: RecordOptions, config: CLIConfigSchema,
                                       jsonMode: Bool, quiet: Bool) async -> MPExitCode {
        writeState(state: "postprocessing", startedAt: Date(), audioPath: nil,
                  name: options.name, warning: controller.deviceChangeWarning)

        // #949:用 stop() 這次真的建的那一筆(發布失敗時沒有這筆;不能拿 recordings.first——那可能是資料夾裡更早的舊檔)。
        guard let recID = controller.lastStoppedRecordingID else {
            // #949:發布失敗(檔留 inprogress 等收割)或太短進隔離區時 lastError 有原因。
            Output.errLine(controller.lastError ?? "錄音時間過短,未儲存檔案")
            return .recordingFailed
        }
        // 逾時上限=音長×4+600s(§4.3),用剛錄的 elapsed 當音長估計。
        let deadline = Date().addingTimeInterval(max(600, controller.elapsed * 4) + 600)
        while let rec = controller.recordings.first(where: { $0.id == recID }), rec.isConverting {
            if Date() > deadline { break }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        guard let rec = controller.recordings.first(where: { $0.id == recID }) else {
            // #949 REC-33:太短的檔搬進 .myparrot/quarantine/(不再刪),訊息由 controller.lastError 帶出。
            Output.errLine(controller.lastError ?? "錄音檔轉檔失敗或被判定為空檔,未儲存")
            if jsonMode, let err = controller.lastError { Output.jsonEvent(["event": "error", "message": err]) }
            return .recordingFailed
        }

        if jsonMode {
            Output.jsonEvent(["event": "stopped", "audioPath": rec.url.path, "duration": controller.elapsed])
        } else if !quiet {
            Output.infoLine("已停止錄音:\(rec.url.path)")
        }

        var exitCode = MPExitCode.success
        let (transcriptPath, srtPath, transcribeEngineLabel) = await runTranscribeStage(
            rec: rec, options: options, config: config, jsonMode: jsonMode, quiet: quiet, exitCode: &exitCode)

        await runMinutesStage(rec: rec, transcriptPath: transcriptPath, options: options,
                              config: config, jsonMode: jsonMode, quiet: quiet, exitCode: &exitCode)

        if jsonMode {
            Output.jsonEvent(["event": "transcribed", "transcript": transcriptPath, "srt": srtPath,
                              "engine": transcribeEngineLabel])
            Output.jsonEvent(["event": "done", "exitCode": Int(exitCode.rawValue)])
        } else if !quiet {
            if let transcriptPath { Output.infoLine("逐字稿:\(transcriptPath)") }
            Output.infoLine("完成(exit \(exitCode.rawValue))")
        }
        return exitCode
    }

    /// 回傳(txt 路徑, srt 路徑, 引擎標籤)——皆可能為 nil(未轉錄/略過/失敗)。
    private func runTranscribeStage(rec: Recording, options: RecordOptions, config: CLIConfigSchema,
                                     jsonMode: Bool, quiet: Bool, exitCode: inout MPExitCode)
        async -> (String?, String?, String?) {
        let base = rec.url.deletingPathExtension()
        let expectedTxt = base.appendingPathExtension("txt").path
        let expectedSrt = base.appendingPathExtension("srt").path
        let autoTranscribeWanted = !options.noTranscribe && (config.autoTranscribe ?? true)

        if let hook = config.hooks?["transcribe"], hook.auto {
            guard HookTrust.isApproved(config.hooks) else {
                if jsonMode { Output.jsonEvent(["event": "hook", "stage": "transcribe", "status": "skipped",
                                                "detail": "hooks 未核准,執行 myparrot hooks approve"]) }
                return await fallbackBuiltinTranscribe(rec: rec, wanted: autoTranscribeWanted,
                                                       expectedTxt: expectedTxt, expectedSrt: expectedSrt,
                                                       exitCode: &exitCode)
            }
            let outcome = await runHookProcess(stage: "transcribe", hook: hook, rec: rec, transcript: nil, config: config)
            let audioDurationSec = controller.elapsed
            let (ok, reportedPath) = HookRunner.transcribeHookSucceeded(
                exitCode: outcome.exitCode, stdout: outcome.stdout, expectedTxtPath: expectedTxt,
                fileExistsNonEmpty: fileExistsNonEmpty)
            _ = audioDurationSec
            if ok {
                if jsonMode { Output.jsonEvent(["event": "hook", "stage": "transcribe", "status": "ok", "detail": nil]) }
                let srt = fileExistsNonEmpty(expectedSrt) ? expectedSrt : nil
                // hook 以 stdout JSON 指到別的路徑時要沿用(v0.3.0 二審:原本丟掉回傳值、
                // 固定回 {base}.txt → 輸出與 minutes hook 都拿到不存在的檔)。
                return (reportedPath ?? expectedTxt, srt, "hook")
            }
            let detail = outcome.launchError ?? (outcome.timedOut ? "逾時" : "exit \(outcome.exitCode);stderr:\(outcome.stderr.prefix(200))")
            if hook.strict {
                if jsonMode { Output.jsonEvent(["event": "hook", "stage": "transcribe", "status": outcome.timedOut ? "timeout" : "failed", "detail": detail]) }
                Output.errLine("transcribe hook 失敗(strict=true,不 fallback):\(detail)")
                exitCode = .hookFailedStrict
                return (nil, nil, nil)
            }
            if jsonMode { Output.jsonEvent(["event": "hook", "stage": "transcribe", "status": outcome.timedOut ? "timeout" : "failed", "detail": detail]) }
            return await fallbackBuiltinTranscribe(rec: rec, wanted: true, expectedTxt: expectedTxt,
                                                   expectedSrt: expectedSrt, exitCode: &exitCode)
        }

        return await fallbackBuiltinTranscribe(rec: rec, wanted: autoTranscribeWanted,
                                               expectedTxt: expectedTxt, expectedSrt: expectedSrt, exitCode: &exitCode)
    }

    private func fallbackBuiltinTranscribe(rec: Recording, wanted: Bool, expectedTxt: String,
                                            expectedSrt: String, exitCode: inout MPExitCode)
        async -> (String?, String?, String?) {
        guard wanted else { return (nil, nil, nil) }
        controller.transcribe(rec)
        while controller.isTranscribing {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        if let err = controller.lastError, fileExistsNonEmpty(expectedTxt) == false {
            Output.errLine("內建轉錄失敗:\(err)")
            exitCode = .transcriptionFailed
            return (nil, nil, nil)
        }
        guard fileExistsNonEmpty(expectedTxt) else {
            exitCode = .transcriptionFailed
            return (nil, nil, nil)
        }
        return (expectedTxt, fileExistsNonEmpty(expectedSrt) ? expectedSrt : nil, controller.engine.rawValue)
    }

    private func runMinutesStage(rec: Recording, transcriptPath: String?, options: RecordOptions,
                                  config: CLIConfigSchema, jsonMode: Bool, quiet: Bool, exitCode: inout MPExitCode) async {
        guard let hook = config.hooks?["minutes"] else { return }
        guard hook.auto else {
            if jsonMode { Output.jsonEvent(["event": "hook", "stage": "minutes", "status": "skipped", "detail": "auto=false"]) }
            return
        }
        guard HookTrust.isApproved(config.hooks) else {
            if jsonMode { Output.jsonEvent(["event": "hook", "stage": "minutes", "status": "skipped",
                                            "detail": "hooks 未核准,執行 myparrot hooks approve"]) }
            return
        }
        let outcome = await runHookProcess(stage: "minutes", hook: hook, rec: rec, transcript: transcriptPath, config: config)
        let ok = outcome.exitCode == 0 && !outcome.timedOut && outcome.launchError == nil
        if jsonMode {
            Output.jsonEvent(["event": "hook", "stage": "minutes",
                              "status": ok ? "ok" : (outcome.timedOut ? "timeout" : "failed"),
                              "detail": ok ? nil : (outcome.launchError ?? "exit \(outcome.exitCode)")])
        } else if !quiet && !ok {
            Output.errLine("minutes hook 失敗(僅記錄,不影響主流程):exit \(outcome.exitCode) \(outcome.stderr.prefix(200))")
        }
        if !ok && hook.strict { exitCode = .hookFailedStrict }
    }

    private func runHookProcess(stage: String, hook: HookSpec, rec: Recording, transcript: String?,
                                 config: CLIConfigSchema) async -> HookRunner.RunOutcome {
        let audio = rec.url.path
        let dir = rec.url.deletingLastPathComponent().path
        let command = HookRunner.substitute(hook.command, audio: audio, transcript: transcript,
                                            name: rec.title, dir: dir)
        let env = HookRunner.environment(audio: audio, transcript: transcript, name: rec.title, dir: dir)
        let stdinData = HookRunner.stdinMetadataJSON(stage: stage, audio: audio, transcript: transcript,
                                                     name: rec.title, dir: dir)
        let timeout = hook.timeout.resolvedSeconds(audioDurationSec: controller.elapsed)
        return await HookRunner.execute(command: command, cwd: hook.cwd, env: env,
                                        stdinData: stdinData, timeoutSec: timeout)
    }

    private func fileExistsNonEmpty(_ path: String) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? UInt64 else { return false }
        return size > 0
    }
}
