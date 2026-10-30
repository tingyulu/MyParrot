import Foundation

/// Transcription languages MyParrot supports. Default follows the system language;
/// unsupported system languages fall back to English. User-overridable in Settings.
public enum TranscriptionLanguage: String, CaseIterable, Identifiable, Sendable {
    case system
    case en
    case zhTW
    case ja
    case ko
    case zhCN
    // MAS-28 D2(Eric 2026-10-29):首版九語,辨識語言跟介面語言一起加(Apple SpeechAnalyzer 與 whisper 都支援)。
    case es
    case de
    case fr
    case ptBR

    public var id: String { rawValue }

    public var label: String {
        switch self {
        // l10n-keys:begin(BUG-28:只有這行要翻,其餘是各語言自己的名字)
        case .system: return "跟隨系統"
        // l10n-keys:end
        case .en:     return "English"
        case .zhTW:   return "繁體中文"
        case .ja:     return "日本語"
        case .ko:     return "한국어"
        case .zhCN:   return "简体中文"
        case .es:     return "Español"
        case .de:     return "Deutsch"
        case .fr:     return "Français"
        case .ptBR:   return "Português (Brasil)"
        }
    }

    private var explicitLocale: Locale? {
        switch self {
        case .system: return nil
        case .en:     return Locale(identifier: "en-US")
        case .zhTW:   return Locale(identifier: "zh-TW")
        case .ja:     return Locale(identifier: "ja-JP")
        case .ko:     return Locale(identifier: "ko-KR")
        case .zhCN:   return Locale(identifier: "zh-CN")
        case .es:     return Locale(identifier: "es-ES")
        case .de:     return Locale(identifier: "de-DE")
        case .fr:     return Locale(identifier: "fr-FR")
        case .ptBR:   return Locale(identifier: "pt-BR")
        }
    }

    /// Resolve to a concrete locale. `.system` follows the OS language; anything
    /// unsupported falls back to English.
    public func resolved() -> Locale {
        if let l = explicitLocale { return l }
        let code = Locale.current.language.languageCode?.identifier ?? "en"
        let region = Locale.current.language.region?.identifier
        switch code {
        case "zh": return Locale(identifier: (region == "CN" || region == "SG") ? "zh-CN" : "zh-TW")
        case "ja": return Locale(identifier: "ja-JP")
        case "ko": return Locale(identifier: "ko-KR")
        case "en": return Locale(identifier: "en-US")
        case "es": return Locale(identifier: "es-ES")
        case "de": return Locale(identifier: "de-DE")
        case "fr": return Locale(identifier: "fr-FR")
        case "pt": return Locale(identifier: "pt-BR")
        default:   return Locale(identifier: "en-US")
        }
    }
}
