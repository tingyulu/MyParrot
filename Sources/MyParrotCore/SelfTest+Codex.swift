import Foundation

/// #2418 Codex CLI 後端(TEST_PLAN T 節 CDX-01／04／07)的純函式案例。真子行程走 `Tests/MyParrotTests/CodexCLITests.swift`(假 codex 腳本)。
extension SelfTest {

    /// CDX-01:登錄表宣告、順序、隱私鍵名、select/selected 往返(獨立 suite,不碰真偏好)。
    static func codexRegistry() -> Result {
        var fails: [String] = []
        let R = ModelBackendRegistry.self
        let ids = { (list: [ModelBackendInfo]) in list.map(\.id) }
        if R.codexCLI.capabilities != [.correction, .minutes, .translation] { fails.append("codexCLI 能力應＝校正＋會議記錄＋翻譯(#2612),得 \(R.codexCLI.capabilities)") }
        if R.codexCLI.isLocal || R.codexCLI.debugOnly { fails.append("codexCLI 應 isLocal=false、debugOnly=false") }
        if R.codexCLI.id != CorrectionBackend.codexCLI.rawValue || R.codexCLI.id != "codexCLI" { fails.append("codexCLI id 應＝CorrectionBackend.codexCLI.rawValue＝codexCLI") }
        let order = ids(R.assemble(platformSupportsAFM: true))
        if order.firstIndex(of: "claudeCLI") != 1 || order.firstIndex(of: "codexCLI") != 2 { fails.append("順序應 off/claudeCLI/codexCLI/appleFM,得 \(order)") }
        // MAS-14:`backends(for:)` 讀本建置的 all,商店版沒有 codexCLI;純函式面(assemble)上面已驗。
        if BuildFlavor.allowsCLIBackends {
            for cap in [ModelCapability.correction, .minutes] where !ids(R.backends(for: cap)).contains("codexCLI") { fails.append("\(cap) 應可選 codexCLI") }
            if !ids(R.backends(for: .translation)).contains("codexCLI") { fails.append("翻譯應列 codexCLI(#2612)") }
        } else if ModelCapability.allCases.contains(where: { ids(R.backends(for: $0)).contains("codexCLI") }) {
            fails.append("MAS-14:商店版任何能力都不應列 codexCLI")
        }
        let suite = "MyParrotSelfTest.codex"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        if BuildFlavor.allowsCLIBackends {   // needsPrivacyConfirmation／select 都查本建置的 all;商店版沒有這個後端(MAS-14)
            if !R.needsPrivacyConfirmation("codexCLI", defaults: d) { fails.append("出機後端第一次應跳隱私框") }
            R.acceptPrivacy("codexCLI", defaults: d)
            if R.needsPrivacyConfirmation("codexCLI", defaults: d) { fails.append("同意後不應再問") }
            if !d.bool(forKey: "privacyAccepted.codexCLI") { fails.append("隱私鍵名應為 privacyAccepted.codexCLI") }
            if d.bool(forKey: "privacyAccepted.claudeCLI") { fails.append("同意 codex 不該連帶同意 claude") }
            R.select("codexCLI", for: .minutes, defaults: d)
            if R.selected(for: .minutes, defaults: d).id != "codexCLI" { fails.append("select/selected 往返錯") }
        } else {
            R.select("codexCLI", for: .minutes, defaults: d)
            if R.selected(for: .minutes, defaults: d).id != "off" { fails.append("MAS-14:商店版 select codexCLI 應 fail closed 成 off") }
        }
        R.select("appleTranslation", for: .minutes, defaults: d)
        if R.selected(for: .minutes, defaults: d).id != "off" { fails.append("會議記錄選只做翻譯的後端應 fail closed 成 off") }
        d.removePersistentDomain(forName: suite)
        return Result(name: "CDX-01 Codex 登錄表", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "能力/順序/隱私鍵/往返/翻譯 fail closed 全對" : fails.joined(separator: ";"))
    }

    /// CDX-04:參數逐項鎖死、禁用字不出現、提示詞合成＝Claude 同一份字串、登入／未登入判定。
    static func codexArguments() -> Result {
        var fails: [String] = []
        let K = CodexCLIRunner.self
        let args = K.arguments(prompt: "PROMPT", schemaPath: "/tmp/x/schema.json", outputPath: "/tmp/x/last.json", model: nil)
        let expected = ["exec", "--skip-git-repo-check", "--ephemeral", "--ignore-user-config", "--ignore-rules",
                        "--sandbox", "read-only", "--color", "never", "--json",
                        "--output-schema", "/tmp/x/schema.json", "-o", "/tmp/x/last.json", "PROMPT"]
        if args != expected { fails.append("參數應逐項＝\(expected),得 \(args)") }
        let withModel = K.arguments(prompt: "PROMPT", schemaPath: "s", outputPath: "o", model: "tier-x")
        if let i = withModel.firstIndex(of: "-m") { if withModel[i + 1] != "tier-x" { fails.append("-m 值錯") } } else { fails.append("有填 model 應帶 -m") }
        if withModel.last != "PROMPT" { fails.append("提示詞應在最後") }
        if K.arguments(prompt: "P", schemaPath: "s", outputPath: "o", model: "").contains("-m") { fails.append("空 model 不應帶 -m") }
        for bad in K.forbiddenFlags where args.contains(bad) || withModel.contains(bad) { fails.append("配方含禁用字 \(bad)") }
        for must in ["--dangerously-bypass-approvals-and-sandbox", "--full-auto", "--add-dir", "danger-full-access", "workspace-write", "resume"]
        where !K.forbiddenFlags.contains(must) { fails.append("forbiddenFlags 應含 \(must)") }
        // 提示詞＝系統提示＋空行＋使用者訊息;使用者訊息就是 CorrectionPrompt.user(與 Claude 後端同一份)
        let user = CorrectionPrompt.user(segments: ["甲", "乙"], range: 0..<2, language: .zhTW)
        let sys = CorrectionPrompt.system(for: .zhTW)
        let composed = K.composePrompt(systemPrompt: sys, userPrompt: user)
        if composed != sys + "\n\n" + user { fails.append("composePrompt 形狀錯") }
        if !composed.hasSuffix(user) || !composed.hasPrefix(sys) { fails.append("composePrompt 應以系統提示開頭、使用者訊息結尾") }
        // 登入判定(2026-10-23 實測:已登入印 Logged in using ChatGPT、exit 0)
        if !K.looksLoggedIn(exitCode: 0, stdout: "Logged in using ChatGPT\n", stderr: "") { fails.append("已登入字樣應判 true") }
        if K.looksLoggedIn(exitCode: 1, stdout: "Not logged in", stderr: "") { fails.append("exit 1 應判 false") }
        if K.looksLoggedIn(exitCode: 0, stdout: "", stderr: "") { fails.append("空輸出應判 false") }
        if !K.looksLoggedIn(exitCode: 0, stdout: "", stderr: "Logged in using API key") { fails.append("stderr 的 Logged in 也算") }
        if !K.looksNotLoggedIn(exitCode: 1, stdout: "", stderr: "Not logged in. Run `codex login`.") { fails.append("非 0＋Not logged in 應判未登入") }
        if !K.looksNotLoggedIn(exitCode: 2, stdout: "Please run codex login first", stderr: "") { fails.append("非 0＋codex login 應判未登入") }
        if K.looksNotLoggedIn(exitCode: 0, stdout: #"{"corrections":[{"segment":1,"original":"codex login","suggestion":"x","reason":"r"}]}"#, stderr: "") { fails.append("exit 0 的模型回覆提到 login 不算未登入") }
        if K.looksNotLoggedIn(exitCode: 3, stdout: "", stderr: "network down") { fails.append("非 0 但沒字樣不算未登入") }
        return Result(name: "CDX-04 Codex 參數鎖定", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "\(expected.count) 項逐項、-m 條件、禁用字 \(K.forbiddenFlags.count)、提示詞合成、登入判定 8 案" : fails.joined(separator: ";"))
    }

    /// CDX-07:輸出解析——`-o` 優先、JSONL 退回、usage 取法、失敗四型(未登入／非 0／非 JSON／缺欄),訊息不含原文;會議記錄五格與正控組。
    static func codexParseOutput() -> Result {
        var fails: [String] = []
        let jsonl = """
        {"type":"thread.started","thread_id":"t"}
        {"type":"turn.started"}
        {"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"{\\"corrections\\":[{\\"segment\\":1,\\"original\\":\\"台積店\\",\\"suggestion\\":\\"台積電\\",\\"reason\\":\\"同音\\"}]}"}}
        {"type":"turn.completed","usage":{"input_tokens":13547,"cached_input_tokens":100,"cache_write_input_tokens":0,"output_tokens":59,"reasoning_output_tokens":10}}
        """
        let last = #"{"corrections":[{"segment":1,"original":"台積店","suggestion":"台積電","reason":"同音"}]}"#
        // 1) -o 優先 + usage(input＋cached、output＋reasoning)+ 耗時帶過
        do {
            let r = try CodexCLIProvider.parseOutput(lastMessage: last, stdout: jsonl, exitCode: 0, durationMs: 1234)
            if r.suggestions.count != 1 || r.suggestions[0].suggestion != "台積電" || r.suggestions[0].segment != 1 { fails.append("-o 正常輸出解析錯") }
            if r.inputTokens != 13647 || r.outputTokens != 69 || r.durationMs != 1234 { fails.append("usage 錯 \(r.inputTokens)/\(r.outputTokens)/\(r.durationMs)") }
        } catch { fails.append("-o 正常輸出丟錯 \(error)") }
        // 2) -o 缺 ⇒ 退回 JSONL 最後一則 agent_message
        do {
            let r = try CodexCLIProvider.parseOutput(lastMessage: nil, stdout: jsonl, exitCode: 0)
            if r.suggestions.count != 1 { fails.append("JSONL 退回解析錯") }
        } catch { fails.append("JSONL 退回丟錯 \(error)") }
        // 3) -o 壞、JSONL 沒有 agent_message ⇒ badOutput,不含原文
        do { _ = try CodexCLIProvider.parseOutput(lastMessage: "SECRET-GARBAGE", stdout: #"{"type":"turn.started"}"#, exitCode: 0); fails.append("非 JSON 沒丟") }
        catch CorrectionError.badOutput(let m) { if m.contains("SECRET-GARBAGE") { fails.append("訊息含原始輸出") } }
        catch { fails.append("非 JSON 丟錯型別 \(error)") }
        // 4) 非 0 ⇒ failed(code),不含 stderr
        do { _ = try CodexCLIProvider.parseOutput(lastMessage: nil, stdout: "", exitCode: 3, stderr: "SECRET-STDERR"); fails.append("非零沒丟") }
        catch CorrectionError.failed(let code, let m) { if code != 3 || m.contains("SECRET-STDERR") { fails.append("非零 code/訊息錯 \(code) \(m)") } }
        catch { fails.append("非零丟錯型別 \(error)") }
        // 5) 未登入
        do { _ = try CodexCLIProvider.parseOutput(lastMessage: nil, stdout: "", exitCode: 1, stderr: "Not logged in. Run codex login"); fails.append("未登入沒丟") }
        catch CorrectionError.codexNotLoggedIn {} catch { fails.append("未登入丟錯型別 \(error)") }
        // 6) 正控:JSON 合法但缺 corrections
        do { _ = try CodexCLIProvider.parseOutput(lastMessage: #"{"fixes":[]}"#, stdout: "", exitCode: 0); fails.append("缺 corrections 沒丟") }
        catch CorrectionError.badOutput(let m) { if !m.contains("corrections") { fails.append("缺欄訊息應點名 corrections,得 \(m)") } }
        catch { fails.append("缺 corrections 丟錯型別 \(error)") }
        // 7) 會議記錄五格 + previous 帳目 + usage
        let when = Date(timeIntervalSince1970: 1_760_900_000)
        let prev = MinutesDocument(updatedAt: when, transcriptLinesConsumed: 7)
        let five = #"{"summary":"S","decisions":["d1"],"actions":[],"questions":["q"],"timeline":["0:00:05 x"]}"#
        let minutesJSONL = #"{"type":"turn.completed","usage":{"input_tokens":14000,"cached_input_tokens":0,"output_tokens":700,"reasoning_output_tokens":100}}"#
        do {
            let d = try CodexCLIMinutesProvider.parseOutput(lastMessage: five, stdout: minutesJSONL, exitCode: 0, previous: prev, now: when)
            if d.summary != "S" || d.decisions != ["d1"] || !d.actions.isEmpty || d.questions != ["q"] || d.timeline != ["0:00:05 x"] { fails.append("五格解析錯") }
            if d.inputTokens != 14000 || d.outputTokens != 800 { fails.append("會議記錄 usage 錯 \(d.inputTokens)/\(d.outputTokens)") }
            if d.updatedAt != when || d.transcriptLinesConsumed != 7 { fails.append("時間/行數帳目沒帶") }
        } catch { fails.append("五格正常輸出丟錯 \(error)") }
        // 8) 正控:缺 timeline
        do { _ = try CodexCLIMinutesProvider.parseOutput(lastMessage: #"{"summary":"SECRET-RAW","decisions":[],"actions":[],"questions":[]}"#, stdout: "", exitCode: 0); fails.append("缺欄位沒丟") }
        catch MinutesError.badOutput(let m) { if m.contains("SECRET-RAW") || !m.contains("timeline") { fails.append("缺欄位訊息錯:\(m)") } }
        catch { fails.append("缺欄位丟錯型別 \(error)") }
        // 9) 型別錯
        do { _ = try CodexCLIMinutesProvider.parseOutput(lastMessage: #"{"summary":"s","decisions":"not-a-list","actions":[],"questions":[],"timeline":[]}"#, stdout: "", exitCode: 0); fails.append("型別錯沒丟") }
        catch MinutesError.badOutput {} catch { fails.append("型別錯丟錯型別 \(error)") }
        // 10) 會議記錄未登入型別
        do { _ = try CodexCLIMinutesProvider.parseOutput(lastMessage: nil, stdout: "", exitCode: 1, stderr: "Not logged in"); fails.append("會議記錄未登入沒丟") }
        catch MinutesError.codexNotLoggedIn {} catch { fails.append("會議記錄未登入丟錯型別 \(error)") }
        // 11) 工具活動計數:純訊息 0;混一則 command_execution ⇒ 1
        if CodexCLIRunner.toolActivityCount(in: jsonl) != 0 { fails.append("純訊息回合工具計數應 0") }
        let withTool = jsonl + "\n" + #"{"type":"item.completed","item":{"id":"c","type":"command_execution","command":"ls"}}"#
        if CodexCLIRunner.toolActivityCount(in: withTool) != 1 { fails.append("有指令 item 應計 1") }
        return Result(name: "CDX-07 Codex 輸出解析", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "-o 優先/JSONL 退回/非 JSON/非零/未登入/缺欄/五格/缺 timeline/型別/會議未登入/工具計數 11 案,訊息不含原文" : fails.joined(separator: ";"))
    }
}
