import Foundation

/// TR-29(#2672):`LiveLineBuffer` 的純函式案例——換代後舊代定稿進不來、三條合併規則不變、依時間排序。
/// 真路徑(同一行程連錄兩段、第二段檔案不含第一段的行)在 TEST_REPORT「TR-29」節真機驗。
extension SelfTest {

    static func liveLineBuffer() -> Result {
        var fails: [String] = []
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        func line(_ text: String, you: Bool, final: Bool, at sec: TimeInterval) -> TranscriptLine {
            TranscriptLine(isYou: you, time: t0.addingTimeInterval(sec), text: text, isFinal: final)
        }
        var buf = LiveLineBuffer()

        // 還沒 reset 過:任何代都進不來(generation 0 不配發)。
        if buf.commit(line("x", you: false, final: true, at: 0), generation: 0) != nil {
            fails.append("reset 前 commit 應回 nil")
        }

        // 第一段:非定稿取代 → 定稿取代非定稿 → 另一說話者追加 → 空字串移除。
        let g1 = buf.reset()
        _ = buf.commit(line("a", you: false, final: false, at: 1), generation: g1)
        let s1 = buf.commit(line("ab", you: false, final: false, at: 1), generation: g1)
        if s1?.count != 1 || s1?.first?.text != "ab" { fails.append("非定稿應取代同說話者非定稿:\(s1?.map(\.text) ?? [])") }
        let s2 = buf.commit(line("abc", you: false, final: true, at: 1), generation: g1)
        if s2?.count != 1 || s2?.first?.isFinal != true { fails.append("定稿應取代同說話者非定稿:\(s2?.map(\.text) ?? [])") }
        let s3 = buf.commit(line("y", you: true, final: false, at: 2), generation: g1)
        if s3?.count != 2 { fails.append("另一說話者應追加:\(s3?.count ?? -1)") }
        let s4 = buf.commit(line("", you: true, final: false, at: 2), generation: g1)
        if s4?.count != 1 { fails.append("空字串應移除該說話者非定稿:\(s4?.count ?? -1)") }
        let s5 = buf.commit(line("", you: true, final: true, at: 3), generation: g1)
        if s5?.count != 1 { fails.append("沒有非定稿可取代時,空字串不追加:\(s5?.count ?? -1)") }
        // 排序:晚 commit 但時間早的定稿要排前面。
        let s6 = buf.commit(line("early", you: true, final: true, at: 0.5), generation: g1)
        if s6?.map(\.text) != ["early", "abc"] { fails.append("應依 time 排序:\(s6?.map(\.text) ?? [])") }

        // 舊代 commit:回 nil、內容不動。
        if buf.commit(line("stale", you: false, final: true, at: 9), generation: g1 - 1) != nil {
            fails.append("舊代 commit 應回 nil")
        }
        if buf.lines.map(\.text) != ["early", "abc"] { fails.append("舊代 commit 不得改內容:\(buf.lines.map(\.text))") }

        // 第二段(#2672 情境):reset 後空;第一段晚到的定稿(帶 g1)進不來;新代才算。
        let g2 = buf.reset()
        if g2 == g1 { fails.append("reset 應換代") }
        if !buf.lines.isEmpty { fails.append("reset 後應為空:\(buf.lines.count)") }
        if buf.commit(line("late-final-from-seg1", you: true, final: true, at: 4), generation: g1) != nil {
            fails.append("前一段晚到的定稿(舊代)應被忽略")
        }
        if !buf.lines.isEmpty { fails.append("舊代定稿不得落進新段:\(buf.lines.map(\.text))") }
        let s7 = buf.commit(line("seg2", you: false, final: true, at: 100), generation: g2)
        if s7?.map(\.text) != ["seg2"] { fails.append("新段第一行應只有自己:\(s7?.map(\.text) ?? [])") }

        return Result(name: "TR-29 即時稿行緩衝換代", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "g1=\(g1) g2=\(g2);舊代忽略、三規則、排序皆符" : fails.joined(separator: ";"))
    }
}

/// TR-31(#2676):`LiveLineStore` 的分流與 `OnceJoin` 的「恰好一次」。
/// 真路徑(Apple 引擎一句就停 ⇒ 幾秒後 .txt 補到;停完立刻開新錄音兩段不混)在 TEST_REPORT「TR-31」節真機驗。
extension SelfTest {

    static func liveLineStore() -> Result {
        var fails: [String] = []
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        func line(_ text: String, you: Bool = false, final: Bool = true, at sec: TimeInterval) -> TranscriptLine {
            TranscriptLine(isYou: you, time: t0.addingTimeInterval(sec), text: text, isFinal: final)
        }
        func texts(_ r: LiveLineStore.Route) -> [String]? { if case .active(let l) = r { return l.map(\.text) }; return nil }
        var store = LiveLineStore()

        // 沒 start 過:commit 什麼代都是 stale;close 回 nil、不產生 closing。
        if store.commit(line("x", at: 0), generation: 0) != .stale { fails.append("start 前 commit 應 stale") }
        if store.close() != nil || !store.closing.isEmpty { fails.append("沒 start 就 close 不得產生 closing") }

        // 第一段開著:同代 commit 上屏(active 帶快照);暫定行照 LiveLineBuffer 規則取代。
        let g1 = store.start()
        if !store.isOpen || g1 <= 0 { fails.append("start 後應開著且代 > 0") }
        if texts(store.commit(line("a", final: false, at: 1), generation: g1)) != ["a"] { fails.append("本段暫定行應 active") }
        if texts(store.commit(line("a1", at: 1), generation: g1)) != ["a1"] { fails.append("本段定稿應取代暫定並 active") }
        if store.commit(line("not-mine", at: 1), generation: g1 + 7) != .stale { fails.append("未知代應 stale") }

        // stop:close 回同代;之後同代 commit ⇒ closing(不上屏、但收進那一段);本段 lines 不再變。
        guard store.close() == g1 else { fails.append("close 應回 g1"); return Result(name: "TR-31 即時稿收尾分流", passed: false, detail: fails.joined(separator: ";")) }
        if store.isOpen { fails.append("close 後不得仍開著") }
        let tailRoute = store.commit(line("tail-after-stop", you: true, at: 2), generation: g1)
        if tailRoute != .closing { fails.append("停止後同代定稿應進 closing:\(tailRoute)") }
        if store.lines.map(\.text) != ["a1"] { fails.append("closing 的行不得上屏(active lines 變了):\(store.lines.map(\.text))") }
        if store.closing[g1]?.lines.map(\.text) != ["a1", "tail-after-stop"] { fails.append("closing[g1] 應含停止前的行＋晚到定稿:\(store.closing[g1]?.lines.map(\.text) ?? [])") }

        // 第二段開錄(停完 1 秒內 new＋錄 B 的情境):新代 commit 走 active 且不含第一段;第一段晚到的行仍進它的 closing。
        let g2 = store.start()
        if g2 == g1 { fails.append("start 應換代") }
        if texts(store.commit(line("b", at: 100), generation: g2)) != ["b"] { fails.append("新段 commit 應 active 且只有自己") }
        if store.commit(line("tail2", at: 3), generation: g1) != .closing { fails.append("新段開著時,第一段晚到的行仍應進 closing") }
        if store.lines.map(\.text) != ["b"] { fails.append("第一段晚到的行不得混進第二段:\(store.lines.map(\.text))") }

        // take:拿到完整行列表(含停止前的);之後同代 ⇒ stale;closing 清掉;第二段不受影響。
        let taken = store.takeClosing(g1)?.map(\.text)
        if taken != ["a1", "tail-after-stop", "tail2"] { fails.append("takeClosing 應回第一段完整行列表:\(taken ?? [])") }
        if store.commit(line("too-late", at: 4), generation: g1) != .stale { fails.append("取走後同代應 stale") }
        if store.takeClosing(g1) != nil { fails.append("取走後再 take 應 nil") }
        if !store.closing.isEmpty { fails.append("closing 應已清空:\(store.closing.keys.sorted())") }
        if store.lines.map(\.text) != ["b"] || store.generation != g2 || !store.isOpen { fails.append("第二段狀態不得受 take 影響") }

        // 沒 close 就再 start(重入):上一段的行直接丟、不產生 closing。
        let g3 = store.start()
        if store.closing[g2] != nil || !store.lines.isEmpty || g3 == g2 { fails.append("重入 start 不得留下 closing、應清空換代") }

        return Result(name: "TR-31 即時稿收尾分流", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "g1=\(g1) g2=\(g2) g3=\(g3);closing 分流、take 一次、stale 皆符" : fails.joined(separator: ";"))
    }

    static func onceJoin() -> Result {
        var fails: [String] = []
        // 兩方都到才觸發,只觸發一次;之後超時／再到都不再觸發。
        var j2 = OnceJoin(expected: 2)
        if j2.fireIfComplete() { fails.append("期待 2、0 到不得觸發") }
        if j2.arrive() { fails.append("期待 2、1 到不得觸發") }
        if !j2.arrive() { fails.append("期待 2、2 到應觸發") }
        if j2.arrive() || j2.timeout() || j2.fireIfComplete() { fails.append("觸發過不得再觸發(arrive/timeout/fireIfComplete)") }
        if j2.arrived != 3 || !j2.fired { fails.append("計數應續記 3、fired 應 true:\(j2.arrived) \(j2.fired)") }
        // 一到＋超時:超時觸發一次;晚到的第二方不再觸發。
        var j1 = OnceJoin(expected: 2)
        _ = j1.arrive()
        if !j1.timeout() { fails.append("1 到後超時應觸發") }
        if j1.arrive() || j1.timeout() { fails.append("超時觸發後,晚到／再超時不得再觸發") }
        // 期待 0(沒有聲道在跑):fireIfComplete 立刻觸發一次。
        var j0 = OnceJoin(expected: 0)
        if !j0.fireIfComplete() { fails.append("期待 0 應立刻觸發") }
        if j0.fireIfComplete() || j0.timeout() { fails.append("期待 0 觸發後不得再觸發") }
        // 負數視為 0。
        var jn = OnceJoin(expected: -3)
        if jn.expected != 0 || !jn.fireIfComplete() { fails.append("負數期待應視為 0") }
        return Result(name: "TR-31 收尾恰好一次(OnceJoin)", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "2 到／1 到＋超時／0 期待皆恰好一次" : fails.joined(separator: ";"))
    }

    static func lateLiveFlushDecision() -> Result {
        var fails: [String] = []
        typealias R = LateLiveFlush.SidecarRead
        let w = (txt: "你: 一", srt: "1\n00:00:01,000 --> 00:00:02,000\n你: 一\n\n")
        let same = (txt: R.content(w.txt), srt: R.content(w.srt))
        func check(_ label: String, _ got: LateLiveFlush.Decision, write: Bool) {
            switch (got, write) {
            case (.write, true), (.skip, false): break
            default: fails.append("\(label):\(got)")
            }
        }
        func d(_ after: Int, _ atStop: Int, _ written: (txt: String, srt: String)?, _ txt: R, _ srt: R, listed: Bool = true) -> LateLiveFlush.Decision {
            LateLiveFlush.decide(finalsAfter: after, finalsAtStop: atStop, writtenAtStop: written, txtOnDisk: txt, srtOnDisk: srt, recordingListed: listed)
        }
        // 一句就停(審查員路徑):停止時沒落檔、現在也沒檔、收尾多 1 行 ⇒ 寫。
        check("短錄一句", d(1, 0, nil, .missing, .missing), write: true)
        // 停止時沒落檔,但現在 .txt 已存在(別人寫的)⇒ 不碰。
        check("停止時沒檔、現在有檔", d(1, 0, nil, .content("MARKER"), .missing), write: false)
        // 多句:停止時寫了 2 行、收尾 3 行、檔案原樣 ⇒ 寫。
        check("多句尾句補寫", d(3, 2, w, same.txt, same.srt), write: true)
        // .txt 被改(重轉／校正)⇒ 不碰;.srt 被改 ⇒ 不碰;兩個檔都被刪 ⇒ 不碰;只剩一份 ⇒ 不碰。
        check("txt 已改", d(3, 2, w, .content("你: 一\n你: 高精度"), same.srt), write: false)
        check("srt 已改", d(3, 2, w, same.txt, .content("")), write: false)
        check("檔已刪", d(3, 2, w, .missing, .missing), write: false)
        check("只剩 txt", d(3, 2, w, same.txt, .missing), write: false)
        // 二審:讀不到(權限／非 UTF-8／I/O)不是「不存在」——就算停止時沒寫也不准寫。
        check("txt 讀失敗", d(1, 0, nil, .readFailure("EACCES"), .missing), write: false)
        check("srt 讀失敗", d(3, 2, w, same.txt, .readFailure("bad utf8")), write: false)
        // 沒多出定稿(相等或更少)⇒ 不碰,就算檔案原樣。
        check("行數相等", d(2, 2, w, same.txt, same.srt), write: false)
        check("行數更少", d(1, 2, w, same.txt, same.srt), write: false)
        check("收尾 0 行", d(0, 0, nil, .missing, .missing), write: false)
        // 錄音已不在列表(停止後立刻丟垃圾桶)⇒ 不碰。
        check("錄音不在列表", d(3, 2, w, same.txt, same.srt, listed: false), write: false)
        // 理由字串非空(要進 log)。
        if case .skip(let why) = d(3, 2, w, .content("x"), same.srt), why.isEmpty { fails.append("skip 理由不得為空") }
        // read():不存在 ⇒ missing;存在且 UTF-8 ⇒ content;存在但不是 UTF-8 ⇒ readFailure(用暫存夾真檔)。
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp-tr31-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        if LateLiveFlush.read(dir.appendingPathComponent("none.txt")) != .missing { fails.append("不存在應 missing") }
        let ok = dir.appendingPathComponent("ok.txt"); try? "你: 一".write(to: ok, atomically: true, encoding: .utf8)
        if LateLiveFlush.read(ok) != .content("你: 一") { fails.append("UTF-8 檔應 content") }
        let bad = dir.appendingPathComponent("bad.txt"); try? Data([0xFF, 0xFE, 0x00, 0xC3]).write(to: bad)
        if case .readFailure = LateLiveFlush.read(bad) {} else { fails.append("非 UTF-8 檔應 readFailure:\(LateLiveFlush.read(bad))") }
        return Result(name: "TR-31 停止後補寫決策", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "寫 2 例、不碰 11 例、read 三態皆符" : fails.joined(separator: ";"))
    }

    /// TR-31 二審第二輪:`.txt`／`.srt` 成對寫入——第二份失敗要把第一份還原(原本有 ⇒ 舊內容、原本沒有 ⇒ 移掉)。
    static func sidecarPairWrite() -> Result {
        var fails: [String] = []
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("mp-tr31-pair-\(UUID().uuidString)", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let lines = [TranscriptLine(isYou: true, time: t0, text: "一", isFinal: true, start: 1, duration: 1),
                     TranscriptLine(isYou: false, time: t0.addingTimeInterval(3), text: "二", isFinal: true, start: 3, duration: 1)]
        func read(_ url: URL) -> String? { try? String(contentsOf: url, encoding: .utf8) }

        // 正常:兩份都出現、內容＝回傳值、.txt 格式「你: ／對方: 」。
        let okStem = dir.appendingPathComponent("ok")
        let okTxt = SidecarSet.url(stem: okStem, ext: "txt"), okSrt = SidecarSet.url(stem: okStem, ext: "srt")
        guard let out = TranscriptSidecarWriter.write(lines, stem: okStem) else {
            return Result(name: "TR-31 逐字稿成對寫入", passed: false, detail: "正常寫入回 nil")
        }
        if read(okTxt) != out.txt || read(okSrt) != out.srt { fails.append("磁碟內容應等於回傳值") }
        if out.txt != "你: 一\n對方: 二" { fails.append(".txt 格式不符:\(out.txt)") }
        if !out.srt.contains("你: 一") || !out.srt.contains("對方: 二") { fails.append(".srt 應含兩個 cue") }

        // 既有兩檔 ＋ 第二份寫失敗(.srt 位置是個目錄):.txt 要還原成舊內容、回 nil。
        let s2 = dir.appendingPathComponent("pair")
        let txt2 = SidecarSet.url(stem: s2, ext: "txt"), srt2 = SidecarSet.url(stem: s2, ext: "srt")
        try? "OLD-TXT".write(to: txt2, atomically: true, encoding: .utf8)
        try? fm.createDirectory(at: srt2, withIntermediateDirectories: true)   // 寫檔到這裡會失敗(是目錄)
        try? "x".write(to: srt2.appendingPathComponent("keep"), atomically: true, encoding: .utf8)
        if TranscriptSidecarWriter.write(lines, stem: s2) != nil { fails.append(".srt 寫失敗應回 nil") }
        if read(txt2) != "OLD-TXT" { fails.append("第二份失敗後 .txt 應還原成舊內容:\(read(txt2) ?? "nil")") }
        var isDir: ObjCBool = false
        if !fm.fileExists(atPath: srt2.path, isDirectory: &isDir) || !isDir.boolValue { fails.append(".srt 位置應維持原樣(目錄)") }

        // 原本沒有 .txt ＋ 第二份寫失敗:剛寫的 .txt 要移掉、回 nil。
        let s3 = dir.appendingPathComponent("fresh")
        let txt3 = SidecarSet.url(stem: s3, ext: "txt"), srt3 = SidecarSet.url(stem: s3, ext: "srt")
        try? fm.createDirectory(at: srt3, withIntermediateDirectories: true)
        if TranscriptSidecarWriter.write(lines, stem: s3) != nil { fails.append("fresh:.srt 寫失敗應回 nil") }
        if fm.fileExists(atPath: txt3.path) { fails.append("原本沒有 .txt 時失敗後不得留下 .txt") }

        // 既有 .txt 備份不了(.txt 位置是目錄 ⇒ 存在但讀不出內容):寫任何東西之前就失敗、.srt 不得出現(二審第三輪)。
        let s4 = dir.appendingPathComponent("unreadable")
        let txt4 = SidecarSet.url(stem: s4, ext: "txt"), srt4 = SidecarSet.url(stem: s4, ext: "srt")
        try? fm.createDirectory(at: txt4, withIntermediateDirectories: true)
        try? "x".write(to: txt4.appendingPathComponent("keep"), atomically: true, encoding: .utf8)
        if TranscriptSidecarWriter.write(lines, stem: s4) != nil { fails.append("既有 .txt 讀不出來應回 nil") }
        if fm.fileExists(atPath: srt4.path) { fails.append("既有 .txt 讀不出來時不得寫 .srt") }
        if !fm.fileExists(atPath: txt4.appendingPathComponent("keep").path) { fails.append("既有 .txt(目錄)不得被動") }

        return Result(name: "TR-31 逐字稿成對寫入", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "正常成對;第二份失敗還原舊 .txt／移掉新 .txt;既有 .txt 備份不了一份都不寫" : fails.joined(separator: ";"))
    }
}
