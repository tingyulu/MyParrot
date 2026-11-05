import Foundation

/// #2438 Phase 2 會議記錄真後端(P 節)的純函式案例:MIN-01／02／03 提示詞範圍、參數鎖定、schema、解析;
/// MIN-04／05／09 滾動決策與 `.minutes.json` 相容。假 `claude` 腳本的真路徑案例在 Tests/MinutesCLITests。
extension SelfTest {

    /// MIN-01／02／03 靜態部分:提示詞只由 input 三段組成、不含本機帳目、參數九旗標齊、schema 五格鎖死。含正控組。
    static func minutesPromptAndArgs() -> Result {
        var fails: [String] = []
        let when = Date(timeIntervalSince1970: 1_760_900_000)
        let previous = MinutesDocument(summary: "舊摘要", decisions: ["決議甲"], actions: [], questions: ["問題乙"],
                                       timeline: ["0:00:01 開場"], updatedAt: when, inputTokens: 999, outputTokens: 777,
                                       transcriptLinesConsumed: 7)
        let input = MinutesInput(previous: previous,
                                 transcriptDelta: ["對方 0:00:05: 今天討論預算", "你 0:00:09: 好", "   "],
                                 notes: "# 週會\n- 重點一\n", language: .zhTW)
        let user = MinutesPrompt.user(input)
        for need in [MinutesPrompt.previousMarker, "舊摘要", "決議甲", "問題乙", "0:00:01 開場",
                     MinutesPrompt.transcriptMarker, "對方 0:00:05: 今天討論預算", "你 0:00:09: 好",
                     MinutesPrompt.notesMarker, "# 週會", "重點一"] where !user.contains(need) {
            fails.append("提示詞缺 \(need)")
        }
        for leak in ["updatedAt", "inputTokens", "outputTokens", "transcriptLinesConsumed", "999", "777"] where user.contains(leak) {
            fails.append("提示詞含本機帳目 \(leak)")
        }
        if user.contains("\n   \n") { fails.append("空白逐字稿行沒濾掉") }
        // 沒筆記 ⇒ 整段省略;沒上一版／沒新行 ⇒ (none)
        let bare = MinutesPrompt.user(MinutesInput(transcriptDelta: [], notes: "  \n"))
        if bare.contains(MinutesPrompt.notesMarker) { fails.append("空筆記仍送出筆記段") }
        if bare.components(separatedBy: MinutesPrompt.noneMarker).count != 3 { fails.append("沒上一版／沒新行應各放 \(MinutesPrompt.noneMarker)") }
        // 資料範圍檢查器 + 正控組:同一個檢查器對「塞了檔名」的提示詞必須抓到
        let sentinel = "會議檔名哨兵-2026-10-19"
        func violations(_ s: String) -> [String] {
            ["/Users", ".m4a", sentinel, "/Documents/"].filter { s.contains($0) }
        }
        if !violations(user).isEmpty { fails.append("提示詞含路徑/檔名 \(violations(user))") }
        if violations(user + "\n/Users/x/Documents/\(sentinel).m4a").count != 4 { fails.append("正控組:檢查器沒抓到塞進去的檔名") }
        // 系統提示分語言、都講 JSON
        let zh = MinutesPrompt.system(for: .zhTW), en = MinutesPrompt.system(for: .en)
        if zh == en || !zh.contains("JSON") || !en.contains("JSON") || !zh.contains(MinutesPrompt.notesMarker) { fails.append("系統提示語言/標記不對") }
        // AFM-13(#2667):`isChinese` 是 AFM 後端挑 @Guide 描述語言的唯一判準,逐語言釘它等於兩個 system prompt 的 zh 分支(分歧就紅,不靜默)。
        let corrZh = CorrectionPrompt.system(for: .zhTW)
        for lang in TranscriptionLanguage.allCases {
            let minutesIsZh = MinutesPrompt.system(for: lang) == zh
            let correctionIsZh = CorrectionPrompt.system(for: lang) == corrZh
            if lang.isChinese != minutesIsZh || lang.isChinese != correctionIsZh {
                fails.append("\(lang.rawValue) isChinese=\(lang.isChinese) 與 system prompt 分支不一致(minutes \(minutesIsZh)、correction \(correctionIsZh))")
            }
        }
        if !TranscriptionLanguage.zhTW.isChinese || !TranscriptionLanguage.zhCN.isChinese || TranscriptionLanguage.en.isChinese || TranscriptionLanguage.ja.isChinese {
            fails.append("isChinese 基本值錯")
        }
        // MIN-01:參數九旗標、schema 就是 MinutesPrompt.schema、禁用旗標無、--tools 非空、model 有填才帶
        let args = ClaudeCLIMinutesProvider.arguments(userPrompt: user, systemPrompt: "S", model: nil)
        let joined = args.joined(separator: " ")
        for need in ["-p", "--output-format json", "--json-schema", "--setting-sources ", "--system-prompt S", "--tools StructuredOutput",
                     "--max-turns 1", "--no-session-persistence", "--strict-mcp-config"] where !joined.contains(need) {
            fails.append("缺 \(need)")
        }
        if args.first != "-p" || args.count < 2 || args[1] != user { fails.append("-p 後面不是提示詞") }
        if let i = args.firstIndex(of: "--json-schema"), args[i + 1] != MinutesPrompt.schema { fails.append("schema 不是 MinutesPrompt.schema") }
        if let i = args.firstIndex(of: "--setting-sources"), args[i + 1] != "" { fails.append("setting-sources 不是空字串") }
        if let i = args.firstIndex(of: "--tools"), args[i + 1].isEmpty { fails.append("--tools 空字串(會灌 140k)") }
        for bad in ClaudeCLIMinutesProvider.forbiddenFlags where joined.contains(bad) { fails.append("出現禁用旗標 \(bad)") }
        if joined.contains("--model") { fails.append("沒指定 model 卻帶了") }
        let withModel = ClaudeCLIMinutesProvider.arguments(userPrompt: "u", systemPrompt: "s", model: "tier-x")
        if let i = withModel.firstIndex(of: "--model"), withModel[i + 1] != "tier-x" {} else if !withModel.contains("--model") { fails.append("有指定 model 卻沒帶") }
        // schema 本身:合法 JSON、五格必填、不准多欄
        if let d = MinutesPrompt.schema.data(using: .utf8), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
            let required = Set(o["required"] as? [String] ?? [])
            let props = Set((o["properties"] as? [String: Any])?.keys.map { $0 } ?? [])
            let five: Set<String> = ["summary", "decisions", "actions", "questions", "timeline"]
            if required != five || props != five { fails.append("schema 欄位不是五格 \(required) \(props)") }
            if (o["additionalProperties"] as? Bool) != false { fails.append("schema 沒鎖 additionalProperties") }
        } else { fails.append("schema 不是合法 JSON") }
        return Result(name: "MIN-01/02/03 提示詞範圍+參數鎖定+schema", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "三段提示詞、本機帳目不送、正控組抓到檔名、9 旗標齊、schema 五格鎖" : fails.joined(separator: ";"))
    }

    /// MIN-03／05 解析:正常/缺欄/型別錯/未登入/非 JSON/is_error/非零,訊息不含原始輸出,previous 的行數帳目帶過去。
    static func minutesParseOutput() -> Result {
        var fails: [String] = []
        let when = Date(timeIntervalSince1970: 1_760_900_000)
        let prev = MinutesDocument(updatedAt: when, transcriptLinesConsumed: 7)
        let good = """
        {"type":"result","structured_output":{"summary":"S","decisions":["d1"],"actions":[],"questions":["q"],"timeline":["0:00:05 x"]},"usage":{"input_tokens":3,"cache_creation_input_tokens":4000,"cache_read_input_tokens":100,"output_tokens":800},"duration_ms":5000}
        """
        do {
            let d = try ClaudeCLIMinutesProvider.parseOutput(good, exitCode: 0, previous: prev, now: when)
            if d.summary != "S" || d.decisions != ["d1"] || !d.actions.isEmpty || d.questions != ["q"] || d.timeline != ["0:00:05 x"] { fails.append("五格解析錯") }
            if d.inputTokens != 4103 || d.outputTokens != 800 { fails.append("usage 錯 \(d.inputTokens)/\(d.outputTokens)") }
            if d.updatedAt != when || d.transcriptLinesConsumed != 7 { fails.append("時間/行數帳目沒帶") }
        } catch { fails.append("正常輸出丟錯 \(error)") }
        let missing = #"{"type":"result","structured_output":{"summary":"SECRET-RAW","decisions":[],"actions":[],"questions":[]}}"#
        do { _ = try ClaudeCLIMinutesProvider.parseOutput(missing, exitCode: 0); fails.append("缺欄位沒丟") }
        catch MinutesError.badOutput(let m) { if m.contains("SECRET-RAW") || !m.contains("timeline") { fails.append("缺欄位訊息錯:\(m)") } }
        catch { fails.append("缺欄位丟錯型別 \(error)") }
        let wrongType = #"{"structured_output":{"summary":"s","decisions":"not-a-list","actions":[],"questions":[],"timeline":[]}}"#
        do { _ = try ClaudeCLIMinutesProvider.parseOutput(wrongType, exitCode: 0); fails.append("型別錯沒丟") }
        catch MinutesError.badOutput {} catch { fails.append("型別錯丟錯型別 \(error)") }
        do { _ = try ClaudeCLIMinutesProvider.parseOutput("Not logged in · Please run /login", exitCode: 1); fails.append("未登入沒丟") }
        catch MinutesError.notLoggedIn {} catch { fails.append("未登入丟錯型別 \(error)") }
        do { _ = try ClaudeCLIMinutesProvider.parseOutput("garbage SECRET-LINE", exitCode: 0); fails.append("非 JSON 沒丟") }
        catch MinutesError.badOutput(let m) { if m.contains("SECRET-LINE") { fails.append("訊息含原始輸出") } }
        catch { fails.append("非 JSON 丟錯型別 \(error)") }
        do { _ = try ClaudeCLIMinutesProvider.parseOutput(#"{"type":"result","is_error":true,"result":"SECRET-ERR"}"#, exitCode: 1); fails.append("is_error 沒丟") }
        catch MinutesError.failed(_, let m) { if m.contains("SECRET-ERR") { fails.append("is_error 訊息含原文") } }
        catch { fails.append("is_error 丟錯型別 \(error)") }
        do { _ = try ClaudeCLIMinutesProvider.parseOutput("", exitCode: 2, stderr: "SECRET-STDERR"); fails.append("非零沒丟") }
        catch MinutesError.failed(let code, let m) { if code != 2 || m.contains("SECRET-STDERR") { fails.append("非零 code/訊息錯") } }
        catch { fails.append("非零丟錯型別 \(error)") }
        return Result(name: "MIN-03/05 會議記錄 CLI 輸出解析", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "正常/缺欄/型別錯/未登入/非 JSON/is_error/非零 7 案,訊息不含原文" : fails.joined(separator: ";"))
    }

    /// MIN-04／05／09 滾動決策純函式＋ `.minutes.json` 舊檔相容(沒 transcriptLinesConsumed ⇒ 0)。
    static func minutesRollingRules() -> Result {
        var fails: [String] = []
        if MinutesRolling.plan(transcriptCount: 10, consumed: 7) != .init(startOver: false, from: 7) { fails.append("接續錯") }
        if MinutesRolling.plan(transcriptCount: 5, consumed: 7) != .init(startOver: true, from: 0) { fails.append("重轉過應從頭") }
        if MinutesRolling.plan(transcriptCount: 7, consumed: 7) != .init(startOver: false, from: 7) { fails.append("剛好吃完應接續、增量空") }
        if MinutesRolling.plan(transcriptCount: 0, consumed: 0) != .init(startOver: false, from: 0) { fails.append("全空") }
        // MIN-04
        if MinutesRolling.shouldSkip(manual: true, deltaEmpty: true, notesChanged: false, notesEmpty: true) { fails.append("手動不可跳過") }
        if !MinutesRolling.shouldSkip(manual: false, deltaEmpty: true, notesChanged: false, notesEmpty: false) { fails.append("沒新行且筆記沒變應跳過") }
        if MinutesRolling.shouldSkip(manual: false, deltaEmpty: true, notesChanged: true, notesEmpty: false) { fails.append("筆記有改應呼叫") }
        if !MinutesRolling.shouldSkip(manual: false, deltaEmpty: true, notesChanged: true, notesEmpty: true) { fails.append("筆記空的且沒新行應跳過") }
        if MinutesRolling.shouldSkip(manual: false, deltaEmpty: false, notesChanged: false, notesEmpty: true) { fails.append("有新行應呼叫") }
        if !MinutesRolling.notesIsEffectivelyEmpty("") || !MinutesRolling.notesIsEffectivelyEmpty("# 週會\n\n  \n") { fails.append("空/只有標題應視為空") }
        if MinutesRolling.notesIsEffectivelyEmpty("# 週會\n- 重點") || MinutesRolling.notesIsEffectivelyEmpty("沒標題的一行") { fails.append("有內容不該視為空") }
        // MIN-05
        if MinutesRolling.autoPauseThreshold != 3 { fails.append("門檻應為 3") }
        if !MinutesRolling.shouldPauseAuto(consecutiveFailures: 3, manual: false) || MinutesRolling.shouldPauseAuto(consecutiveFailures: 2, manual: false)
            || MinutesRolling.shouldPauseAuto(consecutiveFailures: 3, manual: true) { fails.append("自動暫停判定錯") }
        // MIN-09 舊 JSON 相容
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let old = #"{"summary":"s","decisions":[],"actions":[],"questions":[],"timeline":[],"updatedAt":"2026-10-19T12:00:00Z","inputTokens":1,"outputTokens":2}"#
        if let d = try? dec.decode(MinutesDocument.self, from: Data(old.utf8)) {
            if d.transcriptLinesConsumed != 0 || d.inputTokens != 1 { fails.append("舊 JSON 解碼錯") }
        } else { fails.append("舊 JSON(沒 transcriptLinesConsumed)解不開") }
        let doc = MinutesDocument(summary: "x", updatedAt: Date(timeIntervalSince1970: 1_760_900_000), transcriptLinesConsumed: 42)
        if let data = try? enc.encode(doc), let back = try? dec.decode(MinutesDocument.self, from: data) {
            if back.transcriptLinesConsumed != 42 || back != doc { fails.append("新欄位來回錯") }
        } else { fails.append("新欄位編解碼失敗") }
        return Result(name: "MIN-04/05/09 滾動決策+舊 JSON 相容", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "接續/從頭/跳過 5 案/只有標題算空/暫停門檻/舊檔 0 新檔 42" : fails.joined(separator: ";"))
    }
}
