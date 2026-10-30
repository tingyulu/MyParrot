import Foundation

/// #2438 T3 Phase 3 → #2612 TRL(Eric 2026-10-27 G1＋確認):逐字稿翻譯的抽象層。
/// 三個實作:`AppleTranslationProvider`(App 層,持 `TranslationSession`;Core 不 import Translation)、
/// `ClaudeCLITranslationProvider`／`CodexCLITranslationProvider`(Core,沿兩個 runner)。
/// 只加一行譯文、原文不動;Core 只認這個 protocol,不 import 任何 SDK、不含端點。
/// 回傳的 `lines` 與輸入一一對應(同長度、同順序);長度不符由 provider 自己丟 `badOutput`(TRL-05)。
public protocol TranslationProvider: Sendable {
    func translate(_ lines: [String], from: Locale.Language, to: Locale.Language) async throws -> TranslationResult
}

/// 一批翻譯的結果＋額度帳(TRL-11;Apple 後端 tokens 為 0)。
public struct TranslationResult: Sendable {
    public var lines: [String]
    public var inputTokens: Int
    public var outputTokens: Int
    public var durationMs: Int
    public init(lines: [String], inputTokens: Int = 0, outputTokens: Int = 0, durationMs: Int = 0) {
        self.lines = lines; self.inputTokens = inputTokens; self.outputTokens = outputTokens; self.durationMs = durationMs
    }
}

/// 翻譯失敗的原因(TRL-10)。訊息只給一句摘要,**不含** CLI 原始輸出全文;介面文字由 App 層對應 `L()`。
public enum TranslationError: Error, Sendable, Equatable {
    case cliNotFound
    case notLoggedIn
    case codexNotFound
    case codexNotLoggedIn
    case timeout
    case badOutput(String)      // 一句摘要
    case failed(Int32, String)  // exit code + 一句摘要
    /// Apple 後端這台用不了(語言包未裝／不支援);App 層再 L()。
    case unavailable(String)
}

/// 目標語言(TRL-01):偏好 `translation.target` 存 rawValue;檔名用 BCP-47(`<stem>.zh-Hant.srt`)。
public enum TranslationTarget: String, CaseIterable, Sendable, Codable {
    case zhHant = "zh-Hant"
    case en = "en"
    case ja = "ja"
    case ko = "ko"
    case zhHans = "zh-Hans"
    // MAS-28 D2:首版九語,翻譯目標也加四語(Apple Translation 語言包都有)。
    case es = "es"
    case de = "de"
    case fr = "fr"
    case ptBR = "pt-BR"

    public static let defaultsKey = "translation.target"
    public static let `default`: TranslationTarget = .zhHant

    /// 給 Apple Translation／提示詞用的語言(帶地區,Apple 的語言包是「繁體中文(台灣)」)。
    public var language: Locale.Language {
        switch self {
        case .zhHant: return Locale.Language(identifier: "zh-Hant-TW")
        case .en:     return Locale.Language(identifier: "en-US")
        case .ja:     return Locale.Language(identifier: "ja-JP")
        case .ko:     return Locale.Language(identifier: "ko-KR")
        case .zhHans: return Locale.Language(identifier: "zh-Hans-CN")
        case .es:     return Locale.Language(identifier: "es-ES")
        case .de:     return Locale.Language(identifier: "de-DE")
        case .fr:     return Locale.Language(identifier: "fr-FR")
        case .ptBR:   return Locale.Language(identifier: "pt-BR")
        }
    }

    /// 譯文檔副檔(含點前那段;`SidecarSet.extensions` 要有同名項目)。
    public var fileExtension: String { rawValue + ".srt" }

    /// 提示詞裡的語言名(英文,給 CLI 後端)。
    public var promptName: String {
        switch self {
        case .zhHant: return "Traditional Chinese (Taiwan)"
        case .en:     return "English"
        case .ja:     return "Japanese"
        case .ko:     return "Korean"
        case .zhHans: return "Simplified Chinese"
        case .es:     return "Spanish"
        case .de:     return "German"
        case .fr:     return "French"
        case .ptBR:   return "Brazilian Portuguese"
        }
    }

    /// 介面標籤(l10n key;App 層 `L(label)`)。
    public var label: String {
        switch self {
        // l10n-keys:begin
        case .zhHant: return "繁體中文"
        case .en:     return "英文"
        case .ja:     return "日文"
        case .ko:     return "韓文"
        case .zhHans: return "簡體中文"
        case .es:     return "西班牙文"
        case .de:     return "德文"
        case .fr:     return "法文"
        case .ptBR:   return "葡萄牙文（巴西）"
        // l10n-keys:end
        }
    }

    /// 標題列「譯 → 繁中」用的短名。
    public var shortLabel: String {
        switch self {
        // l10n-keys:begin
        case .zhHant: return "繁中"
        case .en:     return "英文"
        case .ja:     return "日文"
        case .ko:     return "韓文"
        case .zhHans: return "簡中"
        case .es:     return "西"
        case .de:     return "德"
        case .fr:     return "法"
        case .ptBR:   return "葡"
        // l10n-keys:end
        }
    }

    public static func resolve(_ raw: String?) -> TranslationTarget {
        raw.flatMap(TranslationTarget.init(rawValue:)) ?? .default
    }
}

/// 批次與節奏的純決策(TRL-04),SelfTest 直接驗。
public enum TranslationPlan {
    /// 一批上限(超過切兩批、順序不變)。
    public static let batchLimit = 60
    /// CLI 後端送出節奏選項(秒)與預設(Eric 裁示 1 分)。
    public static let cadenceOptions: [Int] = [30, 60, 120, 300]
    public static let defaultCadence = 60
    public static let cadenceKey = "translation.cadence"
    /// Codex 選 30 秒時的估算警語門檻(TRL-01;只提醒不擋)。
    public static let codexWarnCadence = 30
    /// 每批逾時(秒)。
    public static let timeout: TimeInterval = 90
    /// 連續失敗幾次自動暫停(沿 MIN-05)。
    public static let pauseAfterFailures = 3

    public static func nextBatch<T>(_ pending: [T], limit: Int = batchLimit) -> (batch: [T], rest: [T]) {
        let n = max(0, min(limit, pending.count))
        return (Array(pending.prefix(n)), Array(pending.dropFirst(n)))
    }

    /// 到節奏點、而且有待翻的行才送(0 行不送＝不花錢);第一批不等節奏;`force`(立即翻譯／結束錄音)只看有沒有行。
    public static func shouldFlush(cadence: TimeInterval, lastSentAt: Date?, now: Date, pendingCount: Int, force: Bool) -> Bool {
        guard pendingCount > 0 else { return false }
        if force { return true }
        guard let last = lastSentAt else { return true }
        return now.timeIntervalSince(last) >= cadence
    }

    /// 估算一小時會議(約 500 定稿行)的 tokens:每次呼叫基底＋每行;給設定頁的警語用(10/27 探針:Claude 1.5k＋45/行、Codex 13.5k＋45/行)。
    public static func estimatedTokensPerHour(cadenceSec: Int, basePerCall: Int, perLine: Int = 45, linesPerHour: Int = 500) -> Int {
        let calls = max(1, 3600 / max(1, cadenceSec))
        return calls * basePerCall + linesPerHour * perLine
    }
}

/// 譯文檔(TRL-08):與原 `.srt` 同時間碼、同講者,只換文字;沒譯的行寫「[未譯] 原文」。讀回時依序對齊。
public enum TranslationSRT {
    public static let untranslatedMarker = "[未譯]"

    public static func lines(original: [TranscriptLine], translations: [UUID: String]) -> [TranscriptLine] {
        original.map { line in
            var l = line
            if let t = translations[line.id], !t.isEmpty { l.text = t } else { l.text = untranslatedMarker + " " + line.text }
            return l
        }
    }

    /// 把讀回的譯文行對回現在的原稿行:同 index 且 start 差 < 0.05 s 才算同一行;`[未譯]` 開頭的不算已譯。
    public static func align(original: [TranscriptLine], translated: [TranscriptLine]) -> [UUID: String] {
        var out: [UUID: String] = [:]
        for (o, t) in zip(original, translated) where abs(o.start - t.start) < 0.05 && !t.text.hasPrefix(untranslatedMarker) && !t.text.isEmpty {
            out[o.id] = t.text
        }
        return out
    }
}

#if DEBUG
/// 本地假翻譯(DEBUG,TRL 驗證用):不 spawn、不出機,回「譯:原文」;含「失敗」二字的行讓整批丟錯(驗 TRL-10 的「未譯」路徑)。
public struct LocalFakeTranslationProvider: TranslationProvider {
    public init() {}
    public func translate(_ lines: [String], from: Locale.Language, to: Locale.Language) async throws -> TranslationResult {
        if lines.contains(where: { $0.contains("假失敗") }) { throw TranslationError.failed(1, "假供應商故意失敗") }
        return TranslationResult(lines: lines.map { "譯:" + $0 })
    }
}
#endif
