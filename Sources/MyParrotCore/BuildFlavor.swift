import Foundation

/// #2646 Mac App Store 免費版(TEST_PLAN X 節):`MYPARROT_MAS=1 swift build` ⇒ Package.swift 給所有目標
/// `MYPARROT_MAS` 編譯條件 ⇒ 商店版。同一份原始碼、同一條 main,差異全在旗標之下;GitHub 版(Developer ID、
/// 全功能)一行行為都不變。**凡是「商店版不做／改走別條路」的判斷都經這裡或 `#if MYPARROT_MAS`**,
/// `grep -rn 'BuildFlavor\.\|MYPARROT_MAS' Sources` 就是守門點清單(MAS-01 對帳)。
/// 衍生開關全部由 `isMAS` 推出(SelfTest `masBuildFlavor` 守著),不會有一處忘了跟。
public enum BuildFlavor {
    /// 商店版(沙盒、bundle id `tw.uncle.MyParrot.mas`)。
    public static let isMAS: Bool = {
        #if MYPARROT_MAS
        return true
        #else
        return false
        #endif
    }()

    /// 2.4.5(vii):商店版更新只能走 Mac App Store ⇒ GitHub releases 更新檢查整段不編(UpdateChecker 的網路段)。
    public static var allowsUpdateChecker: Bool { !isMAS }
    /// 沙盒:Claude CLI／Codex CLI 後端要 spawn 使用者機器上的外部二進位,商店版登錄表不列(MAS-14)。
    public static var allowsCLIBackends: Bool { !isMAS }
    /// 2.5.2:行事曆提醒的「外部通知指令」是使用者自填的 shell,商店版忽略、設定頁不出現這欄(MAS-14)。
    public static var allowsExternalCommand: Bool { !isMAS }
    // (題 C 拍 2 後 watcher 兩版都開:協定檔已搬進 <錄音夾>/.myparrot,商店版看得到。)
    /// 沙盒下錄音夾只能是使用者在 NSOpenPanel 選的、用 security-scoped bookmark 記住(MAS-06);GitHub 版維持路徑字串。
    public static var usesSecurityScopedRecordingsDir: Bool { isMAS }
}
