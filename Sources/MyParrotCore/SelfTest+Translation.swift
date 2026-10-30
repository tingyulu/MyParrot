import Foundation

/// #2612 逐字稿翻譯(TEST_PLAN U 節 TRL-01／04／05／08／10)的純函式案例。真子行程走 `Tests/MyParrotTests/TranslationCLITests.swift`。
extension SelfTest {

    /// TRL-01:登錄表——appleTranslation 只翻譯、本機;claude／codex 多翻譯能力;翻譯選單順序;隱私框判定。
    static func translationRegistry() -> Result {
        var fails: [String] = []
        let R = ModelBackendRegistry.self
        let ids = { (list: [ModelBackendInfo]) in list.map(\.id) }
        if R.appleTranslation.capabilities != [.translation] || !R.appleTranslation.isLocal || R.appleTranslation.debugOnly { fails.append("appleTranslation 宣告不對") }
        if R.appleTranslation.id != "appleTranslation" { fails.append("id 應為 appleTranslation") }
        if !R.claudeCLI.capabilities.contains(.translation) || !R.codexCLI.capabilities.contains(.translation) { fails.append("兩個 CLI 後端應多翻譯能力") }
        if R.appleFM.capabilities.contains(.translation) { fails.append("appleFM 不做翻譯") }
        let tr = ids(R.filter(R.assemble(platformSupportsAFM: true), for: .translation, includeDebugOnly: false))
        if tr != ["off", "claudeCLI", "codexCLI", "appleTranslation"] { fails.append("翻譯選單順序應 off/claudeCLI/codexCLI/appleTranslation,得 \(tr)") }
        let all = ids(R.assemble(platformSupportsAFM: true))
        if all.firstIndex(of: "appleTranslation") != 4 { fails.append("appleTranslation 應排在 appleFM 之後,得 \(all)") }
        let suite = "MyParrotSelfTest.translation"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        if R.needsPrivacyConfirmation("appleTranslation", defaults: d) { fails.append("本機後端不該跳隱私框") }
        if BuildFlavor.allowsCLIBackends, !R.needsPrivacyConfirmation("claudeCLI", defaults: d) { fails.append("claudeCLI 未同意前應跳") }   // MAS-14:商店版表裡沒有它
        R.select("appleTranslation", for: .translation, defaults: d)
        if R.selected(for: .translation, defaults: d).id != "appleTranslation" { fails.append("select/selected 往返錯") }
        R.select("appleTranslation", for: .minutes, defaults: d)
        if R.selected(for: .minutes, defaults: d).id != "off" { fails.append("會議記錄選 appleTranslation 應 fail closed") }
        d.removePersistentDomain(forName: suite)
        // 目標語言
        if TranslationTarget.resolve(nil) != .zhHant || TranslationTarget.resolve("garbage") != .zhHant || TranslationTarget.resolve("ja") != .ja { fails.append("目標語言解析錯") }
        if TranslationTarget.zhHant.fileExtension != "zh-Hant.srt" { fails.append("副檔名應 zh-Hant.srt") }
        for t in TranslationTarget.allCases where !SidecarSet.extensions.contains(t.fileExtension) { fails.append("SidecarSet 缺 \(t.fileExtension)") }
        return Result(name: "TRL-01 翻譯登錄表與目標語言", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "三後端能力/順序/隱私/往返/fail closed/目標語言/副檔名" : fails.joined(separator: ";"))
    }

    /// TRL-04:切批、節奏、0 行不送、強制送、估算。
    static func translationPlan() -> Result {
        var fails: [String] = []
        let P = TranslationPlan.self
        let b = P.nextBatch(Array(1...130))
        if b.batch.count != 60 || b.rest.count != 70 || b.batch.first != 1 || b.rest.first != 61 { fails.append("130 行應切 60/70 且順序不變") }
        let small = P.nextBatch([1, 2, 3])
        if small.batch != [1, 2, 3] || !small.rest.isEmpty { fails.append("少於上限整批送") }
        if !P.nextBatch([Int]()).batch.isEmpty { fails.append("空佇列空批") }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        if P.shouldFlush(cadence: 60, lastSentAt: nil, now: now, pendingCount: 0, force: true) { fails.append("0 行強制也不送") }
        if !P.shouldFlush(cadence: 60, lastSentAt: nil, now: now, pendingCount: 1, force: false) { fails.append("第一批不等節奏") }
        if P.shouldFlush(cadence: 60, lastSentAt: now.addingTimeInterval(-30), now: now, pendingCount: 5, force: false) { fails.append("節奏未到不送") }
        if !P.shouldFlush(cadence: 60, lastSentAt: now.addingTimeInterval(-60), now: now, pendingCount: 5, force: false) { fails.append("到點該送") }
        if !P.shouldFlush(cadence: 60, lastSentAt: now.addingTimeInterval(-1), now: now, pendingCount: 5, force: true) { fails.append("強制送不看節奏") }
        let claude30 = P.estimatedTokensPerHour(cadenceSec: 30, basePerCall: 1500), codex30 = P.estimatedTokensPerHour(cadenceSec: 30, basePerCall: 13500)
        if claude30 < 150_000 || claude30 > 250_000 { fails.append("Claude 30 s 估算應約 20 萬,得 \(claude30)") }
        if codex30 < 1_500_000 { fails.append("Codex 30 s 估算應 >150 萬,得 \(codex30)") }
        if P.defaultCadence != 60 || !P.cadenceOptions.contains(P.defaultCadence) { fails.append("預設節奏應 60 且在選項內") }
        return Result(name: "TRL-04 批次與節奏純決策", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "切批 3 案、節奏 5 案、估算 2 案" : fails.joined(separator: ";"))
    }

    /// TRL-05:提示詞只有編號＋行文字;schema;解析(長度不符作廢、剝編號、型別錯);兩家 parseOutput。
    static func translationPromptAndParse() -> Result {
        var fails: [String] = []
        let lines = ["Let's start.", "Who owns the follow-up?"]
        let user = TranslationPrompt.user(lines: lines, to: .zhHant)
        if !user.contains("1: Let's start.") || !user.contains("2: Who owns the follow-up?") { fails.append("使用者訊息應含編號行") }
        if !user.contains("Traditional Chinese (Taiwan)") || !user.contains("exactly 2") { fails.append("應含目標語言與行數") }
        for bad in ["你", "對方", "You", "Them", "0:00", ".m4a", "/Users"] where user.contains(bad) { fails.append("提示詞不該含 \(bad)") }
        if !TranslationPrompt.system(to: .ja).contains("Japanese") { fails.append("系統提示應含目標語言") }
        if !TranslationPrompt.schema.contains("\"lines\"") { fails.append("schema 應有 lines") }
        // parseLines
        do {
            let out = try TranslationPrompt.parseLines(["lines": ["1: 我們開始。", "2. 誰負責後續?"]], expected: 2)
            if out != ["我們開始。", "誰負責後續?"] { fails.append("應剝掉編號,得 \(out)") }
        } catch { fails.append("正常解析丟錯 \(error)") }
        do { _ = try TranslationPrompt.parseLines(["lines": ["只有一行"]], expected: 2); fails.append("行數不符沒丟") }
        catch TranslationError.badOutput(let m) { if !m.contains("行數") { fails.append("行數訊息錯 \(m)") } }
        catch { fails.append("行數不符丟錯型別 \(error)") }
        do { _ = try TranslationPrompt.parseLines(["lines": ["a", 2]], expected: 2); fails.append("型別錯沒丟") }
        catch TranslationError.badOutput {} catch { fails.append("型別錯丟錯型別 \(error)") }
        do { _ = try TranslationPrompt.parseLines(["other": []], expected: 0); fails.append("缺 lines 沒丟") }
        catch TranslationError.badOutput {} catch { fails.append("缺 lines 丟錯型別 \(error)") }
        if TranslationPrompt.stripNumber("3: 第三行", index: 3) != "第三行" || TranslationPrompt.stripNumber("3: 第三行", index: 4) != "3: 第三行" { fails.append("剝編號只剝對的序號") }
        // Claude parseOutput
        let good = #"{"type":"result","structured_output":{"lines":["甲","乙"]},"usage":{"input_tokens":2,"cache_creation_input_tokens":1700,"output_tokens":50},"duration_ms":4000}"#
        do {
            let r = try ClaudeCLITranslationProvider.parseOutput(good, exitCode: 0, expected: 2)
            if r.lines != ["甲", "乙"] || r.inputTokens != 1702 || r.outputTokens != 50 || r.durationMs != 4000 { fails.append("Claude 正常輸出解析錯") }
        } catch { fails.append("Claude 正常輸出丟錯 \(error)") }
        do { _ = try ClaudeCLITranslationProvider.parseOutput("Not logged in · Please run /login", exitCode: 1, expected: 1); fails.append("Claude 未登入沒丟") }
        catch TranslationError.notLoggedIn {} catch { fails.append("Claude 未登入丟錯型別 \(error)") }
        do { _ = try ClaudeCLITranslationProvider.parseOutput(good, exitCode: 0, expected: 3); fails.append("Claude 行數不符沒丟") }
        catch TranslationError.badOutput {} catch { fails.append("Claude 行數不符丟錯型別 \(error)") }
        // Codex parseOutput
        let jsonl = #"{"type":"turn.completed","usage":{"input_tokens":13600,"cached_input_tokens":0,"output_tokens":200,"reasoning_output_tokens":10}}"#
        do {
            let r = try CodexCLITranslationProvider.parseOutput(lastMessage: #"{"lines":["1: 甲","2: 乙"]}"#, stdout: jsonl, exitCode: 0, expected: 2, durationMs: 9000)
            if r.lines != ["甲", "乙"] || r.inputTokens != 13600 || r.outputTokens != 210 || r.durationMs != 9000 { fails.append("Codex 正常輸出解析錯 \(r.lines)") }
        } catch { fails.append("Codex 正常輸出丟錯 \(error)") }
        do { _ = try CodexCLITranslationProvider.parseOutput(lastMessage: nil, stdout: "", exitCode: 1, stderr: "Not logged in", expected: 1); fails.append("Codex 未登入沒丟") }
        catch TranslationError.codexNotLoggedIn {} catch { fails.append("Codex 未登入丟錯型別 \(error)") }
        do { _ = try CodexCLITranslationProvider.parseOutput(lastMessage: "SECRET-GARBAGE", stdout: "", exitCode: 0, expected: 1); fails.append("Codex 非 JSON 沒丟") }
        catch TranslationError.badOutput(let m) { if m.contains("SECRET-GARBAGE") { fails.append("訊息含原文") } }
        catch { fails.append("Codex 非 JSON 丟錯型別 \(error)") }
        return Result(name: "TRL-05 翻譯提示詞與解析", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "提示詞範圍/schema/parseLines 5 案/Claude 3 案/Codex 3 案" : fails.joined(separator: ";"))
    }

    /// TRL-08:譯文檔行對齊——換文字不換時間碼與講者、沒譯寫 [未譯]、讀回依 index＋start 對齊。
    static func translationSRT() -> Result {
        var fails: [String] = []
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let orig = (0..<3).map { TranscriptLine(isYou: $0 % 2 == 1, time: base.addingTimeInterval(Double($0) * 5), text: "line\($0)", isFinal: true, start: Double($0) * 5, duration: 3) }
        let tr = TranslationSRT.lines(original: orig, translations: [orig[0].id: "譯0", orig[2].id: "譯2"])
        if tr.count != 3 || tr[0].text != "譯0" || tr[1].text != "[未譯] line1" || tr[2].text != "譯2" { fails.append("譯文行文字錯 \(tr.map(\.text))") }
        if tr[1].isYou != true || tr[1].start != 5 || tr[1].duration != 3 { fails.append("時間碼/講者應原樣") }
        let srt = SRT.make(from: tr)
        if !srt.contains("00:00:05,000 --> 00:00:08,000\n你: [未譯] line1") { fails.append("SRT 應含未譯標記行\n\(srt)") }
        let back = SRT.parse(srt)
        let aligned = TranslationSRT.align(original: orig, translated: back)
        if aligned.count != 2 || aligned[orig[0].id] != "譯0" || aligned[orig[2].id] != "譯2" || aligned[orig[1].id] != nil { fails.append("對齊錯 \(aligned.count)") }
        // 原稿變了(重轉後 start 不同)⇒ 對不上的行不認
        var shifted = orig; shifted[2].start = 99
        if TranslationSRT.align(original: shifted, translated: back)[shifted[2].id] != nil { fails.append("start 不同不該對上") }
        if TranslationSRT.align(original: orig, translated: []).count != 0 { fails.append("空譯文檔對齊應空") }
        return Result(name: "TRL-08 譯文檔對齊", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "換文字/未譯標記/SRT 往返/start 不同不認/空檔" : fails.joined(separator: ";"))
    }

    /// #2623 TOK-01:帳本 append／load／totals／壞檔／格式。
    static func tokenLedger() -> Result {
        var fails: [String] = []
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp_tokens_\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let stem = dir.appendingPathComponent("2026-10-27 1100 週會")
        if !TokenLedger.load(stem: stem).isEmpty { fails.append("缺檔應為空帳") }
        let when = Date(timeIntervalSince1970: 1_761_500_000)
        let ok1 = TokenLedger.append(stem: stem, TokenEntry(at: when, feature: .correction, backend: "claudeCLI", inputTokens: 1700, outputTokens: 300, durationMs: 5000, units: 20))
        let ok2 = TokenLedger.append(stem: stem, TokenEntry(at: when, feature: .minutes, backend: "codexCLI", inputTokens: 14000, outputTokens: 700, durationMs: 15000, units: 30))
        let ok3 = TokenLedger.append(stem: stem, TokenEntry(at: when, feature: .minutes, backend: "appleFM", inputTokens: 900, outputTokens: 200, durationMs: 16000, units: 30, estimated: true))
        if !(ok1 && ok2 && ok3) { fails.append("append 應成功") }
        let entries = TokenLedger.load(stem: stem)
        if entries.count != 3 || entries[0].feature != "correction" || entries[2].estimated != true { fails.append("load 應 3 筆且順序/欄位對,得 \(entries.count)") }
        if !FileManager.default.fileExists(atPath: TokenLedger.url(stem: stem).path) || TokenLedger.url(stem: stem).lastPathComponent != "2026-10-27 1100 週會.tokens.json" { fails.append("檔名應 <stem>.tokens.json") }
        let t = TokenLedger.totals(entries)
        if t.all.inputTokens != 16600 || t.all.outputTokens != 1200 || t.all.calls != 3 || t.all.units != 80 || !t.all.estimated { fails.append("全場合計錯 \(t.all)") }
        if t.byFeature["minutes"]?.calls != 2 || t.byFeature["minutes"]?.inputTokens != 14900 || t.byFeature["correction"]?.estimated != false { fails.append("能力加總錯") }
        if t.byFeatureBackend["minutes"]?["codexCLI"]?.inputTokens != 14000 || t.byFeatureBackend["minutes"]?["appleFM"]?.estimated != true { fails.append("能力×後端加總錯") }
        try? "not json {".write(to: TokenLedger.url(stem: stem), atomically: true, encoding: .utf8)
        if !TokenLedger.load(stem: stem).isEmpty { fails.append("壞檔應為空帳") }
        if TokenLedger.append(stem: stem, TokenEntry(at: when, feature: .translation, backend: "appleTranslation", inputTokens: 0, outputTokens: 0, durationMs: 500, units: 10)) == false || TokenLedger.load(stem: stem).count != 1 { fails.append("壞檔上 append 應重建成 1 筆") }
        if TokenLedger.format(999) != "999" || TokenLedger.format(1741) != "1.7k" || TokenLedger.format(1_300_000) != "1.3M" || TokenLedger.format(1_250_000) != "1.2M"   /* %.1f 對 1.25 取偶數位 → 1.2 */ { fails.append("format 錯") }
        if !SidecarSet.extensions.contains("tokens.json") { fails.append("SidecarSet 缺 tokens.json") }
        return Result(name: "TOK-01 每場模型用量帳本", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "append 3/load/totals(全場、能力、能力×後端)/壞檔/format/副檔" : fails.joined(separator: ";"))
    }
}
