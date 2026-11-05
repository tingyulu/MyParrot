import Foundation

/// 校正層的後端介面(CORR-02)。Core 只認這個 protocol:雲端/本機 CLI/將來的本地
/// 小模型都是它的實作,呼叫端(`RecordingController`)不知道後面是誰。
/// 🚫 Core 不 import 任何供應商 SDK、不含任何 API 端點——換後端只動設定不動呼叫端。
public protocol CorrectionProvider: Sendable {
    /// 對 `segments[range]` 提建議。回傳的建議**未驗證**,呼叫端一律先過
    /// `CorrectionRules.validate` 再給人看。
    func suggest(segments: [String], range: Range<Int>, language: TranscriptionLanguage) async throws -> CorrectionResult
}

/// 一次呼叫的結果:建議＋額度帳(CORR-14,內容不入 log,只記 tokens 與耗時)。
public struct CorrectionResult: Sendable {
    public var suggestions: [CorrectionSuggestion]
    public var inputTokens: Int
    public var outputTokens: Int
    public var durationMs: Int
    public init(suggestions: [CorrectionSuggestion], inputTokens: Int = 0, outputTokens: Int = 0, durationMs: Int = 0) {
        self.suggestions = suggestions; self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.durationMs = durationMs
    }
}

/// 設定頁的後端選單(CORR-01):rawValue 存 `UserDefaults["model.correction"]`(#2438 MDL-02 起走
/// `ModelBackendRegistry`;舊鍵 `correctionBackend` 只在啟動遷移時讀、保留不刪),鍵不存在＝`.off`。
/// `.localFake` 是測試用的假供應商(回固定建議),**只存在於 DEBUG 建置**(#2438 MDL-04:release 產物
/// `strings` 查不到它;release 讀到偏好裡殘留的 localFake ⇒ 解析成 off)。
public enum CorrectionBackend: String, CaseIterable, Sendable {
    case off, claudeCLI
    /// #2418 CDX:本機 `codex` CLI(ChatGPT 訂閱)。
    case codexCLI
    /// #2438 Phase 3a:Apple Foundation Models(macOS 26+,資料不出機)。
    case appleFM
    #if DEBUG
    case localFake
    #endif

    /// 舊偏好鍵(#2438 起只供 `ModelBackendRegistry.migrateLegacyKeys` 讀)。
    public static let defaultsKey = "correctionBackend"

    public var label: String {
        switch self {
        // l10n-keys:begin
        case .off:       return "關閉"
        case .claudeCLI: return "Claude CLI(本機)"
        case .codexCLI:  return "Codex CLI(本機)"
        case .appleFM:   return "Apple 本機模型"
        #if DEBUG
        case .localFake: return "本地假供應商(測試用)"
        #endif
        // l10n-keys:end
        }
    }
}

/// 校正失敗的原因(CORR-05/09)。訊息只給一句摘要,**不含** CLI 原始輸出全文。
public enum CorrectionError: Error, Sendable, Equatable {
    case cliNotFound
    case notLoggedIn
    /// #2418 CDX-03:`codex` 找不到／未登入(訊息要指向 Codex,不能借 Claude 的字)。
    case codexNotFound
    case codexNotLoggedIn
    case timeout
    case badOutput(String)      // 一句摘要
    case failed(Int32, String)  // exit code + 一句摘要
    /// #2438 Phase 3a:Apple 本機模型這台用不了(原因＝`AFMAvailability.messageKey` 的 l10n key,App 層再 L())。
    case unavailable(String)

    public var zhTW: String {
        switch self {
        case .cliNotFound: return "找不到 claude 指令,請先安裝 Claude Code"
        case .notLoggedIn: return "Claude Code 尚未登入,請在終端機執行 claude /login"
        case .codexNotFound: return "找不到 codex 指令,請先安裝 Codex CLI"
        case .codexNotLoggedIn: return "Codex CLI 尚未登入,請在終端機執行 codex login"
        case .timeout: return "校正逾時,請稍後再試"
        case .badOutput(let s): return "校正回應無法解析:\(s)"
        case .failed(let code, let s): return "校正失敗(exit \(code)):\(s)"
        case .unavailable(let key): return key
        }
    }
}

/// 提示詞(CORR-06):**只含段號＋該段文字**。沒有參數可以塞檔名、會議名、日期、講者——
/// 簽章本身就是資料範圍的保證,SelfTest 再釘一次。中文截段照拾音慣例:短系統提示＋
/// 使用者訊息列段落。
public enum CorrectionPrompt {
    public static func system(for language: TranscriptionLanguage) -> String {
        switch language.isChinese {   // AFM-13:與 AFM 後端的 @Guide 描述共用同一個判準
        case true:
            return "你是會議逐字稿的校對助手。只做一件事:找出語音辨識最可能聽錯的詞並提出修正建議,不重寫句子、不加內容。original 必須是該段原文裡一字不差、連續出現的文字,只包含要改的詞,越短越好;suggestion 是改正後的文字;reason 用一句話。沒有把握的地方不要提。"
        default:
            return "You proofread meeting transcripts produced by speech recognition. Do one thing only: find the words most likely misheard and suggest corrections. Do not rewrite sentences or add content. \"original\" must appear exactly and contiguously in that segment, containing only the words to fix, as short as possible; \"suggestion\" is the corrected text; \"reason\" is one sentence. Skip anything you are not sure about."
        }
    }

    public static func user(segments: [String], range: Range<Int>, language: TranscriptionLanguage) -> String {
        let isZh = language.isChinese
        let head = isZh
            ? "下面是語音辨識出的會議逐字稿,每段前面是段號。找出最可能聽錯的地方並提出修正,只回 JSON。"
            : "Below is a speech-recognition transcript of a meeting; each line starts with its segment number. Find the most likely mishearings and suggest corrections. Reply with JSON only."
        let body = range.map { "\($0): \(segments[$0])" }.joined(separator: "\n")
        return head + "\n" + body
    }

    /// 結構化輸出的 JSON Schema(與拾音同形:segment/original/suggestion/reason)。
    public static let schema = """
    {"type":"object","additionalProperties":false,"required":["corrections"],"properties":{"corrections":{"type":"array","items":{"type":"object","additionalProperties":false,"required":["segment","original","suggestion","reason"],"properties":{"segment":{"type":"integer"},"original":{"type":"string"},"suggestion":{"type":"string"},"reason":{"type":"string"}}}}}}
    """
}

#if DEBUG
/// 本地假供應商(CORR-02/08):不碰網路、不 spawn 任何東西,回固定建議——每個含
/// 「竹子稿」的段落建議改「逐字稿」,再附一則**故意無效**的建議(original 不在原文),
/// 用來驗 `validate` 真的會把它丟掉(畫面只該出現有效的那幾則)。DEBUG 限定(MDL-04)。
public struct LocalFakeProvider: CorrectionProvider {
    public init() {}
    public func suggest(segments: [String], range: Range<Int>, language: TranscriptionLanguage) async throws -> CorrectionResult {
        var out: [CorrectionSuggestion] = []
        for i in range where segments[i].contains("竹子稿") {
            out.append(CorrectionSuggestion(segment: i, original: "竹子稿", suggestion: "逐字稿", reason: "同音誤辨(假供應商)"))
        }
        if let first = range.first {
            out.append(CorrectionSuggestion(segment: first, original: "這幾個字不在原文裡", suggestion: "x", reason: "故意無效"))
        }
        return CorrectionResult(suggestions: out)
    }
}
#endif
