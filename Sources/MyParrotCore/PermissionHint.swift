import Foundation
import AVFoundation
import Speech

/// PERM(#2673,TEST_PLAN Y 節):權限被拒引導的**純決策**部分。10/31 MAS-22 真機:拒麥克風時藍色橫幅的「授權」鈕
/// 重呼 `requestAccess`、已拒絕時系統直接回 false 不再跳框(按了沒反應),8 秒後的靜音橫幅又把權限問題歸因到裝置選擇;
/// 拒系統音訊時 tap 建得起來、buffer 一直全零,跟藍牙 HFP 同徵狀,舊文案怪到藍牙。
///
/// 事實邊界:麥克風(`AVCaptureDevice.authorizationStatus`)與語音辨識(`SFSpeechRecognizer.authorizationStatus`)四態確定可查、
/// 讀取不會觸發詢問框 ⇒ **確定性引導**(錄音前就知道);系統音訊錄製(`kTCCServiceAudioCapture`)沒有公開查詢 API ⇒
/// 只能在錄音中「tap 建好卻持續無訊號」時**推論**,分流訊號是輸出裝置的傳輸類型(HFP 只發生在藍牙輸出),文案用「可能」。
/// 這裡不碰 TCC、不碰 UI;GUI 依介面語言組字、CLI 印繁中。

/// 四態,對應 AVFoundation／Speech 的授權狀態。
public enum PermissionState: String, Sendable, Equatable, CaseIterable {
    case notDetermined, denied, restricted, authorized

    public init(_ s: AVAuthorizationStatus) {
        switch s {
        case .authorized: self = .authorized
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notDetermined
        @unknown default: self = .restricted   // 二審:未知的新狀態保守當「不可請求」,給系統設定出口而不是一顆沒反應的授權鈕
        }
    }

    public init(_ s: SFSpeechRecognizerAuthorizationStatus) {
        switch s {
        case .authorized: self = .authorized
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notDetermined
        @unknown default: self = .restricted
        }
    }

    /// 已拒絕或被管理者限制:再請求不會跳框,只有系統設定能改(restricted 連系統設定也改不了,但出口一樣)。
    public var isBlocked: Bool { self == .denied || self == .restricted }
}

/// 三種權限與各自在「系統設定 → 隱私權與安全性」的分頁。
public enum PermissionKind: String, Sendable, Equatable, Hashable, CaseIterable {
    case microphone, speech, systemAudio

    /// `x-apple.systempreferences:` 後面那段。
    public var settingsPane: String {
        switch self {
        case .microphone:  return "com.apple.preference.security?Privacy_Microphone"
        case .speech:      return "com.apple.preference.security?Privacy_SpeechRecognition"
        case .systemAudio: return "com.apple.preference.security?Privacy_AudioCapture"
        }
    }

    public var settingsURL: URL { URL(string: "x-apple.systempreferences:" + settingsPane)! }
}

/// 橫幅上那顆鈕該做什麼。
public enum PermissionAction: Sendable, Equatable {
    /// 還沒問過:按了會跳系統詢問框(`requestPermissions()`)。
    case request
    /// 已拒絕／受限:再請求沒反應,只能帶人去系統設定對應分頁。
    case openSystemSettings(pane: String)
}

/// 錄音前橫幅的一條:哪個權限、繁中模板(同時是翻譯表 key)、按鈕動作。
public struct PermissionHint: Sendable, Equatable, Identifiable {
    public let kind: PermissionKind
    public let template: String
    public let action: PermissionAction
    public var id: PermissionKind { kind }
}

public enum PermissionHints {
    // l10n-keys:begin
    static let micNotDetermined   = "需要麥克風權限才能錄到你的聲音"
    static let micBlocked         = "麥克風權限未開啟 — 這段只會錄到對方(系統音訊)"
    static let speechNotDetermined = "需要語音辨識權限才有即時逐字稿"
    static let speechBlocked      = "語音辨識權限未開啟 — 這段不會有即時逐字稿"
    // l10n-keys:end

    /// PERM-02:錄音前該掛哪些橫幅。麥克風永遠評估;語音辨識只在即時引擎真的需要那個 TCC 時才評估
    /// (macOS 26 SpeechAnalyzer 不走語音辨識 TCC,拒了也不影響,提了是噪音)。`.authorized` 不出現。
    public static func decide(mic: PermissionState, speech: PermissionState, speechNeeded: Bool) -> [PermissionHint] {
        var out: [PermissionHint] = []
        if let h = hint(.microphone, mic, notDetermined: micNotDetermined, blocked: micBlocked) { out.append(h) }
        if speechNeeded, let h = hint(.speech, speech, notDetermined: speechNotDetermined, blocked: speechBlocked) { out.append(h) }
        return out
    }

    private static func hint(_ kind: PermissionKind, _ state: PermissionState,
                             notDetermined: String, blocked: String) -> PermissionHint? {
        switch state {
        case .authorized:    return nil
        case .notDetermined: return PermissionHint(kind: kind, template: notDetermined, action: .request)
        case .denied, .restricted:
            return PermissionHint(kind: kind, template: blocked, action: .openSystemSettings(pane: kind.settingsPane))
        }
    }

    /// PERM-04:錄音中 8 秒麥克風無聲該跳哪條橫幅。麥克風被拒／受限 ⇒ nil(錄音前橫幅已講清楚後果,再跳「選對裝置」就是誤歸因);
    /// 還沒決定(系統框還掛著)也 nil(二審第三輪:權限未決就怪裝置一樣是誤歸因);已授權照舊:藍牙麥 ⇒ `.micSilentBluetooth`,否則 `.micSilent`。
    public static func micSilentWarning(auth: PermissionState, isBluetooth: Bool) -> RecordingWarning? {
        guard auth == .authorized else { return nil }
        return isBluetooth ? .micSilentBluetooth : .micSilent
    }

    /// PERM-03(Eric A2):按錄音時要不要先跳「麥克風權限未開啟」三鈕確認框。只看麥克風;語音辨識被拒不擋。
    public static func recordGateBlocks(mic: PermissionState) -> Bool { mic.isBlocked }

    /// PERM-03(二審第三輪):按錄音那一刻 gate 該做什麼。還沒問過 ⇒ 先請求(系統框),答完再依新狀態走一次;
    /// 已請求過仍是未決(理論上不會,保險)⇒ 放行;被拒／受限 ⇒ 三鈕框;已授權 ⇒ 放行。
    public enum RecordGateAction: Sendable, Equatable { case pass, requestFirst, block }
    public static func recordGateAction(mic: PermissionState, alreadyRequested: Bool) -> RecordGateAction {
        switch mic {
        case .authorized: return .pass
        case .notDetermined: return alreadyRequested ? .pass : .requestFirst
        case .denied, .restricted: return .block
        }
    }
}
