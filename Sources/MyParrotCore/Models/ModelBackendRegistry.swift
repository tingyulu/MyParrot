import Foundation

/// #2438 T3 後端登錄表(MDL-01/02):每個後端宣告自己支援哪些能力;設定頁「模型」區段每個能力
/// 各選一個後端,存在 `model.<能力>`。預設全部關閉——鍵不存在、值不在表內、或本建置不提供那個
/// 後端,一律解析成 `off`(沒設供應商 ⇒ 功能根本不出現)。
///
/// 假供應商 `localFake` 只在 DEBUG 建置進表(`debugOnly`):release 的 `all` 與 `backends(for:)`
/// 都看不到它,為 MDL-04「release 產物無 localFake」鋪路;`backends(for:)` 另外依 `debugOnly`
/// 過濾一次當雙保險。翻譯後端 Phase 3 才加(目前翻譯只有 off)。
public enum ModelBackendRegistry {

    /// 後端顯示名(l10n key;沿用 `CorrectionBackend.label` 既有的 key,翻譯表已有)。
    private enum Labels {
        // l10n-keys:begin
        static let off = "關閉"
        static let claudeCLI = "Claude CLI(本機)"
        static let codexCLI = "Codex CLI(本機)"
        static let appleFM = "Apple 本機模型"
        static let appleTranslation = "Apple 翻譯(本機)"
        #if DEBUG
        static let localFake = "本地假供應商(測試用)"
        #endif
        // l10n-keys:end
    }

    public static let offID = "off"

    /// 關閉:對每個能力都是合法選項;不出機。
    public static let off = ModelBackendInfo(id: offID, label: Labels.off,
                                             capabilities: Set(ModelCapability.allCases), isLocal: true)

    /// 本機 `claude` CLI(#2417 校正層配方;會議記錄 Phase 2 接)。資料會經 CLI 送到 Anthropic ⇒ 不是本機後端。
    public static let claudeCLI = ModelBackendInfo(id: CorrectionBackend.claudeCLI.rawValue, label: Labels.claudeCLI,
                                                   capabilities: [.correction, .minutes, .translation], isLocal: false)   // #2612 翻譯批次

    /// #2418 CDX-01:本機 `codex` CLI(ChatGPT 訂閱);資料經 CLI 送到 OpenAI ⇒ 出機後端、第一次選要跳隱私框。
    public static let codexCLI = ModelBackendInfo(id: CorrectionBackend.codexCLI.rawValue, label: Labels.codexCLI,
                                                  capabilities: [.correction, .minutes, .translation], isLocal: false)   // #2612 翻譯批次

    /// #2438 Phase 3a:Apple Foundation Models(macOS 26+)。資料不出機 ⇒ 本機後端、不跳隱私框;只在支援的 OS 進表。
    public static let appleFM = ModelBackendInfo(id: CorrectionBackend.appleFM.rawValue, label: Labels.appleFM,
                                                 capabilities: [.correction, .minutes], isLocal: true)

    /// #2612 TRL-01:Apple Translation framework(macOS 15+,本機、零 token、逐行即時);只做翻譯,不跳隱私框。
    public static let appleTranslation = ModelBackendInfo(id: "appleTranslation", label: Labels.appleTranslation,
                                                          capabilities: [.translation], isLocal: true)

    #if DEBUG
    /// 假供應商(DEBUG 驗證用,回固定內容)。
    public static let localFake = ModelBackendInfo(id: CorrectionBackend.localFake.rawValue, label: Labels.localFake,
                                                   capabilities: [.correction, .minutes, .translation], isLocal: true, debugOnly: true)
    #endif

    /// 登錄表全部後端(順序＝設定頁選單順序)。MAS-14:商店版不列兩個 CLI 後端(`BuildFlavor.allowsCLIBackends`)。
    public static let all: [ModelBackendInfo] = assemble(platformSupportsAFM: AFMAvailability.isPlatformSupported,
                                                         includeCLIBackends: BuildFlavor.allowsCLIBackends)

    /// 純函式(可測):依「這台 OS 有沒有 FoundationModels」決定 appleFM 進不進表;`includeCLIBackends == false`
    /// (商店版)不列 Claude CLI／Codex CLI;DEBUG 才有 localFake。
    public static func assemble(platformSupportsAFM: Bool, includeCLIBackends: Bool = true) -> [ModelBackendInfo] {
        var list = [off]
        if includeCLIBackends { list += [claudeCLI, codexCLI] }
        if platformSupportsAFM { list.append(appleFM) }
        list.append(appleTranslation)   // #2612
        #if DEBUG
        list.append(localFake)
        #endif
        return list
    }

    /// 本建置是否列出 debugOnly 後端。
    public static var includesDebugOnly: Bool {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }

    /// 某能力在本建置可選的後端(含 off)。
    public static func backends(for cap: ModelCapability) -> [ModelBackendInfo] {
        filter(all, for: cap, includeDebugOnly: includesDebugOnly)
    }

    /// 純函式(兩種建置都可測):依能力與 debugOnly 過濾。
    public static func filter(_ list: [ModelBackendInfo], for cap: ModelCapability, includeDebugOnly: Bool) -> [ModelBackendInfo] {
        list.filter { $0.capabilities.contains(cap) && (includeDebugOnly || !$0.debugOnly) }
    }

    /// 偏好鍵:`model.correction`／`model.minutes`／`model.translation`。
    public static func defaultsKey(for cap: ModelCapability) -> String { "model.\(cap.rawValue)" }

    /// 目前選的後端:鍵不存在＝off;值不在 `backends(for:)` 內(不認得／不支援這個能力／本建置不提供)＝off。
    public static func selected(for cap: ModelCapability, defaults: UserDefaults = .standard) -> ModelBackendInfo {
        resolve(defaults.string(forKey: defaultsKey(for: cap)), in: all, for: cap, includeDebugOnly: includesDebugOnly)
    }

    /// 純函式(MAS-14 可測):偏好的原始值 ＋ 本建置的登錄表 ⇒ 後端。鍵不存在／值不在表內／表內那個不支援此能力 ⇒ off。
    /// 商店版舊偏好若指到 CLI 後端(GitHub 版留下的),表裡沒有 ⇒ off、不崩、功能不出現。
    public static func resolve(_ raw: String?, in list: [ModelBackendInfo], for cap: ModelCapability,
                               includeDebugOnly: Bool) -> ModelBackendInfo {
        guard let raw, let hit = filter(list, for: cap, includeDebugOnly: includeDebugOnly).first(where: { $0.id == raw }) else { return off }
        return hit
    }

    /// 這個能力有沒有開(後端 ≠ off)。B2:會議記錄後端 off ⇒ 圖示、欄、自動更新設定全部不出現。
    public static func isEnabled(_ cap: ModelCapability, defaults: UserDefaults = .standard) -> Bool {
        selected(for: cap, defaults: defaults).id != offID
    }

    /// 寫入選擇。`id` 不在 `backends(for:)` 內 ⇒ 寫 off(fail closed,不留不認得的值)。
    public static func select(_ id: String, for cap: ModelCapability, defaults: UserDefaults = .standard) {
        let valid = backends(for: cap).contains { $0.id == id }
        defaults.set(valid ? id : offID, forKey: defaultsKey(for: cap))
    }

    // MARK: 隱私確認(T3 第 5 點／MDL-03)

    /// 偏好鍵 `privacyAccepted.<後端 id>`:**以後端為單位**,各能力共用——同一個後端只問一次。
    public static func privacyAcceptedKey(for backendID: String) -> String { "privacyAccepted.\(backendID)" }

    /// 選這個後端之前要不要先跳隱私確認框:出機後端(`isLocal == false`)且這個後端還沒同意過 ⇒ 要;
    /// 本機後端(含 off)、本建置不認得的 id ⇒ 不用(不認得的 id 交給 `select` fail closed 寫 off)。
    public static func needsPrivacyConfirmation(_ backendID: String, defaults: UserDefaults = .standard) -> Bool {
        guard let b = all.first(where: { $0.id == backendID }), !b.isLocal else { return false }
        return !defaults.bool(forKey: privacyAcceptedKey(for: backendID))
    }

    /// 使用者在確認框按「開啟」:記住這個後端已同意(之後任何能力選它都不再問)。
    public static func acceptPrivacy(_ backendID: String, defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: privacyAcceptedKey(for: backendID))
    }

    /// 舊鍵 → 新鍵(MDL-02):舊鍵有值且新鍵沒值 ⇒ 原樣複製(值合不合法交給 `selected` 判);
    /// **舊鍵不刪**(降版／其他讀者可能還在讀)。重跑無副作用。
    public static let legacyKeys: [(legacy: String, cap: ModelCapability)] = [
        (CorrectionBackend.defaultsKey, .correction)
    ]

    public static func migrateLegacyKeys(defaults: UserDefaults = .standard) {
        for (legacy, cap) in legacyKeys {
            let key = defaultsKey(for: cap)
            guard defaults.object(forKey: key) == nil, let old = defaults.string(forKey: legacy) else { continue }
            defaults.set(old, forKey: key)
        }
    }
}
