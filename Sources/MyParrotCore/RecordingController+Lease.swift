import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// #949 第一段:唯一 writer 租約＋inprogress 路徑＋發布(brief §4、§5 步驟 3～8)。
/// 本體的 `startRecording`/`stop` 只呼叫這裡的函式,租約與檔案規則集中在一處。
extension RecordingController {

    // MARK: - 路徑(純函式,SelfTest `inprogressPathAndPublishName`;本體在 `InprogressFiles`,fake-writer 共用)

    /// `<dir>/.myparrot`——MyParrot 在錄音資料夾裡的私有區(inprogress、quarantine)。舊版收割端只掃頂層,看不到這裡。
    public nonisolated static func privateDir(dir: URL) -> URL { InprogressFiles.privateDir(dir: dir) }

    /// `<dir>/.myparrot/inprogress`
    public nonisolated static func inprogressRoot(dir: URL) -> URL { InprogressFiles.root(dir: dir) }

    /// 錄音中實際寫的檔:`<dir>/.myparrot/inprogress/<sessionId>/audio.caf`。
    public nonisolated static func inprogressURL(dir: URL, sessionId: String) -> URL {
        InprogressFiles.audioURL(dir: dir, sessionId: sessionId)
    }

    /// 發布目的地 `<dir>/<stem>.caf`,帶避讓(只看音檔 .caf/.m4a,不看 sidecar)。
    public nonisolated static func publishURL(dir: URL, stem: String, fm: FileManager = .default) -> URL {
        InprogressFiles.publishURL(dir: dir, stem: stem, fm: fm)
    }

    public typealias PublishError = InprogressFiles.PublishError

    /// REC-31:`renamex_np(RENAME_EXCL)` 原子發布到頂層(撞名換後綴、絕不覆蓋),成功後刪 `inprogress/<id>/`。
    public nonisolated static func publishInprogress(_ src: URL, dir: URL, stem: String,
                                                     fm: FileManager = .default) -> Swift.Result<URL, PublishError> {
        InprogressFiles.publish(src, dir: dir, stem: stem, fm: fm)
    }

    /// 停止時(recorder 已 finalize)發布本場錄音並收尾:發布 → 刪 inprogress 目錄 → 釋放租約 → GUI owner 清自己的
    /// state.json。回傳落地的頂層 URL;nil＝沒有可發布的檔(開錄就失敗)或發布失敗(lastError 已設,檔留 inprogress)。
    func publishAndEndLease() -> URL? {
        let sid = sessionId
        defer {
            endLease()
            if leaseOwner == "gui", let sid { RecordingStateStore.cleanupState(ifSession: sid) }
        }
        guard let src = inprogressURL, let planned = currentURL else { return nil }
        inprogressURL = nil
        switch Self.publishInprogress(src, dir: recordingsDir, stem: planned.deletingPathExtension().lastPathComponent) {
        case .success(let dest):
            currentURL = dest
            return dest
        case .failure(.missing):
            return nil
        case .failure(.renameFailed(let e)):
            lastError = "發布錄音失敗(\(String(cString: strerror(e)))):檔案留在 \(src.deletingLastPathComponent().path),"
                + "下次啟動 app 或執行 myparrot list 會自動復原"
            return nil
        }
    }

    /// 租約取不到時給 UI/CLI 的訊息(繁中;GUI 經 `L` 翻)。
    public nonisolated static let leaseHeldMessage = "已有錄音進行中"

    nonisolated static func leaseFailureMessage(_ e: LeaseError) -> String {
        switch e {
        case .held: return leaseHeldMessage
        case .unsupportedVolume:
            return "設定資料夾所在的磁碟不支援檔案鎖,無法確認只有一個錄音在跑,已取消開錄"
        case .ioError(let code):
            return "取得錄音租約失敗:\(String(cString: strerror(code)))"
        }
    }

    // MARK: - 租約生命週期

    /// 開錄前取租約＋建 inprogress 目錄。失敗 ⇒ `lastLeaseError`/`lastError`,回 false(呼叫端什麼都不做)。
    func beginLease(sessionId sid: String, name: String, audioURL: URL) -> Bool {
        lastLeaseError = nil
        let lease = RecordingLease.make(sessionId: sid, owner: leaseOwner, name: name, audioPath: audioURL.path)
        // C2 相容:10/20 版 CLI 的租約還在 ~/.config/myparrot(舊位置);它活著就一樣不開第二份。
        if case .alive(let legacy) = RecordingLeaseHolder.inspect(in: MyParrotPaths.configDir), legacy.sessionId != sid {
            lastLeaseError = .held(legacy)
            lastError = Self.leaseFailureMessage(.held(legacy))
            return false
        }
        switch RecordingLeaseHolder.acquire(lease) {
        case .failure(let e):
            lastLeaseError = e
            lastError = Self.leaseFailureMessage(e)
            return false
        case .success(let holder):
            do {
                try FileManager.default.createDirectory(at: audioURL.deletingLastPathComponent(),
                                                        withIntermediateDirectories: true)
            } catch {
                holder.release()
                lastError = "建立錄音暫存夾失敗:\(error)"
                return false
            }
            leaseHolder = holder
            sessionId = sid
            inprogressURL = audioURL
            lastHeartbeatAt = Date()
            lastCommandPoll = Date()
            RecordingCommandStore.purge()   // 清掉一小時前的指令結果/沒人收的舊指令
            return true
        }
    }

    /// 釋放租約、停 owner 計時器。可重入(沒持有就什麼都不做)。
    func endLease() {
        stopOwnerTimer()
        leaseHolder?.release()
        leaseHolder = nil
    }

    /// 本進程是不是目前錄音的 owner(持有租約)。
    public var holdsLease: Bool { leaseHolder != nil }

    /// 目前持有的租約內容(DebugControl `lease status` 用)。
    public var heldLease: RecordingLease? { leaseHolder?.lease }

    // MARK: - owner 計時器(0.5 秒;錄音＋暫停期間都跑)

    /// 既有 `startTicker` 是 0.25 秒且**暫停時停掉**——暫停中仍要心跳、寫 state(paused)、收 resume 指令,
    /// 所以另開一支 0.5 秒的 owner 計時器,開錄起、停止收尾後停(報告 §5 偏差)。
    func startOwnerTimer() {
        ownerTimer?.invalidate()
        ownerTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.ownerTick() }
        }
    }

    func stopOwnerTimer() {
        ownerTimer?.invalidate()
        ownerTimer = nil
    }

    /// 心跳間隔(brief §9 預設 2 秒)。
    nonisolated static let heartbeatInterval: TimeInterval = 2

    func ownerTick(now: Date = Date()) {
        guard let holder = leaseHolder else { return }
        if now.timeIntervalSince(lastHeartbeatAt) >= Self.heartbeatInterval {
            lastHeartbeatAt = now
            holder.heartbeat(now: now)
        }
        // REC-36:GUI 當 owner 時每 1 秒收一次指令檔(CLI owner 在自己的主迴圈收,不重複)。
        if leaseOwner == "gui", now.timeIntervalSince(lastCommandPoll) >= 1 {
            lastCommandPoll = now
            processExternalCommands()
        }
        // REC-34:GUI 當 owner 時由這裡每 0.5 秒寫 state.json(CLI owner 在自己的主迴圈寫,不重複)。
        if leaseOwner == "gui" { writeOwnerState() }
    }

    // MARK: - 指令檔(REC-36)

    /// owner 端:依序執行 `commands/*.json`,完成就 `.done`／`.failed`。不是這場的、早於本場開錄的 ⇒ `.failed`。
    func processExternalCommands() {
        guard let holder = leaseHolder, let sid = sessionId else { return }
        let started = ISO8601.date(holder.lease.startedAt) ?? segmentStart
        for cmd in RecordingCommandStore.pending() {
            if let why = RecordingCommand.rejection(cmd, sessionId: sid, sessionStartedAt: started) {
                RecordingCommandStore.complete(cmd.requestId, ok: false, result: why)
                continue
            }
            let (ok, result) = executeExternal(cmd)
            RecordingCommandStore.complete(cmd.requestId, ok: ok, result: result)
            if cmd.cmd == "stop" { break }   // 停了:後面的指令留給下一場判過期
        }
    }

    /// 走既有公開方法(stop/pause/resume/currentTitle);`mark` Core 沒有對應 ⇒ 交給 App 層 `onExternalCommand`。
    func executeExternal(_ cmd: RecordingCommand) -> (Bool, String) {
        switch cmd.cmd {
        case "stop":
            stop()
            return (true, currentRecordingURL?.path ?? "stopped")
        case "pause":
            pause()
            return (state == .paused, state == .paused ? "paused" : "not recording")
        case "resume":
            resume()
            return (state == .recording, state == .recording ? "recording" : "not paused")
        case "mark":
            guard let handler = onExternalCommand else { return (false, "這一端不支援標記") }
            handler(cmd)
            return (true, "marked")
        case "title":
            if let t = cmd.args["title"] { currentTitle = t }
            return (true, currentTitle)
        default:
            return (false, "不支援的指令:\(cmd.cmd)")
        }
    }

    /// 非 owner 端(GUI 看到 CLI 在錄)送指令。新版 owner(租約 protocolVersion ≥ 1)⇒ 寫 `commands/<id>.json`
    /// (帶 sessionId,只給這一場);舊版 CLI(沒有租約、只有 record.pid)不認指令檔 ⇒ 只有 stop 能送,退而 SIGINT。
    /// 回傳 requestId("sigint"＝走了舊版路徑;nil＝沒送出)。
    @discardableResult
    public func requestExternal(_ cmd: String, args: [String: String] = [:]) -> String? {
        guard leaseHolder == nil else { return nil }   // 自己就是 owner:用本地方法,不送指令給自己
        // 監看中有看到的那一場優先(舊版 CLI 沒有租約,只有監看看得到它的 pid)
        if let ext = externalRecording, ext.lease.protocolVersion < 1 {
            guard cmd == "stop", ext.lease.pid > 0 else { return nil }
            return kill(ext.lease.pid, SIGINT) == 0 ? "sigint" : nil
        }
        switch RecordingLeaseHolder.inspect() {
        case .alive(let lease) where lease.protocolVersion >= 1:
            var a = args
            a["sessionId"] = lease.sessionId
            let c = RecordingCommand(cmd: cmd, args: a)
            do {
                try RecordingCommandStore.issue(c)
                return c.requestId
            } catch {
                lastError = "送出指令失敗:\(error)"
                return nil
            }
        case .alive(let lease) where cmd == "stop" && lease.pid > 0:
            return kill(lease.pid, SIGINT) == 0 ? "sigint" : nil
        default:
            if cmd == "stop", let pid = RecordingStateStore.activePID() {
                return kill(pid_t(pid), SIGINT) == 0 ? "sigint" : nil
            }
            return nil
        }
    }

    public func requestExternalStop() { requestExternal("stop") }
    public func requestExternalPause() { requestExternal("pause") }
    public func requestExternalResume() { requestExternal("resume") }

    // MARK: - 監看別的進程的錄音(REC-35)

    /// App 啟動時呼叫(CLI 不用):監看 `~/.config/myparrot/` 與錄音資料夾,事件或 2 秒保底 ⇒ `refreshExternal()`。
    public func startExternalWatch() {
        guard externalWatcher == nil else { return }
        // C2:監看 <錄音夾>/.myparrot(租約/state/commands)與錄音夾頂層;舊位置 ~/.config/myparrot 也看著(10/20 版 CLI 相容)。
        let w = ExternalRecordingWatcher(directories: Self.watchDirectories(for: recordingsDir)) { [weak self] in
            Task { @MainActor in self?.refreshExternal() }
        }
        externalWatcher = w
        w.start()
        refreshExternal()
    }

    /// C2 唯一一處決定「監看哪些目錄」:夾內協定目錄、錄音夾頂層、舊位置(10/20 版 CLI 相容)。start／換夾／重探都用它。
    nonisolated static func watchDirectories(for dir: URL) -> [URL] {
        [MyParrotPaths.protocolDir(for: dir), dir, MyParrotPaths.configDir]
    }

    public func stopExternalWatch() {
        externalWatcher?.stop()
        externalWatcher = nil
    }

    /// 重算 `externalRecording`;別人那場結束/死掉 ⇒ 收割＋重掃列表;資料夾頂層有新檔(別的進程發布了成品)⇒ 重掃列表。
    public func refreshExternal(now: Date = Date()) {
        let selfSession = leaseHolder != nil ? sessionId : nil
        let legacyPID = (leaseHolder == nil) ? RecordingStateStore.activePID() : nil
        // C2:先看新位置(<錄音夾>/.myparrot),沒有活租約再看舊位置(~/.config/myparrot,10/20 版 CLI);state.json 同理。
        let inspection = Self.effectiveInspection(primary: RecordingLeaseHolder.inspect(),
                                                  legacy: RecordingLeaseHolder.inspect(in: MyParrotPaths.configDir))
        let state = RecordingStateStore.read() ?? RecordingStateStore.read(in: MyParrotPaths.configDir)
        let next = Self.computeExternal(inspection: inspection, state: state,
                                        legacyPID: legacyPID, selfSessionId: selfSession, now: now)
        let ended = externalRecording != nil && next == nil
        if next != externalRecording { externalRecording = next }
        if ended { reapInprogress() }
        let sig = ((try? FileManager.default.contentsOfDirectory(atPath: recordingsDir.path)) ?? [])
            .filter { $0.hasSuffix(".m4a") || $0.hasSuffix(".caf") || $0.hasSuffix(".txt") }.sorted()
        if ended || sig != recordingsDirSignature {
            recordingsDirSignature = sig
            loadRecordings()
        }
    }

    /// C2 純函式:新位置有活租約就用它;否則舊位置有活租約就用舊的;都沒有 ⇒ 新位置的結果(dead／none 由收割端判)。
    nonisolated static func effectiveInspection(primary: LeaseInspection, legacy: LeaseInspection) -> LeaseInspection {
        if case .alive = primary { return primary }
        if case .alive = legacy { return legacy }
        return primary
    }

    /// 純函式:租約/state.json/舊版 pidfile ⇒ 該不該顯示「別人在錄」。
    /// - 租約 alive 且不是自己那場 ⇒ 有值;心跳 > 10 秒 ⇒ `unresponsive`(只標示,不收割)。
    /// - 沒有活租約但舊版 CLI 的 record.pid 活著 ⇒ 用 state.json 組一個 protocolVersion 0 的租約(停止只能 SIGINT)。
    nonisolated static func computeExternal(inspection: LeaseInspection, state: RecordingStateFile?, legacyPID: Int32?,
                                            selfSessionId: String?, now: Date) -> ExternalRecording? {
        switch inspection {
        case .alive(let lease):
            if let me = selfSessionId, lease.sessionId == me { return nil }
            let st = (state?.sessionId == lease.sessionId && !lease.sessionId.isEmpty) ? state : nil
            return ExternalRecording(lease: lease, state: st,
                                     unresponsive: RecordingLease.isHeartbeatStale(lease, now: now))
        case .none, .dead, .unreadable:
            guard let pid = legacyPID else { return nil }
            // 驗證員 medium(2026-10-20):新版 CLI 停錄後租約已釋放、record.pid 要到後製結束才清;這段期間不是錄音,
            // 不能顯示「正在錄音」更不能給停止鈕(會 SIGINT 後製中的 CLI)。
            if let st = state?.state, st == "postprocessing" || st == "stopping" { return nil }
            let lease = RecordingLease(sessionId: "", owner: "cli", pid: pid, bundleID: "myparrot-cli", appVersion: "",
                                       protocolVersion: 0, startedAt: state?.startedAt ?? "",
                                       name: state?.name ?? "", audioPath: state?.audioPath ?? "",
                                       bootUUID: "", heartbeatAt: state?.updatedAt ?? "")
            return ExternalRecording(lease: lease, state: state, unresponsive: false)
        }
    }

    /// 錄音中實際寫的 inprogress 檔路徑(state.json 的 audioPath、CLI 顯示用)。
    public var inprogressAudioPath: String? { inprogressURL?.path }

    /// 目前錄了多久(扣掉暫停;不等 0.25 秒 ticker,當下算)。
    public var liveElapsed: TimeInterval {
        state == .recording ? accumulatedElapsed + Date().timeIntervalSince(segmentStart) : elapsed
    }

    /// owner 的 state.json 內容(GUI 與 CLI 共用同一個組法;`stateLabel` 由呼叫端給:recording/paused/stopping/postprocessing)。
    public func ownerStateFile(stateLabel: String? = nil) -> RecordingStateFile {
        let label = stateLabel ?? (state == .paused ? "paused" : "recording")
        return RecordingStateFile(
            pid: getpid(), startedAt: leaseHolder?.lease.startedAt ?? ISO8601.string(segmentStart),
            audioPath: inprogressURL?.path ?? "", name: leaseHolder?.lease.name ?? currentTitle, state: label,
            levels: .init(other: Double(otherLevel), you: Double(youLevel), otherSignal: sysHasSignal, youSignal: micHasSignal),
            warning: deviceChangeWarning, updatedAt: ISO8601.string(), owner: leaseOwner, sessionId: sessionId ?? "",
            elapsed: liveElapsed, paused: state == .paused, markers: markerCount)
    }

    /// GUI owner 寫 state.json(每 0.5 秒＋暫停／繼續當下)。只在持有租約時寫。
    func writeOwnerState() {
        guard leaseHolder != nil, leaseOwner == "gui" else { return }
        try? RecordingStateStore.write(ownerStateFile())
    }

    // MARK: - 收割(REC-32)

    /// `<dir>/.myparrot/inprogress/` 底下有 audio.caf 的那幾場(sessionId, audio URL)——status 的 `recoverable` 用。
    public nonisolated static func inprogressLeftovers(dir: URL, fm: FileManager = .default) -> [(sessionId: String, audio: URL)] {
        InprogressFiles.leftovers(dir: dir, fm: fm)
    }

    /// 掃 `<recordingsDir>/.myparrot/inprogress/*/`:依 `ReapPolicy`(租約 alive ⇒ 跳過;dead／沒有租約檔 ⇒ 發布到
    /// 頂層 `<stem>-已修復.caf` 再轉檔;讀不到租約狀態 ⇒ fail closed:不動、lastError)。
    func reapInprogress() {
        let fm = FileManager.default
        let root = Self.inprogressRoot(dir: recordingsDir)
        guard let ids = try? fm.contentsOfDirectory(atPath: root.path), !ids.isEmpty else { return }
        let inspection = RecordingLeaseHolder.inspect()
        var published: [URL] = []
        var recoveredIDs: Set<String> = []
        for id in ids.sorted() {
            let dirURL = root.appendingPathComponent(id, isDirectory: true)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dirURL.path, isDirectory: &isDir), isDir.boolValue else { continue }
            // 自己正在寫的那場:inspect 對自己持有的租約本來就回 alive,這裡是雙保險。
            if leaseHolder != nil, id == sessionId { continue }
            switch ReapPolicy.decide(topLevelCafAge: nil, inspection: inspection) {
            case .skip, .manualOnly:
                continue
            case .failClosed:
                if case .unreadable(let e) = inspection {
                    lastError = "讀不到錄音租約狀態(\(String(cString: strerror(e)))),未自動復原中斷的錄音 \(id)"
                }
                continue
            case .repair:
                let audio = dirURL.appendingPathComponent("audio.caf")
                let stem = Self.repairStem(sessionId: id, audio: audio, inspection: inspection)
                switch Self.publishInprogress(audio, dir: recordingsDir, stem: stem) {
                case .success(let dest):
                    published.append(dest)
                    recoveredIDs.insert(id)
                    recoveredRecordings.append(RecoveredRecording(sessionId: id, url: dest))
                    RecordingStateStore.cleanupState(ifSession: id)   // 死掉那場留下的 state.json
                case .failure(.missing):
                    continue   // 空目錄(開錄就失敗的殘骸),publishInprogress 已清掉
                case .failure(.renameFailed(let e)):
                    lastError = "復原中斷的錄音失敗(\(String(cString: strerror(e)))):\(audio.path)"
                }
            }
        }
        // 死租約剛好就是這次復原的那場 ⇒ 清掉(status/stop 不再說「上次錄音未正常結束」)。
        if case .dead(let l) = inspection, recoveredIDs.contains(l.sessionId) {
            _ = RecordingLeaseHolder.clearIfDead()
        }
        guard !published.isEmpty else { return }
        loadRecordings()
        for url in published {
            if let rec = recordings.first(where: { $0.url == url }) { convertToM4A(rec) }
        }
    }

    /// 復原檔名主幹:死租約就是這場 ⇒ 用租約記的名字(開錄時算好的 `<日期 時間> <標題>`);
    /// 否則用 inprogress 檔的建立時間組 `<日期 時間> 錄音`。最後加「-已修復」。
    nonisolated static func repairStem(sessionId: String, audio: URL, inspection: LeaseInspection) -> String {
        if case .dead(let l) = inspection, l.sessionId == sessionId, !l.name.isEmpty {
            return l.name + Recording.repairedSuffix
        }
        let attrs = try? FileManager.default.attributesOfItem(atPath: audio.path)
        let date = (attrs?[.creationDate] as? Date) ?? (attrs?[.modificationDate] as? Date) ?? Date()
        let base = String(Recording.fileName(date: date, title: "錄音").dropLast(4))
        return base + Recording.repairedSuffix
    }

    // MARK: - 頂層殘檔手動修復

    /// 這筆能不能「修復」:頂層殘檔(needsManualRepair)且 mtime 超過 24 小時(`ReapPolicy.manualOnly`)。
    public func canRepair(_ rec: Recording, now: Date = Date()) -> Bool {
        guard rec.needsManualRepair, rec.url.pathExtension == "caf" else { return false }
        let attrs = try? FileManager.default.attributesOfItem(atPath: rec.url.path)
        guard let mtime = attrs?[.modificationDate] as? Date else { return false }
        return ReapPolicy.decide(topLevelCafAge: now.timeIntervalSince(mtime), inspection: nil) == .manualOnly
    }

    /// 右鍵「修復」:只對 `canRepair` 成立的殘檔呼叫轉檔(轉成同名 m4a)。
    public func repair(_ rec: Recording) {
        guard canRepair(rec) else { return }
        if let i = recordings.firstIndex(where: { $0.id == rec.id }) {
            recordings[i].needsManualRepair = false
            recordings[i].isConverting = true
        }
        convertToM4A(rec)
    }
}

/// REC-35:別的進程正在錄的那一場(GUI 橫幅/中央鍵停用/DebugControl `external status`)。
public struct ExternalRecording: Equatable, Sendable {
    public var lease: RecordingLease
    public var state: RecordingStateFile?
    public var unresponsive: Bool

    /// 錄了多久:同一場 state.json 的 elapsed(扣掉暫停),沒有就用 startedAt 估。
    public func elapsed(now: Date = Date()) -> TimeInterval {
        if let s = state, s.protocolVersion >= 1 { return s.elapsed }   // 舊版 state.json 沒有 elapsed 欄
        guard let d = ISO8601.date(lease.startedAt) else { return 0 }
        return max(0, now.timeIntervalSince(d))
    }
    public var paused: Bool { state?.paused ?? false }
    /// 舊版 CLI(沒有租約/指令檔)⇒ 暫停/繼續不能送,停止只能 SIGINT。
    public var supportsCommands: Bool { lease.protocolVersion >= 1 }
}

/// 收割端復原的一場(CLI `recovered` 事件)。
public struct RecoveredRecording: Equatable, Sendable {
    public var sessionId: String
    public var url: URL
}
