import Foundation
import ArgumentParser
import MyParrotCore
#if canImport(Darwin)
import Darwin
#endif

/// `myparrot stop`(§5)。讀 pidfile → SIGINT → 等優雅收尾。**絕不 SIGKILL**
/// (ffmpeg moov atom / CAF finalize 損檔教訓,decisions D2)。
struct StopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "結束目前的錄音(送 SIGINT,等收尾)")

    @Flag(name: .long, help: "額外等到後製(轉檔/轉錄/hook)完全結束才回傳(上限 30 分)") var wait = false
    @Flag(name: .long, help: "輸出單行 JSON 結果") var json = false

    /// GUI owner 回 `.done` 的等待上限(brief §9 預設 20 秒)。
    static let guiStopTimeout: TimeInterval = 20

    func run() async throws {
        _ = resolvedRecordingsDir(CLIConfigStore.load())   // C2:租約在 <錄音夾>/.myparrot,先把錄音夾定下來
        // #949 §5.7:先看全域租約決定分流;沒有租約才走舊版 record.pid(8/10 舊 CLI 在錄)。
        switch RecordingLeaseHolder.inspect() {
        case .alive(let lease) where lease.owner == "gui":
            stopGUI(lease)
        case .alive(let lease):
            await stopCLI(pid: lease.pid, leaseSession: lease.sessionId)
        case .dead:
            if StateStore.activePID() == nil {
                let msg = "上次錄音未正常結束,啟動 app 或 `myparrot list` 會自動修復"
                if json { Output.jsonEvent(["recording": false, "message": msg]) } else { Output.infoLine(msg) }
                MPExitCode.success.terminate()
            }
            await stopLegacy()
        case .unreadable(let e):
            Output.errLine("讀不到錄音租約(\(String(cString: strerror(e)))),不確定誰在錄,沒有送出停止")
            MPExitCode.recordingFailed.terminate()
        case .none:
            await stopLegacy()
        }
    }

    /// owner=gui:寫 `commands/<id>.json {"cmd":"stop"}`,等 `.done`/`.failed` 或租約釋放(最多 20 秒)。
    private func stopGUI(_ lease: RecordingLease) {
        let cmd = RecordingCommand(cmd: "stop", args: ["sessionId": lease.sessionId])
        do { try RecordingCommandStore.issue(cmd) } catch {
            Output.errLine("寫停止指令失敗:\(error)")
            MPExitCode.recordingFailed.terminate()
        }
        let answered = RecordingCommandStore.wait(cmd.requestId, timeout: Self.guiStopTimeout)
        let res = RecordingCommandStore.result(cmd.requestId)
        guard answered else {
            Output.errLine("app 未回應(\(Int(Self.guiStopTimeout)) 秒內沒有處理停止指令),請到 MyParrot app 按停止")
            if json { Output.external(action: "stop", lease: lease, result: "timeout") }
            MPExitCode.recordingFailed.terminate()
        }
        if let res, !res.ok {
            Output.errLine("app 拒絕停止:\(res.result)")
            if json { Output.external(action: "stop", lease: lease, result: "failed", detail: res.result) }
            MPExitCode.recordingFailed.terminate()
        }
        if json { Output.external(action: "stop", lease: lease, result: "done", detail: res?.result) }
        else { Output.infoLine("已請 MyParrot app 停止錄音:\(lease.name)") }
        MPExitCode.success.terminate()
    }

    /// owner=cli(新版):SIGINT 租約上的 pid,等租約釋放(＝錄音已停、檔已發布)。
    private func stopCLI(pid: Int32, leaseSession: String) async {
        guard pid > 0, kill(pid_t(pid), SIGINT) == 0 else {
            Output.errLine("送出 SIGINT 給 pid \(pid) 失敗:\(String(cString: strerror(errno)))")
            MPExitCode.recordingFailed.terminate()
        }
        let stopDeadline = Date().addingTimeInterval(15)
        while Date() < stopDeadline {
            if case .alive(let l) = RecordingLeaseHolder.inspect(), l.sessionId == leaseSession {
                try? await Task.sleep(nanoseconds: 300_000_000)
            } else { break }
        }
        if case .alive(let l) = RecordingLeaseHolder.inspect(), l.sessionId == leaseSession {
            Output.errLine("⚠ 已送出停止訊號,但 15 秒內錄音還沒收尾(租約仍在)——請稍候用 `myparrot status` 確認,不會強殺進程")
            if json { Output.jsonEvent(["recording": true, "message": "停止訊號已送出,收尾中"]) }
            MPExitCode.recordingFailed.terminate()
        }
        await finishWait()
    }

    /// 等後製(`--wait`)並回報。
    private func finishWait() async {
        if wait {
            let waitDeadline = Date().addingTimeInterval(30 * 60)
            while StateStore.readState() != nil, Date() < waitDeadline {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        if json { Output.jsonEvent(["recording": false, "message": "已停止"]) }
        else { Output.infoLine("已停止") }
        MPExitCode.success.terminate()
    }

    /// 沒有租約:8/10 舊 CLI 只有 record.pid ⇒ 舊流程(SIGINT pidfile)。
    private func stopLegacy() async {
        guard let pid = StateStore.activePID() else {
            if json { Output.jsonEvent(["recording": false, "message": "沒有進行中的錄音"]) }
            else { Output.infoLine("沒有進行中的錄音") }
            MPExitCode.success.terminate()
        }

        guard kill(pid_t(pid), SIGINT) == 0 else {
            Output.errLine("送出 SIGINT 給 pid \(pid) 失敗:\(String(cString: strerror(errno)))")
            MPExitCode.recordingFailed.terminate()
        }

        // 等 pidfile/state 消失(=錄音進程正常結束並自行清檔),逾時警告但絕不強殺。
        let stopDeadline = Date().addingTimeInterval(15)
        while StateStore.activePID() != nil, Date() < stopDeadline {
            try? await Task.sleep(nanoseconds: 300_000_000)
        }
        if StateStore.activePID() != nil {
            Output.errLine("⚠ 已送出停止訊號,但 15 秒內未看到收尾完成(pidfile 仍在)——錄音可能還在做較長的收尾,請稍候用 `myparrot status` 確認,不會強殺進程")
            if !wait {
                if json { Output.jsonEvent(["recording": true, "message": "停止訊號已送出,收尾中"]) }
                MPExitCode.recordingFailed.terminate()
            }
        }

        if wait {
            // 額外等到 state 檔(postprocessing)整個消失——上限 30 分。
            let waitDeadline = Date().addingTimeInterval(30 * 60)
            while StateStore.readState() != nil, Date() < waitDeadline {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }

        if json { Output.jsonEvent(["recording": false, "message": "已停止"]) }
        else { Output.infoLine("已停止") }
        MPExitCode.success.terminate()
    }
}

/// `myparrot status`(§5)。無 pidfile/stale → `{"recording":false}`;有 → state
/// 檔全文 + `"recording":true"`。
struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "目前有沒有在錄音、錄多久、電平快照")

    @Flag(name: .long, help: "輸出 JSON(預設也是 JSON——status 天生是給 agent 讀的)") var json = false

    func run() throws {
        let dir = resolvedRecordingsDir(CLIConfigStore.load())   // C2:先定錄音夾,租約/state 才找得到
        Output.jsonEvent(Self.snapshot(inspection: RecordingLeaseHolder.inspect(), state: StateStore.readState(),
                                       legacyPID: StateStore.activePID(),
                                       recoverable: RecordingController.inprogressLeftovers(dir: dir)))
    }

    /// #949 §3:`status` 的輸出(純函式,CLI SelfTest 可測)。
    /// - 租約活著 ⇒ `recording:true`＋owner／sessionId／elapsed／paused＋state.json 電平(同一場才用)＋`unresponsive`(心跳 >10 秒)。
    /// - 沒租約但舊 CLI(只有 record.pid)在錄 ⇒ 舊格式＋`owner:"cli"`。
    /// - 都沒有 ⇒ `{"recording":false}`;租約鎖得到(死／沒有)但 inprogress 有殘檔 ⇒ 加 `recoverable`。
    static func snapshot(inspection: LeaseInspection, state: RecordingStateFile?, legacyPID: Int32?,
                         recoverable: [(sessionId: String, audio: URL)], now: Date = Date()) -> [String: Any?] {
        switch inspection {
        case .alive(let lease):
            let st = (state?.sessionId == lease.sessionId && !lease.sessionId.isEmpty) ? state : nil
            return [
                "recording": true, "owner": lease.owner, "sessionId": lease.sessionId, "pid": Int(lease.pid),
                "startedAt": lease.startedAt, "audioPath": lease.audioPath, "name": lease.name,
                "state": st?.state ?? "recording",
                "elapsed": externalElapsed(lease, state: state, now: now), "paused": st?.paused ?? false,
                "markers": st?.markers ?? 0,
                "other": st?.levels.other, "you": st?.levels.you,
                "otherSignal": st?.levels.otherSignal, "youSignal": st?.levels.youSignal,
                "warning": st?.warning, "updatedAt": st?.updatedAt ?? lease.heartbeatAt,
                "unresponsive": RecordingLease.isHeartbeatStale(lease, now: now) ? true : nil
            ]
        case .unreadable(let e):
            return ["recording": false, "error": "讀不到錄音租約:\(String(cString: strerror(e)))"]
        case .none, .dead:
            if let pid = legacyPID {
                // 舊版 CLI(8/10,沒有租約)在錄:沿用舊輸出;state.json 還沒寫出來(開錄頭一秒)也算在錄
                // (矩陣 O1 抓到:只看到 record.pid 時舊判斷回 recording:false)。
                return ["recording": true, "owner": "cli", "pid": Int(pid), "startedAt": state?.startedAt,
                        "audioPath": state?.audioPath, "name": state?.name, "state": state?.state ?? "recording",
                        "other": state?.levels.other, "you": state?.levels.you,
                        "otherSignal": state?.levels.otherSignal, "youSignal": state?.levels.youSignal,
                        "warning": state?.warning, "updatedAt": state?.updatedAt, "legacy": true]
            }
            var out: [String: Any?] = ["recording": false]
            if !recoverable.isEmpty {
                out["recoverable"] = recoverable.map { ["sessionId": $0.sessionId, "audioPath": $0.audio.path] as [String: Any?] }
            }
            return out
        }
    }
}
