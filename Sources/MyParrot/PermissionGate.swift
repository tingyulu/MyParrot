import AppKit
import SwiftUI
import os
import MyParrotCore

/// PERM-03(#2673,Eric 11/01 A2;兩版都有):按「開始錄音」時麥克風權限已拒絕／受限 ⇒ 先跳一次三鈕確認框
/// 【開啟系統設定】【仍要錄音】【取消】;「仍要錄音」才往下走 MAS-17 的錄音同意提示。所有 GUI 開錄入口
/// (遙控器大鈕、迷你列、⌘R／選單、會議提醒通知)都經 `RecordingGate.confirmThen`;🚫 不擋 DebugControl 直呼 `startRecording`。
/// 只看麥克風:語音辨識被拒不擋(錄音照常,只是沒即時稿);系統音訊查不到(PermissionHint.swift 檔頭)。
@MainActor
enum RecordingGate {
    /// 回 false＝這次請求被丟掉(gate 框或同意框已經掛著);DebugControl 用它回報,不假裝成功(二審第二、三輪)。
    /// 麥克風還沒問過 ⇒ 先跳系統框、答完再走一次(`afterRequest` 防重入),免得請求還掛著就開錄、8 秒後怪裝置(二審第三輪)。
    @discardableResult
    static func confirmThen(_ controller: RecordingController, afterRequest: Bool = false,
                            _ proceed: @escaping @MainActor () -> Void) -> Bool {
        controller.refreshPermissionStatus()   // PERM-01:按下去那一刻的真狀態(使用者可能剛從系統設定切回來)
        switch PermissionHints.recordGateAction(mic: controller.micAuthorization, alreadyRequested: afterRequest) {
        case .pass:
            return RecordingConsent.confirmThen(proceed)
        case .requestFirst:
            Task { @MainActor in
                await controller.requestPermission(.microphone)
                confirmThen(controller, afterRequest: true, proceed)
            }
            return true
        case .block:
            return PermissionGate.present(controller: controller) {
                if !RecordingConsent.confirmThen(proceed) { os_log("MyParrot perm: 同意框已開著,「仍要錄音」這次沒接上") }
            }
        }
    }
}

/// 三鈕確認框本體。有可見視窗就掛 sheet,沒有(迷你／關窗)就 runModal;框掛著時連按不疊第二個(同 MAS-17 二審)。
@MainActor
enum PermissionGate {
    enum Choice: String { case settings, proceed, cancel }

    private static var pending: (alert: NSAlert, window: NSWindow?, controller: RecordingController, onProceed: @MainActor () -> Void)?
    static var isPresented: Bool { pending != nil }

    /// 回 false＝已有框掛著、這次丟掉。
    @discardableResult
    static func present(controller: RecordingController, onProceed: @escaping @MainActor () -> Void) -> Bool {
        guard pending == nil else {
            // 二審:連按／多入口同時觸發 ⇒ 不疊第二個框(同 MAS-17),但留一行 log、回 false,不無聲吞掉。
            os_log("MyParrot perm: 麥克風權限確認框已開著,忽略再一次的開錄請求")
            return false
        }
        let alert = NSAlert()
        alert.messageText = L("麥克風權限未開啟")
        alert.informativeText = L("這段只會錄到對方(系統音訊)。要錄到你的聲音，請到「系統設定 → 隱私權與安全性 → 麥克風」允許 MyParrot。")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("開啟系統設定"))
        alert.addButton(withTitle: L("仍要錄音"))
        alert.addButton(withTitle: L("取消"))
        if let window = sheetHost() {
            // 二審:從通知／背景觸發時 app 可能不在前景,先叫到前面,否則框掛在看不見的視窗上、之後的點擊又被 pending 擋掉。
            if !NSApp.isActive { NSApp.activate() }
            pending = (alert, window, controller, onProceed)
            alert.beginSheetModal(for: window) { response in finish(response) }
        } else {
            pending = (alert, nil, controller, onProceed)
            finish(alert.runModal())
        }
        return true
    }

    /// 掛 sheet 的視窗:key／main 優先;app 不在前景時兩者都是 nil(11/01 真機:從背景腳本按 gate 直接走了 runModal,
    /// 模態迴圈把主執行緒的 DEBUG 通道一起卡住),退而找任何可見、可成為主視窗的一般視窗(標準／迷你都算)。
    /// 二審第二輪:key／main 也要「沒掛著別的 sheet」(設定頁、選夾、同意框開著時再掛會排隊到看不見);全都掛著 ⇒ nil ⇒ runModal。
    private static func sheetHost() -> NSWindow? {
        if let w = NSApp.keyWindow ?? NSApp.mainWindow, w.isVisible, w.attachedSheet == nil { return w }
        return NSApp.windows.first { $0.isVisible && $0.canBecomeMain && !($0 is NSPanel) && $0.attachedSheet == nil }
    }

    private static func finish(_ response: NSApplication.ModalResponse) {
        guard let p = pending else { return }
        pending = nil
        switch response {
        case .alertFirstButtonReturn:
            if !SystemSettingsOpener.open(PermissionKind.microphone.settingsPane) { p.controller.lastError = SystemSettingsOpener.failureMessage }
        case .alertSecondButtonReturn: p.onProceed()
        default: break
        }
    }

    /// DebugControl `perm-gate settings|proceed|cancel`:回答掛著的 sheet(等同按鈕)。沒有掛著、或是 runModal 的框 ⇒ false。
    @discardableResult
    static func respond(_ choice: Choice) -> Bool {
        guard let p = pending, let w = p.window else { return false }
        guard w.attachedSheet == p.alert.window else { pending = nil; return false }   // 視窗已關、sheet 不在了
        let code: NSApplication.ModalResponse
        switch choice {
        case .settings: code = .alertFirstButtonReturn
        case .proceed:  code = .alertSecondButtonReturn
        case .cancel:   code = .alertThirdButtonReturn
        }
        w.endSheet(p.alert.window, returnCode: code)
        return true
    }
}

/// 「系統設定 → 隱私權與安全性 → <分頁>」深連結(行事曆區段原本自己拼,這裡給錄音前橫幅／警示橫幅／設定頁權限列共用)。
@MainActor
enum SystemSettingsOpener {
    /// 兩層都開不了時給 `controller.lastError` 的繁中訊息(GUI 紅橫幅;`CoreMessageL10n` 依介面語言翻)。
    static let failureMessage = "無法開啟系統設定,請手動到「系統設定 → 隱私權與安全性」"

    /// 二審:`NSWorkspace.open` 回 false(某版 macOS 分頁深連結失效)不能當成功——退回「隱私權與安全性」總頁,再失敗就 log＋呼叫端給畫面錯誤。
    @discardableResult
    static func open(_ pane: String) -> Bool {
        if let u = URL(string: "x-apple.systempreferences:" + pane), NSWorkspace.shared.open(u) { return true }
        os_log(.error, "MyParrot perm: 開不了系統設定分頁 %{public}@,退回隱私權與安全性總頁", pane)
        if let u = URL(string: "x-apple.systempreferences:com.apple.preference.security"), NSWorkspace.shared.open(u) { return true }
        os_log(.error, "MyParrot perm: 連「隱私權與安全性」總頁都開不了")
        return false
    }
}
