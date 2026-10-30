import Foundation
import AVFoundation
#if canImport(Darwin)
import Darwin
#endif

/// #949 第一段 SelfTest(brief §6):全部純函式或只動**自己建的暫存夾**,
/// 🚫 不讀寫真的 `~/.config/myparrot`、🚫 不碰錄音資料夾。每案的正控組突變記錄在
/// `docs/worklogs/2026-10-20-single-recorder/report-949-stage1.md` §6。
extension SelfTest {

    /// 每案自建一個暫存夾(`NSTemporaryDirectory()/mp949_<案名>_<uuid>`),跑完刪掉。
    static func withScratchDir<T>(_ tag: String, _ body: (URL) throws -> T) rethrows -> T {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mp949_\(tag)_\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        return try body(dir)
    }

    // MARK: - REC-34 state.json 新舊相容

    /// 2026-08-10 舊 CLI 的 `CLIRecordingState` 原樣(欄位一個不加),用來證明「舊 CLI 讀得懂新檔」。
    private struct LegacyCLIRecordingState: Codable, Equatable {
        var pid: Int32
        var startedAt: String
        var audioPath: String
        var name: String
        var state: String
        var levels: Levels
        var warning: String?
        var updatedAt: String
        struct Levels: Codable, Equatable {
            var other: Double
            var you: Double
            var otherSignal: Bool
            var youSignal: Bool
        }
    }

    static func leaseStateCompat() -> Result {
        var fails: [String] = []
        // ① 舊欄位 JSON(8/10 CLI 寫的檔)→ 新型別:新欄位走預設值。
        let oldJSON = """
        {"pid":4242,"startedAt":"2026-08-10T01:02:03.000Z","audioPath":"/x/a.caf","name":"週會","state":"paused",\
        "levels":{"other":0.1,"you":0.2,"otherSignal":true,"youSignal":false},"updatedAt":"2026-08-10T01:02:04.000Z"}
        """
        if let s = try? JSONDecoder().decode(RecordingStateFile.self, from: Data(oldJSON.utf8)) {
            if s.owner != "cli" { fails.append("舊檔 owner 預設應為 cli,得 \(s.owner)") }
            if s.sessionId != "" { fails.append("舊檔 sessionId 預設應為空") }
            if s.elapsed != 0 { fails.append("舊檔 elapsed 預設應為 0") }
            if !s.paused { fails.append("舊檔 state=paused ⇒ paused 應為 true") }
            if s.markers != 0 { fails.append("舊檔 markers 預設應為 0") }
            if s.protocolVersion != 0 { fails.append("舊檔 protocolVersion 預設應為 0") }
            if s.pid != 4242 || s.name != "週會" || s.levels.you != 0.2 { fails.append("舊欄位值沒帶過來") }
        } else {
            fails.append("舊欄位 JSON 解不開新型別")
        }
        // ② 新型別 JSON → 舊 CLI 的結構:要解得開(多的欄位忽略),舊欄位值一致。
        let new = RecordingStateFile(pid: 7, startedAt: "2026-10-20T00:00:00.000Z", audioPath: "/r/.myparrot/inprogress/S/audio.caf",
                                     name: "客戶會議", state: "recording",
                                     levels: .init(other: 0.5, you: 0.25, otherSignal: true, youSignal: true),
                                     warning: "警告", updatedAt: "2026-10-20T00:00:01.000Z",
                                     owner: "gui", sessionId: "S", elapsed: 12.5, paused: false, markers: 3)
        do {
            let data = try JSONEncoder().encode(new)
            let legacy = try JSONDecoder().decode(LegacyCLIRecordingState.self, from: data)
            if legacy.pid != 7 || legacy.name != "客戶會議" || legacy.state != "recording"
                || legacy.levels.other != 0.5 || legacy.warning != "警告" || legacy.audioPath != new.audioPath {
                fails.append("舊結構讀新檔值不符:\(legacy)")
            }
            let back = try JSONDecoder().decode(RecordingStateFile.self, from: data)
            if back != new { fails.append("新型別來回不等") }
            if back.protocolVersion != RecordingStateFile.currentProtocolVersion { fails.append("新檔 protocolVersion 應為 1") }
        } catch {
            fails.append("新型別 JSON 舊結構解不開:\(error)")
        }
        // ③ 暫存夾真檔來回(RecordingStateStore 帶 dir,不碰真的 config 目錄)+ GUI 收尾只清自己那場。
        withScratchDir("state") { dir in
            do {
                try RecordingStateStore.write(new, in: dir)
                if RecordingStateStore.read(in: dir) != new { fails.append("暫存夾寫讀不等") }
                RecordingStateStore.cleanupState(ifSession: "別場", in: dir)
                if RecordingStateStore.read(in: dir) == nil { fails.append("cleanupState 不該清別場的檔") }
                RecordingStateStore.cleanupState(ifSession: "S", in: dir)
                if RecordingStateStore.read(in: dir) != nil { fails.append("cleanupState 應清掉自己那場") }
            } catch {
                fails.append("暫存夾寫檔失敗:\(error)")
            }
        }
        return Result(name: "REC-34 state.json 新舊相容(舊檔→新型別預設值/新檔→舊結構)", passed: fails.isEmpty,
                      detail: fails.joined(separator: "; "))
    }
}

// MARK: - REC-30 全域租約(步驟 2)
extension SelfTest {

    static func sampleLease(_ id: String = UUID().uuidString, owner: String = "cli",
                            heartbeat: Date = Date()) -> RecordingLease {
        RecordingLease(sessionId: id, owner: owner, pid: getpid(), bundleID: "selftest", appVersion: "0",
                       startedAt: ISO8601.string(heartbeat), name: "測試", audioPath: "/x/.myparrot/inprogress/\(id)/audio.caf",
                       bootUUID: RecordingLease.bootSessionUUID(), heartbeatAt: ISO8601.string(heartbeat))
    }

    /// 暫存夾內:acquire 成功 → 第二次 acquire 回 `.held` → inspect `.alive` → release → inspect `.none`
    /// → 再 acquire 成功;另驗「死檔」(有內容但沒人持鎖)inspect `.dead` 且 acquire 會清掉重建、心跳改得到內容。
    static func leaseAcquireRelease() -> Result {
        var fails: [String] = []
        withScratchDir("lease") { dir in
            let a = sampleLease("A")
            switch RecordingLeaseHolder.acquire(a, in: dir) {
            case .failure(let e): fails.append("第一次 acquire 應成功,得 \(e)")
            case .success(let holder):
                if case .failure(.held(let existing)) = RecordingLeaseHolder.acquire(sampleLease("B"), in: dir) {
                    if existing?.sessionId != "A" { fails.append("held 應帶回現有租約 A,得 \(String(describing: existing?.sessionId))") }
                } else { fails.append("第二次 acquire 應回 .held") }
                if case .alive(let l) = RecordingLeaseHolder.inspect(in: dir) {
                    if l.sessionId != "A" { fails.append("inspect alive 內容不符") }
                } else { fails.append("持鎖時 inspect 應 .alive,得 \(RecordingLeaseHolder.inspect(in: dir))") }
                let later = Date().addingTimeInterval(5)
                holder.heartbeat(now: later)
                if case .alive(let l) = RecordingLeaseHolder.inspect(in: dir) {
                    if l.heartbeatAt != ISO8601.string(later) { fails.append("心跳沒寫進檔:\(l.heartbeatAt)") }
                } else { fails.append("心跳後應仍 .alive") }
                holder.release()
                if RecordingLeaseHolder.inspect(in: dir) != .none { fails.append("release 後 inspect 應 .none") }
                switch RecordingLeaseHolder.acquire(sampleLease("C"), in: dir) {
                case .success(let h2): h2.release()
                case .failure(let e): fails.append("release 後再 acquire 應成功,得 \(e)")
                }
            }
            // 死檔:直接寫一個租約檔、沒人持鎖 ⇒ dead;acquire 清掉後成功。
            let deadURL = RecordingLeaseHolder.leaseURL(in: dir)
            if let data = try? JSONEncoder().encode(sampleLease("DEAD")) { try? data.write(to: deadURL) }
            if case .dead(let l) = RecordingLeaseHolder.inspect(in: dir) {
                if l.sessionId != "DEAD" { fails.append("dead 內容不符") }
            } else { fails.append("沒人持鎖的租約檔應 .dead,得 \(RecordingLeaseHolder.inspect(in: dir))") }
            switch RecordingLeaseHolder.acquire(sampleLease("E"), in: dir) {
            case .success(let h3):
                if case .alive(let l) = RecordingLeaseHolder.inspect(in: dir), l.sessionId == "E" {} else { fails.append("清死檔後應換成 E") }
                h3.release()
            case .failure(let e): fails.append("死檔應被清掉並取得租約,得 \(e)")
            }
        }
        return Result(name: "REC-30 租約 acquire/held/inspect/release/死檔清除(暫存夾)", passed: fails.isEmpty,
                      detail: fails.joined(separator: "; "))
    }

    /// `RecordingLeaseHolder.classify` 判定表(brief §4.1)。
    static func leaseClassify() -> Result {
        var fails: [String] = []
        let l = sampleLease("K")
        let table: [(Int32, Int32, Bool, LeaseInspection)] = [
            (0, 0, true, .dead(l)),
            (0, EWOULDBLOCK, true, .dead(l)),
            (-1, EWOULDBLOCK, true, .alive(l)),
            (-1, ENOTSUP, true, .unreadable(ENOTSUP)),
            (-1, EIO, true, .unreadable(EIO)),
            (0, 0, false, .none),
            (-1, EWOULDBLOCK, false, .none),
        ]
        for (r, e, exists, want) in table {
            let got = RecordingLeaseHolder.classify(flockResult: r, errno: e, fileExists: exists, lease: l)
            if got != want { fails.append("(\(r), \(e), \(exists)) 應 \(want),得 \(got)") }
        }
        // 內容讀不到 ⇒ 占位(sessionId 空,不會誤比對到任何 inprogress 目錄)
        if case .alive(let p) = RecordingLeaseHolder.classify(flockResult: -1, errno: EWOULDBLOCK, fileExists: true, lease: nil) {
            if p != .placeholder { fails.append("讀不到內容應給 placeholder") }
        } else { fails.append("讀不到內容但鎖不到應仍 .alive") }
        return Result(name: "REC-30 租約判定表 classify(flock 結果×errno×檔在不在)", passed: fails.isEmpty,
                      detail: fails.joined(separator: "; "))
    }

    /// REC-38:心跳 > 10 秒 ⇒ 無回應;解不開 ⇒ 視為不新鮮。
    static func heartbeatStale() -> Result {
        var fails: [String] = []
        let now = Date()
        let cases: [(TimeInterval, Bool)] = [(0, false), (9.9, false), (10.5, true), (60, true)]
        for (age, want) in cases {
            let l = sampleLease(heartbeat: now.addingTimeInterval(-age))
            if RecordingLease.isHeartbeatStale(l, now: now) != want { fails.append("心跳 \(age)s 前 應 \(want)") }
        }
        var bad = sampleLease(); bad.heartbeatAt = "不是時間"
        if !RecordingLease.isHeartbeatStale(bad, now: now) { fails.append("heartbeatAt 解不開應視為不新鮮") }
        if RecordingLease.isHeartbeatStale(sampleLease(heartbeat: now.addingTimeInterval(-3)), now: now, threshold: 2) == false {
            fails.append("門檻參數沒生效")
        }
        // 步驟 9:非 owner 端的顯示(computeExternal)——心跳舊 ⇒ unresponsive,但仍是「別人在錄」(不收割)
        let staleLease = sampleLease("X", owner: "cli", heartbeat: now.addingTimeInterval(-30))
        let ext = RecordingController.computeExternal(inspection: .alive(staleLease), state: nil, legacyPID: nil,
                                                      selfSessionId: nil, now: now)
        if ext?.unresponsive != true { fails.append("心跳 30 秒前 ⇒ 外部錄音應標無回應") }
        if ReapPolicy.decide(topLevelCafAge: nil, inspection: .alive(staleLease)) != .skip { fails.append("無回應但鎖仍在 ⇒ 不收割") }
        if RecordingController.computeExternal(inspection: .alive(staleLease), state: nil, legacyPID: nil,
                                               selfSessionId: "X", now: now) != nil { fails.append("自己那場不算外部") }
        let fresh = RecordingController.computeExternal(inspection: .alive(sampleLease("Y", heartbeat: now)), state: nil,
                                                        legacyPID: nil, selfSessionId: nil, now: now)
        if fresh == nil || fresh?.unresponsive == true || fresh?.supportsCommands != true { fails.append("新鮮心跳 ⇒ 外部錄音、可送指令") }
        let legacy = RecordingController.computeExternal(inspection: .none, state: nil, legacyPID: 4242, selfSessionId: nil, now: now)
        if legacy?.lease.pid != 4242 || legacy?.supportsCommands != false { fails.append("舊版 CLI(只有 record.pid)⇒ 外部錄音、只能 SIGINT") }
        if RecordingController.computeExternal(inspection: .dead(staleLease), state: nil, legacyPID: nil, selfSessionId: nil, now: now) != nil {
            fails.append("死租約不算外部錄音")
        }
                // 驗證員 medium:後製期(record.pid 在、租約已釋放、state=postprocessing)不算外部錄音
        let ppState = RecordingStateFile(pid: 4242, startedAt: "", audioPath: "", name: "x", state: "postprocessing", levels: .init(), warning: nil, updatedAt: "")
        if RecordingController.computeExternal(inspection: .none, state: ppState, legacyPID: 4242, selfSessionId: nil, now: Date()) != nil { fails.append("後製期 legacy pid 不該算外部錄音") }
        let recState = RecordingStateFile(pid: 4242, startedAt: "", audioPath: "", name: "x", state: "recording", levels: .init(), warning: nil, updatedAt: "")
        if RecordingController.computeExternal(inspection: .none, state: recState, legacyPID: 4242, selfSessionId: nil, now: Date()) == nil { fails.append("錄音中 legacy pid 應算外部錄音") }
return Result(name: "REC-38 心跳無回應判定(>10 秒)", passed: fails.isEmpty, detail: fails.joined(separator: "; "))
    }
}

// MARK: - REC-31 inprogress 路徑與發布檔名(步驟 3)
extension SelfTest {

    static func inprogressPathAndPublishName() -> Result {
        var fails: [String] = []
        let root = URL(fileURLWithPath: "/r/錄音", isDirectory: true)
        let p = RecordingController.inprogressURL(dir: root, sessionId: "S1")
        if p.path != "/r/錄音/.myparrot/inprogress/S1/audio.caf" { fails.append("inprogress 路徑:\(p.path)") }
        // 舊版收割端只掃頂層(非遞迴、只認 m4a/caf):inprogress 檔不能落在頂層。
        if p.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().standardizedFileURL != root.standardizedFileURL {
            fails.append("inprogress 應在 <dir>/.myparrot/inprogress/<id>/ 下(不在頂層)")
        }
        withScratchDir("publish") { dir in
            let stem = "2026-10-20 1500 週會"
            func name(_ u: URL) -> String { u.lastPathComponent }
            if name(RecordingController.publishURL(dir: dir, stem: stem)) != "\(stem).caf" { fails.append("空資料夾應原名") }
            // 只有自己的筆記 sidecar(錄音中就寫了)⇒ 不避讓自己
            FileManager.default.createFile(atPath: dir.appendingPathComponent("\(stem).notes.md").path, contents: Data("x".utf8))
            if name(RecordingController.publishURL(dir: dir, stem: stem)) != "\(stem).caf" { fails.append("只有 sidecar 不該避讓") }
            // 頂層已有同 stem 音檔(例如舊版 writer 同分鐘同標題)⇒ 加「 2」;再撞 ⇒「 3」
            FileManager.default.createFile(atPath: dir.appendingPathComponent("\(stem).caf").path, contents: Data("x".utf8))
            if name(RecordingController.publishURL(dir: dir, stem: stem)) != "\(stem) 2.caf" { fails.append("撞 .caf 應加 2") }
            FileManager.default.createFile(atPath: dir.appendingPathComponent("\(stem) 2.m4a").path, contents: Data("x".utf8))
            if name(RecordingController.publishURL(dir: dir, stem: stem)) != "\(stem) 3.caf" { fails.append("撞 2.m4a 應加 3") }
        }
        // 步驟 4 真檔發布:暫存夾裡合成 1 秒 inprogress CAF → publishInprogress → 頂層出現、幀數不變、inprogress/<id>/ 清掉。
        withScratchDir("publishReal") { dir in
            let src = RecordingController.inprogressURL(dir: dir, sessionId: "S2")
            guard writeSyntheticCAF(src, seconds: 1) else { fails.append("合成 CAF 失敗"); return }
            switch RecordingController.publishInprogress(src, dir: dir, stem: "2026-10-20 1501 錄音") {
            case .success(let dest):
                if dest.lastPathComponent != "2026-10-20 1501 錄音.caf" { fails.append("發布名:\(dest.lastPathComponent)") }
                let frames = (try? AVAudioFile(forReading: dest))?.length ?? 0
                if frames != 48_000 { fails.append("發布後幀數應 48000,得 \(frames)") }
                if FileManager.default.fileExists(atPath: src.deletingLastPathComponent().path) { fails.append("inprogress/<id>/ 應清掉") }
            case .failure(let e): fails.append("發布失敗:\(e)")
            }
            // 沒有 inprogress 檔(開錄就失敗)⇒ .missing,不建任何頂層檔
            let ghost = RecordingController.inprogressURL(dir: dir, sessionId: "S3")
            if RecordingController.publishInprogress(ghost, dir: dir, stem: "x") != .failure(.missing) { fails.append("沒檔應 .missing") }
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("x.caf").path) { fails.append("沒檔不該長出頂層檔") }
        }
        return Result(name: "REC-31 inprogress 路徑＋發布檔名避讓(只看音檔)＋真檔發布", passed: fails.isEmpty,
                      detail: fails.joined(separator: "; "))
    }

    /// REC-32 收割判定表(`ReapPolicy.decide`)＋修復檔名。
    static func reapDecisionTable() -> Result {
        var fails: [String] = []
        let l = sampleLease("R")
        let day: TimeInterval = 24 * 3600
        let table: [(TimeInterval?, LeaseInspection?, ReapDecision, String)] = [
            // 頂層 .caf:不看租約(舊版 writer 沒租約),只看年齡
            (0, nil, .skip, "剛寫的頂層 caf"),
            (day - 60, LeaseInspection.none, .skip, "未滿 24h 頂層 caf(沒租約也不動)"),
            (day + 60, nil, .manualOnly, "超過 24h 頂層 caf"),
            (day + 60, .alive(l), .manualOnly, "頂層 caf 不看租約"),
            // inprogress
            (nil, .alive(l), .skip, "租約活著"),
            (nil, .dead(l), .repair, "租約死了"),
            (nil, LeaseInspection.none, .repair, "沒有租約檔"),
            (nil, .unreadable(ENOTSUP), .failClosed, "卷不支援"),
            (nil, .unreadable(EIO), .failClosed, "其他 errno"),
            (nil, nil, .failClosed, "沒觀察"),
        ]
        for (age, insp, want, label) in table {
            let got = ReapPolicy.decide(topLevelCafAge: age, inspection: insp)
            if got != want { fails.append("\(label):應 \(want),得 \(got)") }
        }
        if Recording.repairedFileName(stem: "2026-10-20 1500 週會") != "2026-10-20 1500 週會-已修復.caf" {
            fails.append("修復檔名:\(Recording.repairedFileName(stem: "2026-10-20 1500 週會"))")
        }
        // 修復主幹:死租約就是這場 ⇒ 用租約記的名字;否則用檔案時間組「<日期 時間> 錄音」
        var dl = sampleLease("S9"); dl.name = "2026-10-20 1400 客戶會議"
        let a = URL(fileURLWithPath: "/nonexistent/audio.caf")
        if RecordingController.repairStem(sessionId: "S9", audio: a, inspection: .dead(dl)) != "2026-10-20 1400 客戶會議-已修復" {
            fails.append("死租約同場應用租約名")
        }
        let other = RecordingController.repairStem(sessionId: "OTHER", audio: a, inspection: .dead(dl))
        if !other.hasSuffix(" 錄音-已修復") { fails.append("不同場應用時間組名,得 \(other)") }
        // 真檔:暫存夾 inprogress 殘骸(沒有租約檔)⇒ leftovers 列得到;有檔才算
        withScratchDir("reap") { dir in
            writeSyntheticCAF(RecordingController.inprogressURL(dir: dir, sessionId: "A1"), seconds: 0.2)
            try? FileManager.default.createDirectory(at: RecordingController.inprogressRoot(dir: dir).appendingPathComponent("EMPTY"),
                                                     withIntermediateDirectories: true)
            let left = RecordingController.inprogressLeftovers(dir: dir).map(\.sessionId)
            if left != ["A1"] { fails.append("leftovers 應只有 A1,得 \(left)") }
        }
        return Result(name: "REC-32 收割判定表(頂層 caf 年齡 × inprogress 租約觀察)＋修復檔名", passed: fails.isEmpty,
                      detail: fails.joined(separator: "; "))
    }

    /// REC-33:0.01 秒合成 caf 走 `ConversionPolicy.decide` ⇒ quarantine;真檔搬進 `.myparrot/quarantine/`,不刪。
    static func quarantineInsteadOfDelete() -> Result {
        var fails: [String] = []
        let table: [(Int64, ConversionDecision)] = [(0, .quarantine), (480, .quarantine), (2_399, .quarantine),
                                                     (2_400, .convert), (48_000, .convert)]
        for (f, want) in table where ConversionPolicy.decide(frames: f) != want {
            fails.append("\(f) 幀應 \(want)")
        }
        if ConversionPolicy.quarantineMessage(frames: 480) != "錄音太短（480 幀），已移到隔離區" {
            fails.append("訊息:\(ConversionPolicy.quarantineMessage(frames: 480))")
        }
        withScratchDir("quarantine") { dir in
            let caf = dir.appendingPathComponent("2026-10-20 1502 誤觸.caf")
            guard writeSyntheticCAF(caf, seconds: 0.01) else { fails.append("合成失敗"); return }
            let frames = (try? AVAudioFile(forReading: caf))?.length ?? -1
            if frames != 480 { fails.append("0.01 秒應 480 幀,得 \(frames)") }
            guard ConversionPolicy.decide(frames: frames) == .quarantine else { fails.append("0.01 秒應進隔離區"); return }
            do {
                let q = try ConversionPolicy.quarantine(caf, dir: dir)
                if FileManager.default.fileExists(atPath: caf.path) { fails.append("原位置應已搬走") }
                if !FileManager.default.fileExists(atPath: q.path) { fails.append("隔離區沒有檔") }
                if q.deletingLastPathComponent().lastPathComponent != "quarantine" { fails.append("隔離區路徑:\(q.path)") }
                if ((try? AVAudioFile(forReading: q))?.length ?? -1) != 480 { fails.append("隔離後內容應不變") }
                // 同名再來一次 ⇒ 加後綴,不覆蓋
                guard writeSyntheticCAF(caf, seconds: 0.01) else { fails.append("第二次合成失敗"); return }
                let q2 = try ConversionPolicy.quarantine(caf, dir: dir)
                if q2 == q || !FileManager.default.fileExists(atPath: q.path) { fails.append("撞名應加後綴、不覆蓋") }
            } catch {
                fails.append("搬移失敗:\(error)")
            }
        }
        return Result(name: "REC-33 太短的錄音進隔離區不刪(判定＋真檔搬移)", passed: fails.isEmpty,
                      detail: fails.joined(separator: "; "))
    }

    /// REC-36:commands/ 生命週期 issue→pending→complete→wait；.failed；過期/別場拒收；purge。全在暫存夾。
    static func commandLifecycle() -> Result {
        var fails: [String] = []
        withScratchDir("commands") { cfg in
            let dir = cfg.appendingPathComponent("commands", isDirectory: true)
            // 租約活著(owner 在),沒結果 ⇒ wait 逾時 false
            guard case .success(let holder) = RecordingLeaseHolder.acquire(sampleLease("OWN"), in: cfg) else {
                fails.append("暫存夾取租約失敗"); return
            }
            let stop = RecordingCommand(cmd: "stop", args: ["sessionId": "OWN"])
            do { try RecordingCommandStore.issue(stop, in: dir) } catch { fails.append("issue 失敗:\(error)") }
            let p = RecordingCommandStore.pending(in: dir)
            if p.map(\.requestId) != [stop.requestId] { fails.append("pending 應只有 stop,得 \(p.map(\.cmd))") }
            if RecordingCommandStore.wait(stop.requestId, timeout: 0.3, in: dir, leaseDir: cfg) { fails.append("owner 沒處理前 wait 應逾時") }
            RecordingCommandStore.complete(stop.requestId, ok: true, result: "/r/x.caf", in: dir)
            if !RecordingCommandStore.pending(in: dir).isEmpty { fails.append("complete 後 pending 應空") }
            if !RecordingCommandStore.wait(stop.requestId, timeout: 1, in: dir, leaseDir: cfg) { fails.append("有 .done 應 wait true") }
            if RecordingCommandStore.result(stop.requestId, in: dir)?.ok != true { fails.append(".done 應 ok") }
            if !FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(stop.requestId).done").path) { fails.append("應有 .done 檔") }
            // 失敗 ⇒ .failed
            let bad = RecordingCommand(cmd: "pause")
            try? RecordingCommandStore.issue(bad, in: dir)
            RecordingCommandStore.complete(bad.requestId, ok: false, result: "not recording", in: dir)
            if RecordingCommandStore.result(bad.requestId, in: dir)?.ok != false { fails.append(".failed 應 ok=false") }
            if !FileManager.default.fileExists(atPath: dir.appendingPathComponent("\(bad.requestId).failed").path) { fails.append("應有 .failed 檔") }
            // 租約釋放(owner 收尾/死了)⇒ 沒結果也 wait true
            let orphan = RecordingCommand(cmd: "stop")
            try? RecordingCommandStore.issue(orphan, in: dir)
            holder.release()
            if !RecordingCommandStore.wait(orphan.requestId, timeout: 1, in: dir, leaseDir: cfg) { fails.append("租約釋放後 wait 應 true") }
            // 拒收規則
            let start = Date()
            if RecordingCommand.rejection(RecordingCommand(cmd: "stop", args: ["sessionId": "S"]), sessionId: "S", sessionStartedAt: start.addingTimeInterval(-5)) != nil {
                fails.append("本場、開錄後的 stop 應執行")
            }
            if RecordingCommand.rejection(RecordingCommand(cmd: "stop", args: ["sessionId": "OTHER"]), sessionId: "S", sessionStartedAt: start.addingTimeInterval(-5)) == nil {
                fails.append("別場的指令應拒收")
            }
            let stale = RecordingCommand(cmd: "stop", issuedAt: ISO8601.string(start.addingTimeInterval(-600)))
            if RecordingCommand.rejection(stale, sessionId: "S", sessionStartedAt: start) == nil { fails.append("早於開錄的指令應過期") }
            if RecordingCommand.rejection(RecordingCommand(cmd: "rm -rf"), sessionId: "S", sessionStartedAt: start.addingTimeInterval(-5)) == nil {
                fails.append("不支援的指令應拒收")
            }
            // purge:把檔案時間撥回兩小時前 ⇒ 清掉;新的留著
            let fresh = RecordingCommand(cmd: "mark")
            try? RecordingCommandStore.issue(fresh, in: dir)
            let old = Date().addingTimeInterval(-7200)
            for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where !name.hasPrefix(fresh.requestId) {
                try? FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: dir.appendingPathComponent(name).path)
            }
            RecordingCommandStore.purge(olderThan: 3600, in: dir)
            let left = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            if left != ["\(fresh.requestId).json"] { fails.append("purge 後應只剩新的,得 \(left)") }
        }
        return Result(name: "REC-36 指令檔生命週期(issue→pending→done/failed→wait；拒收；purge)", passed: fails.isEmpty,
                      detail: fails.joined(separator: "; "))
    }

    /// 合成立體聲 48k float CAF(左 440Hz、右 660Hz 弱訊號);函式結束時 AVAudioFile deinit 收檔。
    @discardableResult
    static func writeSyntheticCAF(_ url: URL, seconds: Double) -> Bool {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false) else { return false }
        let n = AVAudioFrameCount(seconds * 48_000)
        do {
            let f = try AVAudioFile(forWriting: url, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            guard n > 0 else { return true }
            guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: n), let ch = buf.floatChannelData else { return false }
            buf.frameLength = n
            for i in 0..<Int(n) {
                ch[0][i] = 0.1 * sinf(Float(i) * 2 * .pi * 440 / 48_000)
                ch[1][i] = 0.1 * sinf(Float(i) * 2 * .pi * 660 / 48_000)
            }
            try f.write(from: buf)
            return true
        } catch { return false }
    }
}

// MARK: - C2(#2646,Eric 2026-10-29 16:36):協定檔搬進 <錄音夾>/.myparrot

extension SelfTest {
    /// REC-40:協定目錄＝`<錄音夾>/.myparrot`;不同錄音夾的租約互不可見、同一夾可見;state.json／commands 也在那。
    static func protocolDirRules() -> Result {
        var fails: [String] = []
        withScratchDir("c2") { root in
            let a = root.appendingPathComponent("A", isDirectory: true), b = root.appendingPathComponent("B", isDirectory: true)
            if MyParrotPaths.protocolDir(for: a).path != a.appendingPathComponent(".myparrot").path { fails.append("protocolDir 應為 <夾>/.myparrot") }
            let lease = RecordingLease.make(sessionId: "s-a", owner: "gui", name: "x", audioPath: "/tmp/x.caf")
            guard case .success(let holder) = RecordingLeaseHolder.acquire(lease, in: MyParrotPaths.protocolDir(for: a)) else {
                fails.append("A 夾取租約失敗"); return
            }
            if case .alive = RecordingLeaseHolder.inspect(in: MyParrotPaths.protocolDir(for: b)) { fails.append("B 夾不該看到 A 夾的租約") }
            if case .alive(let l) = RecordingLeaseHolder.inspect(in: MyParrotPaths.protocolDir(for: a)) {
                if l.sessionId != "s-a" { fails.append("A 夾租約 sessionId 不符") }
            } else { fails.append("A 夾應看到活租約") }
            // 同一個進程換錄音夾 ⇒ currentRecordingsDir 跟著換,預設目錄就跟著換
            let before = MyParrotPaths.currentRecordingsDir
            MyParrotPaths.currentRecordingsDir = b
            if RecordingLeaseHolder.directory().path != MyParrotPaths.protocolDir(for: b).path { fails.append("directory() 應跟 currentRecordingsDir 走") }
            if RecordingCommandStore.directory().path != MyParrotPaths.protocolDir(for: b).appendingPathComponent("commands").path { fails.append("commands 應在 <夾>/.myparrot/commands") }
            if RecordingStateStore.statePath.path != MyParrotPaths.protocolDir(for: b).appendingPathComponent("state.json").path { fails.append("state.json 應在 <夾>/.myparrot") }
            if !RecordingStateStore.pidfilePath.path.hasSuffix("record.pid") || RecordingStateStore.pidfilePath.path.contains(b.path) { fails.append("record.pid 應留在 configDir(舊版相容)") }
            MyParrotPaths.currentRecordingsDir = before
            holder.release()
        }
        return Result(name: "REC-40 協定檔在 <錄音夾>/.myparrot", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "A/B 兩夾互不可見;directory/commands/state 跟錄音夾走;record.pid 留 configDir" : fails.joined(separator: ";"))
    }

    /// REC-41:舊位置(~/.config/myparrot)的活租約仍被當外部錄音(10/20 版 CLI 相容);新位置有活租約優先;都死 ⇒ 回新位置的結果。
    static func legacyLeaseFallback() -> Result {
        var fails: [String] = []
        let C = RecordingController.self
        let newL = RecordingLease.make(sessionId: "new", owner: "cli", name: "n", audioPath: "/tmp/n.caf")
        let oldL = RecordingLease.make(sessionId: "old", owner: "cli", name: "o", audioPath: "/tmp/o.caf")
        func sid(_ i: LeaseInspection) -> String? { if case .alive(let l) = i { return l.sessionId }; return nil }
        if sid(C.effectiveInspection(primary: .alive(newL), legacy: .alive(oldL))) != "new" { fails.append("兩邊都活應取新位置") }
        if sid(C.effectiveInspection(primary: .none, legacy: .alive(oldL))) != "old" { fails.append("新位置沒有、舊位置活著應取舊位置(正控)") }
        if sid(C.effectiveInspection(primary: .dead(newL), legacy: .alive(oldL))) != "old" { fails.append("新位置死、舊位置活應取舊位置") }
        if case .dead = C.effectiveInspection(primary: .dead(newL), legacy: .none) {} else { fails.append("都沒活應回新位置的 dead") }
        if case .none = C.effectiveInspection(primary: .none, legacy: .none) {} else { fails.append("都沒有應回 none") }
        return Result(name: "REC-41 舊位置租約相容", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "新活>舊活>新 dead/none 五組" : fails.joined(separator: ";"))
    }
}
