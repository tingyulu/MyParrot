import Foundation

/// BUG-28(#1680):錄音中的警示橫幅原本是 Core 直接指派繁中字串、GUI `Text(warn)`
/// 原樣顯示,英/日/韓/簡中介面照樣跳中文(2026-09-17 拍 #1667 英文截圖時撞到)。
/// 改成 Core 只丟「是哪一種警示 + 參數」,GUI 依介面語言組字。
///
/// 三個約定:
/// 1. `template` 的繁中原文=改版前寫死的字串,**逐字不變**,同時當 GUI 翻譯表的 key。
/// 2. `zhTW` 組出的整句=改版前的整句,CLI 與 state.json 照舊輸出這個(CLI 零修改)。
/// 3. `l10n-keys:begin/end` 之間的字面值由 `scripts/check-translations.swift` 掃描,
///    缺翻譯或標記不見就 exit 1(動態 key 靜態掃不到,所以要標記)。

/// 模板參數:系統給的裝置名不翻譯,繁中 key 才交給 UI 查表。
public enum WarningArgument: Sendable, Equatable {
    /// 系統字串(裝置名…),原樣顯示。
    case raw(String)
    /// 繁中 key,UI 依介面語言翻譯;繁中介面查不到就回傳 key 本身。
    case localizable(String)

    public var zhTW: String {
        switch self {
        case .raw(let s), .localizable(let s): return s
        }
    }
}

/// `%@` 佔位符的填值工具。刻意不用 `String(format:)`:譯文若多寫一個 `%@`,
/// `String(format:)` 會讀到越界的參數(未定義行為/當機),逐一替換只會少填。
public enum L10nFormat {
    public static let placeholder = "%@"

    public static func placeholderCount(_ template: String) -> Int {
        template.components(separatedBy: placeholder).count - 1
    }

    /// 依序把 `%@` 換成 `args`;多出來的佔位符原樣留著(由呼叫端先驗數量)。
    public static func fill(_ template: String, _ args: [String]) -> String {
        var out = ""
        var rest = Substring(template)
        var i = 0
        while let r = rest.range(of: placeholder) {
            out += rest[rest.startIndex..<r.lowerBound]
            if i < args.count { out += args[i]; i += 1 } else { out += placeholder }
            rest = rest[r.upperBound...]
        }
        return out + rest
    }
}

/// 你軌(麥克風)自動重建的原因。
public enum MicRebuildReason: Sendable, Equatable, CaseIterable {
    case signalLost, deviceRemoved

    public var template: String {
        switch self {
        // l10n-keys:begin
        case .signalLost:    return "你軌訊號中斷"
        case .deviceRemoved: return "選用的麥克風已移除"
        // l10n-keys:end
        }
    }
    public var zhTW: String { template }
}

/// 對方軌(系統音訊 tap)自動重建的原因。
public enum SysRebuildReason: Sendable, Equatable, CaseIterable {
    case signalLost, persistentSilence, outputDeviceChanged

    public var template: String {
        switch self {
        // l10n-keys:begin
        case .signalLost:          return "對方軌訊號中斷"
        case .persistentSilence:   return "對方軌持續無聲"
        case .outputDeviceChanged: return "系統輸出裝置變更"
        // l10n-keys:end
        }
    }
    public var zhTW: String { template }
}

/// 錄音中的橘色警示橫幅。新增 case 必須同時補 `template` 與 `arguments`
/// (兩個 switch 都窮舉,漏了編譯不過)。
public enum RecordingWarning: Sendable, Equatable {
    case engineChangeDeferred
    case whisperModelMissing
    case cloudNotConfigured
    case micSwitched(device: String)
    case micSwitchFailed(device: String)
    case micReconnected(reason: MicRebuildReason, device: String?)
    case sysRebuildMaybeStillSilent
    case sysRestarted(reason: SysRebuildReason)
    case micSilentBluetooth
    /// AUD-38(#2529):藍牙麥 HFP 格式反覆切換,MicCapture 震盪鎖已停止自動重建。
    case micBluetoothUnstable(device: String)
    case micSilent
    case sysSilent
    /// PERM-05(#2673):輸出裝置**不是**藍牙時的對方軌無聲警告——HFP 說法不成立,先請確認會議聲音在這台 Mac 播放,
    /// 再提「可能是系統音訊錄製權限沒開」(沒有公開 API 查那個權限,只能推論);重建後仍無聲也用這一句。
    case sysSilentCheckPermission
    case deviceChanged

    /// 繁中模板(`%@`=參數位置),同時是翻譯表的 key。
    public var template: String {
        switch self {
        // l10n-keys:begin
        case .engineChangeDeferred:
            return "逐字稿引擎將於本次錄音結束後生效"
        case .whisperModelMissing:
            return "Whisper 模型未安裝 — 到設定下載後生效,暫用 macOS 原生引擎"
        case .cloudNotConfigured:
            return "雲端引擎尚未設定,暫用 macOS 原生引擎"
        case .micSwitched:
            return "已切換麥克風為「%@」,你軌(右)會有短暫空白"
        case .micSwitchFailed:
            return "⚠️ 切換到「%@」失敗、原麥克風也起不來,你軌(右)現在收不到音 — 請停止錄音、重選裝置再錄"
        case .micReconnected:
            return "偵測到你的麥克風中斷(%@),已自動重接「%@」"
        case .sysRebuildMaybeStillSilent:
            return "已嘗試自動重建對方軌,但可能仍收不到 — 若用藍牙耳機當輸出會走 HFP/電話模式而擷取不到,請改用內建喇叭或有線輸出"
        case .sysRestarted:
            return "偵測到系統音訊擷取中斷(%@),已自動重新啟動"
        case .micSilentBluetooth:
            return "⚠️ 你選的是藍牙麥克風,整場可能收不到聲音(常被會議 app 佔住或掉窄頻)— 請到設定改用內建或 USB 麥克風"
        case .micBluetoothUnstable:
            return "⚠️ 藍牙麥克風「%@」在此系統無法穩定擷取（HFP 格式反覆切換），你軌（右）已停止自動重建 — 請切回內建或有線麥克風"
        case .micSilent:
            return "你的麥克風似乎沒收到聲音 — 請到設定確認「你的麥克風」選對裝置"
        case .sysSilent:
            return "⚠️ 對方(系統音訊)沒收到聲音 — 若用藍牙耳機當輸出,通話會走 HFP/電話模式而擷取不到對方,請改用內建喇叭或有線輸出;並確認會議音訊在這台 Mac 上播放"
        case .sysSilentCheckPermission:
            return "⚠️ 對方(系統音訊)沒收到聲音 — 請確認會議音訊在這台 Mac 上播放;若已在播放,可能是「系統音訊錄製」權限沒開,請到系統設定允許 MyParrot"
        case .deviceChanged:
            return "偵測到音訊裝置變更,錄音續行中,請確認狀態"
        // l10n-keys:end
        }
    }

    /// 依序對應 `template` 裡的 `%@`。
    public var arguments: [WarningArgument] {
        switch self {
        case .micSwitched(let device), .micSwitchFailed(let device), .micBluetoothUnstable(let device):
            return [.raw(device)]
        case .micReconnected(let reason, let device):
            // 裝置名是系統字串不翻;沒有裝置名時退回可翻的「系統預設」。
            // l10n-keys:begin
            return [.localizable(reason.template), device.map { .raw($0) } ?? .localizable("系統預設")]
            // l10n-keys:end
        case .sysRestarted(let reason):
            return [.localizable(reason.template)]
        case .engineChangeDeferred, .whisperModelMissing, .cloudNotConfigured,
             .sysRebuildMaybeStillSilent, .micSilentBluetooth, .micSilent,
             .sysSilent, .sysSilentCheckPermission, .deviceChanged:
            return []
        }
    }

    /// 繁中整句 = 改版前寫死的字串。CLI / state.json / 終端電平表用這個。
    public var zhTW: String {
        L10nFormat.fill(template, arguments.map(\.zhTW))
    }

    /// B2(Eric 2026-09-17):對方軌恢復真訊號時自動收起的兩種。其他警示
    /// (麥克風、裝置變更、引擎…)與對方軌有沒有聲音無關,不能被收掉。
    public var clearsWhenSysSignalReturns: Bool {
        switch self {
        case .sysSilent, .sysRebuildMaybeStillSilent, .sysSilentCheckPermission: return true
        case .engineChangeDeferred, .whisperModelMissing, .cloudNotConfigured,
             .micSwitched, .micSwitchFailed, .micReconnected, .sysRestarted,
             .micSilentBluetooth, .micBluetoothUnstable, .micSilent, .deviceChanged: return false
        }
    }

    /// PERM(#2673):橫幅上要不要多一顆可行動的鈕(GUI 畫鈕;CLI／state.json 照舊只有 `zhTW` 整句)。
    public var action: WarningAction? {
        switch self {
        case .sysSilentCheckPermission:
            return .openSystemSettings(pane: PermissionKind.systemAudio.settingsPane)
        case .engineChangeDeferred, .whisperModelMissing, .cloudNotConfigured,
             .micSwitched, .micSwitchFailed, .micReconnected, .sysRebuildMaybeStillSilent, .sysRestarted,
             .micSilentBluetooth, .micBluetoothUnstable, .micSilent, .sysSilent, .deviceChanged:
            return nil
        }
    }
}

/// 警示橫幅上的可行動鈕。
public enum WarningAction: Sendable, Equatable {
    /// 帶人去「系統設定 → 隱私權與安全性」的某個分頁(`x-apple.systempreferences:` 後那段)。
    case openSystemSettings(pane: String)
}
