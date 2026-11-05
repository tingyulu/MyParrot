import Foundation
#if canImport(FoundationModels) && !MYPARROT_NO_AFM
import FoundationModels

/// #2438 Phase 3a(AFM-12):Apple Foundation Models 逐字稿校正後端。提示詞沿 `CorrectionPrompt`(只含段號＋原文),
/// 子批 ≤ `AFMBudget.correctionBatchMax`;回來的建議照常交給 `CorrectionRules.validate`(original 必須逐字命中)。
@available(macOS 26, *)
public struct AppleFMCorrectionProvider: CorrectionProvider {
    public var timeout: TimeInterval

    public init(timeout: TimeInterval = 120) { self.timeout = timeout }

    /// AFM-13(#2667,Eric B1 併修):`@Guide` 描述跟 `CorrectionPrompt.system(for:)` 走同一個 zh／其他分支(`language.isChinese`),
    /// 否則英文介面的 `reason` 會回中文(會議記錄那邊 11/05 真跑五欄全中文,同一機制)。中文描述原樣保留;欄位與上限(20)不變。
    @Generable
    struct CorrectionDraftZH: CorrectionDraftFields {
        @Guide(description: "最可能聽錯的詞與修正;沒有就空陣列", .maximumCount(20)) var corrections: [CorrectionItemZH]
    }

    @Generable
    struct CorrectionItemZH: CorrectionItemFields {
        @Guide(description: "段號") var segment: Int
        @Guide(description: "該段原文中逐字出現的字串") var original: String
        @Guide(description: "修正後的字串") var suggestion: String
        @Guide(description: "一句理由") var reason: String
    }

    @Generable
    struct CorrectionDraftEN: CorrectionDraftFields {
        @Guide(description: "Words the speech recognizer most likely misheard, with the fix; empty array if none", .maximumCount(20)) var corrections: [CorrectionItemEN]
    }

    @Generable
    struct CorrectionItemEN: CorrectionItemFields {
        @Guide(description: "Segment number") var segment: Int
        @Guide(description: "A string that appears verbatim in that segment") var original: String
        @Guide(description: "The corrected string") var suggestion: String
        @Guide(description: "One-sentence reason") var reason: String
    }

    public func suggest(segments: [String], range: Range<Int>, language: TranscriptionLanguage) async throws -> CorrectionResult {
        let started = Date()
        let instructions = CorrectionPrompt.system(for: language)
        let zh = language.isChinese   // AFM-13:與 CorrectionPrompt.system(for:) 同一個判準
        var out: [CorrectionSuggestion] = []
        var inTokens = 0, outTokens = 0
        for sub in AFMBudget.correctionBatches(segments: segments, range: range) {
            let user = CorrectionPrompt.user(segments: segments, range: sub, language: language)
            inTokens += AFMBudget.estimateTokens(instructions) + AFMBudget.estimateTokens(user)
            let session = LanguageModelSession(instructions: instructions)
            let options = GenerationOptions(sampling: .greedy, maximumResponseTokens: AFMBudget.correctionOutputMax)
            do {
                let items = try await suggestions(zh: zh, session: session, user: user, options: options)
                for s in items {
                    out.append(s)
                    outTokens += AFMBudget.estimateTokens(s.original + s.suggestion + s.reason) + 4
                }
            } catch let e as LanguageModelSession.GenerationError {
                if AFMErrors.isGuardrail(e) { continue }          // 這一批跳過,其他照常
                if AFMErrors.isContextOverflow(e) { throw CorrectionError.failed(-1, "段落太長") }
                if AFMErrors.isUnsupportedLanguage(e) { throw CorrectionError.failed(-2, "不支援的語言") }
                throw CorrectionError.failed(-2, String(String(describing: e).prefix(120)))
            } catch let e as CorrectionError {
                throw e
            } catch {
                if AFMErrors.describesGuardrail(error) { continue }
                if AFMErrors.describesContextOverflow(error) { throw CorrectionError.failed(-1, "段落太長") }
                throw CorrectionError.failed(-2, String(String(describing: error).prefix(120)))
            }
        }
        return CorrectionResult(suggestions: out, inputTokens: inTokens, outputTokens: outTokens,
                                durationMs: Int(Date().timeIntervalSince(started) * 1000))
    }

    /// AFM-13:依語言挑草稿型別,回來立刻攤平成 `CorrectionSuggestion`,後面的 validate 不分語言。
    private func suggestions(zh: Bool, session: LanguageModelSession, user: String, options: GenerationOptions) async throws -> [CorrectionSuggestion] {
        if zh {
            let d = try await AFMCorrectionTimeout.run(seconds: timeout) {
                try await session.respond(to: user, generating: CorrectionDraftZH.self, options: options).content
            }
            return Self.flatten(d)
        } else {
            let d = try await AFMCorrectionTimeout.run(seconds: timeout) {
                try await session.respond(to: user, generating: CorrectionDraftEN.self, options: options).content
            }
            return Self.flatten(d)
        }
    }

    static func flatten(_ d: some CorrectionDraftFields) -> [CorrectionSuggestion] {
        d.corrections.map { CorrectionSuggestion(segment: $0.segment, original: $0.original, suggestion: $0.suggestion, reason: $0.reason) }
    }
}

/// AFM-13:兩套 `@Generable` 草稿共用的讀取面。
protocol CorrectionItemFields {
    var segment: Int { get }
    var original: String { get }
    var suggestion: String { get }
    var reason: String { get }
}
protocol CorrectionDraftFields {
    associatedtype Item: CorrectionItemFields
    var corrections: [Item] { get }
}

@available(macOS 26, *)
enum AFMCorrectionTimeout {
    struct TimedOut: Error {}
    static func run<T: Sendable>(seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask { try await Task.sleep(for: .seconds(seconds)); throw TimedOut() }
            do { let v = try await group.next()!; group.cancelAll(); return v }
            catch is TimedOut { group.cancelAll(); throw CorrectionError.timeout }
        }
    }
}
#endif
