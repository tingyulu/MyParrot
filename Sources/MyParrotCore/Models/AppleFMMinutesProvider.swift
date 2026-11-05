import Foundation
#if canImport(FoundationModels) && !MYPARROT_NO_AFM
import FoundationModels

/// #2438 Phase 3a(AFM-03/04/05):Apple Foundation Models 會議記錄後端。資料全部留在本機。
/// 每次更新新開 `LanguageModelSession`(不累積歷史);使用者訊息沿 `MinutesPrompt.user` 三段格式,
/// 與 Claude CLI 後端一字不差;增量照 `AFMBudget.chunk` 切段、段與段 previous 接力;
/// `exceededContextWindowSize` ⇒ 對半重試最多 3 次;`guardrailViolation` ⇒ 跳過該段不讓整輪失敗。
/// token 數是估算(框架不回 usage)。
@available(macOS 26, *)
public struct AppleFMMinutesProvider: MinutesProvider {
    public var timeout: TimeInterval
    public var chunkMax: Int

    public init(timeout: TimeInterval = 120, chunkMax: Int = AFMBudget.deltaChunkMax) {
        self.timeout = timeout
        self.chunkMax = chunkMax
    }

    /// AFM-13(#2667):五欄草稿的 `@Guide` 描述跟 `MinutesPrompt.system(for:)` 走同一個 zh／其他分支(`language.isChinese`)。
    /// 11/05 真跑:英文逐字稿＋英文 system prompt,中文描述仍把五欄全部帶成中文(342 個 CJK 字元)⇒ 描述語言決定輸出語言。
    /// 中文描述原樣保留(10/20 驗過的品質不動);其他八語用英文描述,輸出語言交給 system 第 5 條「寫逐字稿的語言」。
    /// 兩套的欄位、上限(12／20)與 `MinutesPrompt.schema` 五格一字不差;送出資料範圍不變。
    @Generable
    struct MinutesDraftZH: MinutesDraftFields {
        @Guide(description: "會議摘要,最多 300 字") var summary: String
        @Guide(description: "決議事項,每條一句", .maximumCount(12)) var decisions: [String]
        @Guide(description: "待辦事項,每條一句(含負責人若有)", .maximumCount(12)) var actions: [String]
        @Guide(description: "待釐清問題,每條一句", .maximumCount(12)) var questions: [String]
        @Guide(description: "時間軸,每條「h:mm:ss 事件」", .maximumCount(20)) var timeline: [String]
    }

    @Generable
    struct MinutesDraftEN: MinutesDraftFields {
        @Guide(description: "Meeting summary, at most 300 characters") var summary: String
        @Guide(description: "Decisions made, one sentence each", .maximumCount(12)) var decisions: [String]
        @Guide(description: "Action items, one sentence each (include the owner if stated)", .maximumCount(12)) var actions: [String]
        @Guide(description: "Open questions, one sentence each", .maximumCount(12)) var questions: [String]
        @Guide(description: "Timeline, each entry \"h:mm:ss event\"", .maximumCount(20)) var timeline: [String]
    }

    public func update(_ input: MinutesInput) async throws -> MinutesDocument {
        let instructions = MinutesPrompt.system(for: input.language)
        var previous = input.previous.map { AFMBudget.compressPrevious($0) }
        let notes = AFMBudget.notesTail(input.notes)
        let chunks = AFMBudget.chunk(lines: input.transcriptDelta, max: chunkMax)
        var inTokens = 0, outTokens = 0, skipped = 0
        var produced: MinutesDocument? = nil
        let zh = input.language.isChinese   // AFM-13:與 MinutesPrompt.system(for:) 同一個判準
        let work: [[String]] = chunks.isEmpty ? [[]] : chunks
        for chunk in work {
            var attempt = 1
            var pieces: [[String]] = [chunk]
            var done = false
            while !done {
                var okAll = true
                for piece in pieces {
                    let user = MinutesPrompt.user(MinutesInput(previous: previous, transcriptDelta: piece, notes: notes, language: input.language))
                    inTokens += AFMBudget.estimateTokens(instructions) + AFMBudget.estimateTokens(user)
                    do {
                        let doc = try await respondDocument(zh: zh, instructions: instructions, user: user, previous: input.previous)
                        outTokens += AFMBudget.estimateTokens(MinutesPrompt.previousJSON(doc) ?? "")
                        produced = doc
                        previous = doc
                    } catch let e as LanguageModelSession.GenerationError {
                        if AFMErrors.isContextOverflow(e) {
                            // AFM-05:對半再試,最多 3 次(10/20 真跑:框架的 case 名比對不到,改看描述當後備)。
                            attempt += 1
                            guard let n = AFMBudget.halvePlan(attempt: attempt) else { throw MinutesError.failed(-1, "段落太長") }
                            pieces = AFMBudget.split(chunk, into: n)
                            okAll = false
                        } else if AFMErrors.isGuardrail(e) {
                            skipped += 1
                        } else if AFMErrors.isUnsupportedLanguage(e) {
                            throw MinutesError.failed(-2, "不支援的語言")
                        } else {
                            throw MinutesError.failed(-2, Self.oneLine(e))
                        }
                    } catch let e as MinutesError {
                        throw e
                    } catch {
                        // 10/20 真跑:超出上下文的錯誤不是 GenerationError 型別(描述「Content contains N tokens, which exceeds
                        // the maximum allowed context size of 4096.」),只能看描述。
                        if AFMErrors.describesContextOverflow(error) {
                            attempt += 1
                            guard let n = AFMBudget.halvePlan(attempt: attempt) else { throw MinutesError.failed(-1, "段落太長") }
                            pieces = AFMBudget.split(chunk, into: n)
                            okAll = false
                        } else if AFMErrors.describesGuardrail(error) {
                            skipped += 1
                        } else {
                            throw MinutesError.failed(-2, Self.oneLine(error))
                        }
                    }
                    if !okAll { break }
                }
                done = okAll
            }
        }
        guard var doc = produced else {
            if skipped > 0 { throw MinutesError.badOutput("安全守則拒絕了全部段落") }
            throw MinutesError.badOutput("沒有產出")
        }
        doc.inputTokens = inTokens
        doc.outputTokens = outTokens
        return doc
    }

    /// AFM-13:依語言挑草稿型別(zh ⇒ 中文描述,其他 ⇒ 英文描述),回來先轉成 `MinutesDocument`,後面流程不分語言。
    private func respondDocument(zh: Bool, instructions: String, user: String, previous: MinutesDocument?) async throws -> MinutesDocument {
        if zh {
            let d: MinutesDraftZH = try await respond(instructions: instructions, user: user)
            return Self.document(from: d, previous: previous, now: Date())
        } else {
            let d: MinutesDraftEN = try await respond(instructions: instructions, user: user)
            return Self.document(from: d, previous: previous, now: Date())
        }
    }

    private func respond<D: Generable & Sendable>(instructions: String, user: String) async throws -> D {
        let session = LanguageModelSession(instructions: instructions)
        // 10/20 真跑:預設取樣品質起伏大(校正閘 8/10 → 0/10),改 greedy 求可重現。
        let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: AFMBudget.outputMax)
        return try await AFMTimeout.run(seconds: timeout) {
            try await session.respond(to: user, generating: D.self, options: options).content
        }
    }

    static func document(from d: some MinutesDraftFields, previous: MinutesDocument?, now: Date) -> MinutesDocument {
        MinutesDocument(summary: d.summary, decisions: d.decisions, actions: d.actions, questions: d.questions,
                        timeline: d.timeline, updatedAt: now, inputTokens: 0, outputTokens: 0,
                        transcriptLinesConsumed: previous?.transcriptLinesConsumed ?? 0)
    }

    static func oneLine(_ e: Error) -> String {
        String(String(describing: e).split(separator: "\n").first ?? "").prefix(120).description
    }
}

/// AFM-13:兩套 `@Generable` 草稿共用的五欄讀取面,讓 `document(from:)` 不分語言。
protocol MinutesDraftFields {
    var summary: String { get }
    var decisions: [String] { get }
    var actions: [String] { get }
    var questions: [String] { get }
    var timeline: [String] { get }
}

/// 框架錯誤分類:先比 case,比不到就看描述(10/20 真跑發現 `exceededContextWindowSize` 的 case 比對不中,
/// 描述是「Content contains N tokens, which exceeds the maximum allowed context size of 4096.」)。
@available(macOS 26, *)
enum AFMErrors {
    static func isContextOverflow(_ e: LanguageModelSession.GenerationError) -> Bool {
        if case .exceededContextWindowSize = e { return true }
        let d = String(describing: e).lowercased()
        return d.contains("context") && (d.contains("exceed") || d.contains("window") || d.contains("size"))
    }
    static func isGuardrail(_ e: LanguageModelSession.GenerationError) -> Bool {
        if case .guardrailViolation = e { return true }
        return String(describing: e).lowercased().contains("guardrail")
    }
    static func isUnsupportedLanguage(_ e: LanguageModelSession.GenerationError) -> Bool {
        if case .unsupportedLanguageOrLocale = e { return true }
        return String(describing: e).lowercased().contains("unsupportedlanguage")
    }
    /// 任意 Error 的描述判定(非 GenerationError 型別時用)。
    static func describesContextOverflow(_ e: Error) -> Bool {
        let d = (String(describing: e) + " " + e.localizedDescription).lowercased()
        return d.contains("context") && (d.contains("exceed") || d.contains("window") || d.contains("size"))
    }
    static func describesGuardrail(_ e: Error) -> Bool {
        (String(describing: e) + " " + e.localizedDescription).lowercased().contains("guardrail")
    }
}

/// 逾時:跟模型回應賽跑,逾時就取消並丟 `MinutesError.timeout`。
@available(macOS 26, *)
enum AFMTimeout {
    struct TimedOut: Error {}
    static func run<T: Sendable>(seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw TimedOut()
            }
            do {
                let v = try await group.next()!
                group.cancelAll()
                return v
            } catch is TimedOut {
                group.cancelAll()
                throw MinutesError.timeout
            }
        }
    }
}
#endif
