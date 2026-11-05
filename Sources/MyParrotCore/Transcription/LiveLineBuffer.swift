import Foundation

/// TR-29(#2672):即時逐字稿的行緩衝,純邏輯、不碰執行緒。
///
/// 10/31 真機發現:同一行程「停止 → 新錄音 → 再錄」,第二段的 .txt／.srt 開頭混進第一段的行。
/// 兩個來源:(1)`SpeechAnalyzerLiveTranscriber` 的行列表在 `start()` 沒清;(2)前一段 `stop()` 後
/// `finalizeAndFinishThroughEndOfInput` 晚到的定稿仍走同一個 commit。這裡用 generation 一次擋掉兩者:
/// `reset()` 每次開錄呼叫並回新代,Channel 回呼帶建立當下的代;舊代的 commit 回 nil、什麼都不動。
/// 三個即時引擎都用它(各自包在 `OSAllocatedUnfairLock` 裡),合併規則只剩這一份。
struct LiveLineBuffer: Sendable {
    private(set) var lines: [TranscriptLine] = []
    private(set) var generation: Int = 0

    /// 開錄:清空並換代。回新 generation,給這一段的回呼帶著。
    mutating func reset() -> Int {
        lines = []
        generation += 1
        return generation
    }

    /// 回 nil ＝ 舊代(或還沒 reset 過),沒動任何東西;否則回更新後的快照。
    /// 規則與原三個引擎的 commit 一致:同說話者的非定稿行取代(空字串＝移除)、否則非空就追加、依 time 排序。
    mutating func commit(_ line: TranscriptLine, generation gen: Int) -> [TranscriptLine]? {
        guard generation > 0, gen == generation else { return nil }   // 0＝還沒 reset 過,不配發
        if let idx = lines.lastIndex(where: { $0.isYou == line.isYou && !$0.isFinal }) {
            if line.text.isEmpty { lines.remove(at: idx) } else { lines[idx] = line }
        } else if !line.text.isEmpty {
            lines.append(line)
        }
        lines.sort { $0.time < $1.time }
        return lines
    }
}

/// TR-31(#2676):`LiveLineBuffer` 的外層——**開著的本段**與**已關、還在收尾的前段**分流,純邏輯、不碰執行緒。
///
/// TR-29 之後,stop() 後才到的定稿帶舊代、被整個忽略;但 Apple SpeechAnalyzer 只在句界定稿,
/// 「一句話接著靜音到停止」整句都是停止之後才定稿 ⇒ 短錄一句就停,整段沒有 `.txt`。
/// 這裡把「舊代」再分兩種:`close()` 過、還沒被 `takeClosing` 取走的那一段 ⇒ 行照代數收進 `closing[gen]`、
/// **不上屏**(回 `.closing`);取走之後(或根本沒 close 過)才來的 ⇒ `.stale`。
/// 三個即時引擎都用它(各自包在 `OSAllocatedUnfairLock` 裡),收尾的回呼由 `LiveStopDrain` 負責。
struct LiveLineStore: Sendable {
    /// `commit` 的去向。
    enum Route: Equatable, Sendable {
        /// 開著的本段:帶更新後的快照,呼叫端上屏。
        case active([TranscriptLine])
        /// 已關、還在收尾的那一段:收下了,不上屏。
        case closing
        /// 取走後才到、或從沒 close 過的代:什麼都沒動。
        case stale
    }

    private var active = LiveLineBuffer()
    private(set) var isOpen = false
    private(set) var closing: [Int: LiveLineBuffer] = [:]

    /// 目前這段的代(0＝還沒 start 過)。
    var generation: Int { active.generation }
    /// 開著的本段目前的行。
    var lines: [TranscriptLine] { active.lines }

    /// 開錄:清空、換代、標開著。回新代給這一段的回呼帶著。
    /// 沒 `close()` 就再 `start()` ⇒ 上一段的行直接丟掉(呼叫端要保留就先 close)。
    mutating func start() -> Int {
        let gen = active.reset()
        isOpen = true
        return gen
    }

    /// 停止:把開著的本段原樣搬進 `closing[gen]`,之後同代的 commit 走 `.closing`。回該代;沒開著 ⇒ nil。
    mutating func close() -> Int? {
        guard isOpen else { return nil }
        isOpen = false
        closing[active.generation] = active
        return active.generation
    }

    /// 依代數分流;合併規則仍是 `LiveLineBuffer.commit` 那一份。
    mutating func commit(_ line: TranscriptLine, generation gen: Int) -> Route {
        if isOpen, gen == active.generation {
            return active.commit(line, generation: gen).map(Route.active) ?? .stale
        }
        guard var buf = closing[gen] else { return .stale }
        _ = buf.commit(line, generation: gen)
        closing[gen] = buf
        return .closing
    }

    /// 取走已關那段的完整行列表(含停止前就在的);之後同代的 commit ⇒ `.stale`。沒這一段 ⇒ nil。
    mutating func takeClosing(_ gen: Int) -> [TranscriptLine]? {
        closing.removeValue(forKey: gen)?.lines
    }
}

/// TR-31:「N 方都到了、或超時」⇒ 恰好觸發一次。純邏輯;`LiveStopDrain` 把它包在鎖裡用。
struct OnceJoin: Sendable {
    let expected: Int
    private(set) var arrived = 0
    private(set) var fired = false

    init(expected: Int) { self.expected = max(0, expected) }

    var isComplete: Bool { arrived >= expected }

    /// 一方到了。回 true ＝ 此刻該觸發(只會回一次 true)。
    mutating func arrive() -> Bool {
        arrived += 1
        return fireIfComplete()
    }

    /// 期待數已滿(含 expected 0)就觸發;回 true ＝ 此刻該觸發。
    mutating func fireIfComplete() -> Bool {
        guard isComplete, !fired else { return false }
        fired = true
        return true
    }

    /// 超時:沒觸發過就觸發。回 true ＝ 此刻該觸發。
    mutating func timeout() -> Bool {
        guard !fired else { return false }
        fired = true
        return true
    }
}
