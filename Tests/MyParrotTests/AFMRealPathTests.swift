import Testing
import Foundation
@testable import MyParrotCore
#if canImport(FoundationModels)
import FoundationModels
#endif

/// #2438 Phase 3a AFM-07/05/12 真路徑(鐵則 3):真的叫 Apple Foundation Models。預設關,`MP_AFM_REAL=1` 才跑
/// (要 macOS 26+、Apple Intelligence 可用)。合成逐字稿在這裡生,不含任何真資料。
@Suite("AFM 真路徑(MP_AFM_REAL=1 才跑)")
struct AFMRealPathTests {
    /// 二審(AFM-13):OS 不到 26 也算「不啟用」,讓報告顯示 skipped,而不是 `guard #available … return` 的假綠。
    static var enabled: Bool {
        ProcessInfo.processInfo.environment["MP_AFM_REAL"] == "1"
            && ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(majorVersion: 26, minorVersion: 0, patchVersion: 0))
    }

    /// 60 行合成週會:你／對方交替,講一個虛構的產品會議。
    static func syntheticLines(_ n: Int) -> [String] {
        let topics = ["淺色遙控器改成銀色,下週三前完成", "外觀設定加三選一,跟隨系統是預設", "首次啟動要有說明框告訴使用者去哪開模型",
                      "會議記錄後端先接本機模型,資料不出機", "校正層要能抓語音辨識聽錯的詞", "發版前要重拍四張截圖",
                      "系統需求寫 macOS 15 以上", "隱私聲明要講清楚哪些功能會連網", "Eric 負責驗收,週五回報",
                      "下一版版號定 0.5", "測試矩陣要跑新舊兩個版本", "錄音中不能重裝 app"]
        return (0..<n).map { i in
            let who = i % 2 == 0 ? "對方" : "你"
            let t = i * 9
            return "\(who) \(t / 3600):\(String(format: "%02d", (t % 3600) / 60)):\(String(format: "%02d", t % 60)): \(topics[i % topics.count])(第 \(i + 1) 句)"
        }
    }

    @Test("AFM-07 滾動兩輪(30＋30 行)", .enabled(if: enabled))
    func rollingTwoRounds() async throws {
        guard #available(macOS 26, *) else { return }
        #if canImport(FoundationModels)
        let p = AppleFMMinutesProvider(timeout: 300)   // 量真實耗時;產品預設 120 秒,數字進報告
        let lines = Self.syntheticLines(60)
        var t0 = Date()
        // AFM-13 二審:語言寫死 .zhTW(原本 .system 跟 CI 主機語言走,中文回歸的斷言就不可靠)。
        let r1 = try await p.update(MinutesInput(previous: nil, transcriptDelta: Array(lines[0..<30]), notes: "# 合成週會\n- 重點:銀色遙控器", language: .zhTW))
        let ms1 = Int(Date().timeIntervalSince(t0) * 1000)
        #expect(!r1.summary.isEmpty && r1.summary.count <= 400)
        #expect(!(r1.decisions.isEmpty && r1.actions.isEmpty && r1.timeline.isEmpty))
        t0 = Date()
        var prev = r1; prev.transcriptLinesConsumed = 30
        let r2 = try await p.update(MinutesInput(previous: prev, transcriptDelta: Array(lines[30..<60]), notes: "# 合成週會\n- 重點:銀色遙控器\n- 版號 0.5", language: .zhTW))
        let ms2 = Int(Date().timeIntervalSince(t0) * 1000)
        #expect(!r2.summary.isEmpty)
        #expect(r2.transcriptLinesConsumed == 30)
        // AFM-13 回歸(二審:不能只印):中文輸入的五欄要仍是中文——摘要與每個非空欄位都要有 CJK。
        let cjk2 = ([r2.summary] + r2.decisions + r2.actions + r2.questions + r2.timeline).map(Self.cjkCount).reduce(0, +)
        print("AFM-REAL rolling zh-check: round2 cjk=\(cjk2) summary=\(r2.summary.prefix(40)) timeline[0]=\(r2.timeline.first ?? "")")
        #expect(Self.cjkCount(r2.summary) > 0, "中文會議記錄的摘要沒有中文")
        for (name, items) in [("decisions", r2.decisions), ("actions", r2.actions), ("questions", r2.questions), ("timeline", r2.timeline)] where !items.isEmpty {
            #expect(items.map(Self.cjkCount).reduce(0, +) > 0, "中文會議記錄的 \(name) 沒有中文")
        }
        print("AFM-REAL rolling: round1 \(ms1) ms in≈\(r1.inputTokens) out≈\(r1.outputTokens) | round2 \(ms2) ms in≈\(r2.inputTokens) out≈\(r2.outputTokens) | timeline \(r1.timeline.count)→\(r2.timeline.count) decisions \(r2.decisions.count) actions \(r2.actions.count)")
        #endif
    }

    @Test("AFM-05 超大段退讓後成功", .enabled(if: enabled))
    func contextRetry() async throws {
        guard #available(macOS 26, *) else { return }
        #if canImport(FoundationModels)
        let p = AppleFMMinutesProvider(timeout: 300, chunkMax: 4500)   // 故意超過 4096,逼框架丟超出上下文
        let lines = Self.syntheticLines(200)
        let t0 = Date()
        let r = try await p.update(MinutesInput(previous: nil, transcriptDelta: lines, notes: "", language: .system))
        print("AFM-REAL retry: \(Int(Date().timeIntervalSince(t0) * 1000)) ms, summary \(r.summary.count) chars, in≈\(r.inputTokens)")
        #expect(!r.summary.isEmpty)
        #endif
    }

    @Test("AFM-12 校正品質閘(10 個聽錯詞)", .enabled(if: enabled))
    func correctionQualityGate() async throws {
        guard #available(macOS 26, *) else { return }
        #if canImport(FoundationModels)
        let planted: [(wrong: String, right: String)] = [("竹子稿", "逐字稿"), ("會議基路", "會議紀錄"), ("麥克封", "麥克風"), ("藍牙耳雞", "藍牙耳機"),
                                                         ("系統因訊", "系統音訊"), ("逐字搞", "逐字稿"), ("錄因", "錄音"), ("暫亭", "暫停"), ("結蜀", "結束"), ("標技", "標記")]
        var segments: [String] = []
        for i in 0..<20 {
            if i % 2 == 0 {
                let p = planted[i / 2]
                segments.append("我們把這段\(p.wrong)整理一下,下週再看一次")
            } else {
                segments.append("好,那這個部分我會先記下來,等一下再討論")
            }
        }
        let provider = AppleFMCorrectionProvider(timeout: 300)
        let t0 = Date()
        let r = try await provider.suggest(segments: segments, range: 0..<segments.count, language: .system)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let valid = CorrectionRules.validate(r.suggestions, segments: segments, range: 0..<segments.count)
        let invalid = r.suggestions.count - valid.count
        let hits = planted.filter { pl in valid.contains { $0.original.contains(pl.wrong) } }.count
        let exact = planted.filter { pl in valid.contains { $0.original.contains(pl.wrong) && $0.suggestion.contains(pl.right) } }.count
        print("AFM-REAL correction: \(ms) ms raw \(r.suggestions.count) valid \(valid.count) invalid \(invalid) hits \(hits)/10 exact \(exact)/10 in≈\(r.inputTokens) out≈\(r.outputTokens)")
        for s in valid { print("  seg \(s.segment): \(s.original) → \(s.suggestion) (\(s.reason))") }
        #expect(invalid == 0)
        #expect(hits >= 5, "品質閘:至少抓到 5/10,得 \(hits)")
        #endif
    }

    // MARK: - AFM-13(#2667,Eric 11/05 A1 B1):英文介面五欄／校正理由不得出中文

    /// 30 行英文合成會議(內容與 `syntheticLines` 同一場,翻成英文),講者標籤照英文介面。
    static func englishLines(_ n: Int) -> [String] {
        let topics = ["Let's switch the light remote to silver and ship it by next Wednesday", "Add a three-way appearance setting, follow system is the default",
                      "First launch needs a hint box telling users where to enable the model", "Meeting minutes should use the on-device model first, data stays local",
                      "The correction layer must catch words the recognizer misheard", "We need to retake all four screenshots before release",
                      "System requirements say macOS 26 or later", "The privacy note must spell out which features go online",
                      "Eric owns acceptance testing and reports back on Friday", "Next version number is 0.5",
                      "The test matrix has to cover both old and new builds", "Never reinstall the app while a recording is running"]
        return (0..<n).map { i in
            let who = i % 2 == 0 ? "Them" : "You"
            let t = i * 9
            return "\(who) \(t / 3600):\(String(format: "%02d", (t % 3600) / 60)):\(String(format: "%02d", t % 60)): \(topics[i % topics.count]) (line \(i + 1))"
        }
    }

    /// CJK 字元數(漢字含擴展 A／B 以上、假名、CJK 標點、全形)——英文輸出應為 0。
    static func cjkCount(_ s: String) -> Int {
        s.unicodeScalars.filter { u in
            (0x3000...0x30FF).contains(u.value) || (0x3400...0x4DBF).contains(u.value) || (0x4E00...0x9FFF).contains(u.value)
                || (0xF900...0xFAFF).contains(u.value) || (0xFF00...0xFFEF).contains(u.value) || (0x20000...0x3134F).contains(u.value)
        }.count
    }

    /// 英文的正向判準(二審:「沒有 CJK」不等於英文):字母裡 ASCII 字母佔比 ≥ 0.9,且至少 10 個字母。
    static func looksEnglish(_ s: String) -> Bool {
        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let ascii = letters.filter { $0.isASCII }.count
        return letters.count >= 10 && Double(ascii) / Double(letters.count) >= 0.9
    }

    @Test("AFM-13 英文逐字稿 → 會議記錄五欄全英文", .enabled(if: enabled))
    func englishMinutes() async throws {
        guard #available(macOS 26, *) else { return }
        #if canImport(FoundationModels)
        let p = AppleFMMinutesProvider(timeout: 300)
        let lines = Self.englishLines(30)
        let t0 = Date()
        let r = try await p.update(MinutesInput(previous: nil, transcriptDelta: lines, notes: "# Weekly sync\n- Priority: silver remote", language: .en))
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let fields: [(String, [String])] = [("summary", [r.summary]), ("decisions", r.decisions), ("actions", r.actions),
                                             ("questions", r.questions), ("timeline", r.timeline)]
        var total = 0
        print("AFM-13 minutes EN: \(ms) ms in≈\(r.inputTokens) out≈\(r.outputTokens)")
        for (name, items) in fields {
            let c = items.map(Self.cjkCount).reduce(0, +)
            total += c
            print("  [\(name)] items=\(items.count) cjk=\(c)")
            for it in items { print("    - \(it)") }
        }
        #expect(!r.summary.isEmpty && !r.timeline.isEmpty && !r.decisions.isEmpty, "英文會議記錄摘要／時間軸／決議不得為空")
        #expect(total == 0, "五欄 CJK 字元共 \(total)(timeline \(r.timeline.map(Self.cjkCount).reduce(0, +)))")
        #expect(Self.looksEnglish(r.summary), "摘要不像英文:\(r.summary.prefix(60))")
        #expect(Self.looksEnglish(r.timeline.joined(separator: " ")), "時間軸不像英文")
        #endif
    }

    @Test("AFM-13 英文逐字稿 → 校正建議(含理由)全英文", .enabled(if: enabled))
    func englishCorrection() async throws {
        guard #available(macOS 26, *) else { return }
        #if canImport(FoundationModels)
        let planted: [(wrong: String, right: String)] = [("meeting minuets", "meeting minutes"), ("micro phone", "microphone"), ("blue tooth head set", "bluetooth headset"),
                                                         ("system audio tab", "system audio tap"), ("transcript ion", "transcription")]
        var segments: [String] = []
        for i in 0..<10 {
            if i % 2 == 0 {
                let p = planted[i / 2]
                segments.append("Let's clean up this part of the \(p.wrong) and look at it again next week")
            } else {
                segments.append("Okay, I'll note that down and we can discuss it in a moment")
            }
        }
        let provider = AppleFMCorrectionProvider(timeout: 300)
        let t0 = Date()
        let r = try await provider.suggest(segments: segments, range: 0..<segments.count, language: .en)
        let ms = Int(Date().timeIntervalSince(t0) * 1000)
        let valid = CorrectionRules.validate(r.suggestions, segments: segments, range: 0..<segments.count)
        let hits = planted.filter { pl in valid.contains { $0.original.contains(pl.wrong) } }.count
        let cjk = r.suggestions.map { Self.cjkCount($0.original + $0.suggestion + $0.reason) }.reduce(0, +)
        print("AFM-13 correction EN: \(ms) ms raw \(r.suggestions.count) valid \(valid.count) hits \(hits)/5 cjk \(cjk) in≈\(r.inputTokens) out≈\(r.outputTokens)")
        for s in r.suggestions { print("  seg \(s.segment): \(s.original) → \(s.suggestion) (\(s.reason))") }
        // 二審:零產出、全被 guardrail 跳過、全無效都不得算綠。
        #expect(!r.suggestions.isEmpty, "模型沒有產生任何校正建議")
        #expect(!valid.isEmpty, "校正建議全部沒過 CorrectionRules.validate")
        #expect(hits >= 3, "植入的聽錯詞只命中 \(hits)/5")
        #expect(valid.allSatisfy { !$0.reason.isEmpty }, "有建議沒有理由")
        #expect(cjk == 0, "校正建議含 \(cjk) 個 CJK 字元")
        #expect(Self.looksEnglish(valid.map(\.reason).joined(separator: " ")), "理由不像英文")
        #endif
    }
}
