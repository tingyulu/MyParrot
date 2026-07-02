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

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .system: return "跟隨系統"
        case .en:     return "English"
        case .zhTW:   return "繁體中文"
        case .ja:     return "日本語"
        case .ko:     return "한국어"
        case .zhCN:   return "简体中文"
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
        default:   return Locale(identifier: "en-US")
        }
    }
}
