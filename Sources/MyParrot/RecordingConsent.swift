import AppKit
import SwiftUI
import MyParrotCore

/// MAS-17(#2646,App Review 2.5.14;兩版都有):第一次按「開始錄音」先跳一次性提示,按「我知道了，開始錄音」才開錄;
/// 偏好 `recordingConsentShown` 記住、之後不再跳。四個 GUI 入口(遙控器大鈕、迷你列、⌘R、會議提醒通知)都經這裡;
/// 🚫 不擋 DebugControl 直呼 `startRecording`(驗證路徑;`consent show` 才會走提示)。
@MainActor
enum RecordingConsent {
    static let key = "recordingConsentShown"
    static var shown: Bool { UserDefaults.standard.bool(forKey: key) }
    static func markShown() { UserDefaults.standard.set(true, forKey: key) }
    static func reset() { UserDefaults.standard.removeObject(forKey: key) }

    /// 目前掛著的提示(DebugControl `consent accept|cancel` 用同一條路回答)。
    private static var pending: (alert: NSAlert, window: NSWindow)?
    static var isPresented: Bool { pending != nil }

    /// 看過 ⇒ 直接 proceed;沒看過 ⇒ 有可見視窗就掛 sheet,沒有(迷你／關窗)就 runModal;同意才 proceed。
    static func confirmThen(_ proceed: @escaping @MainActor () -> Void) {
        if shown { proceed(); return }
        guard pending == nil else { return }   // 二審:框還掛著時連按(快捷鍵／鈕／通知)不再掛第二個
        let alert = NSAlert()
        alert.messageText = L("錄音前請先告知對方")
        alert.informativeText = L("依所在地法律，錄音可能需要取得對方同意。這個提醒只會出現一次。")
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("我知道了，開始錄音"))
        alert.addButton(withTitle: L("取消"))
        if let window = NSApp.keyWindow ?? NSApp.mainWindow, window.isVisible {
            pending = (alert, window)
            alert.beginSheetModal(for: window) { response in
                pending = nil
                guard response == .alertFirstButtonReturn else { return }
                markShown()
                proceed()
            }
        } else if alert.runModal() == .alertFirstButtonReturn {
            markShown()
            proceed()
        }
    }

    /// DebugControl:回答掛著的 sheet(等同按鈕)。沒有掛著 ⇒ false。
    @discardableResult
    static func respond(accept: Bool) -> Bool {
        guard let p = pending else { return false }
        guard p.window.attachedSheet == p.alert.window else { pending = nil; return false }   // 視窗已關、sheet 不在了
        p.window.endSheet(p.alert.window, returnCode: accept ? .alertFirstButtonReturn : .alertSecondButtonReturn)
        return true
    }
}

/// MAS-17 2.5.14 錄音中可見指示:Dock 圖示 badge「REC」＋選單列狀態項(紅點＋字)。標準／窄版／迷你本來就有 LED 與吉祥物,
/// 關窗(-backgroundStart、使用者把視窗關掉)時只剩這兩層;8/23 二審指出選單列會被自動隱藏或瀏海擠掉,所以兩層都做。
@MainActor
enum RecordingIndicator {
    private static var statusItem: NSStatusItem?
    private static let target = StatusItemTarget()

    static func update(state: RecordingState) {
        let active = state == .recording || state == .paused
        NSApp.dockTile.badgeLabel = active ? (state == .paused ? "II" : "REC") : nil
        guard active else {
            if let item = statusItem { NSStatusBar.system.removeStatusItem(item); statusItem = nil }
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            item.button?.target = target
            item.button?.action = #selector(StatusItemTarget.activate)
            statusItem = item
        }
        statusItem?.button?.title = (state == .paused ? "⏸ " : "● ") + L(state == .paused ? "已暫停" : "錄音中")
        statusItem?.button?.contentTintColor = state == .paused ? .systemOrange : .systemRed
        statusItem?.button?.toolTip = "MyParrot"
    }

    static var isShowing: Bool { statusItem != nil }
    static var badge: String? { NSApp.dockTile.badgeLabel }

    /// 點狀態項 ⇒ 把 app 叫到前面(關窗時等於重新打開視窗)。
    final class StatusItemTarget: NSObject {
        @objc func activate() {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
        }
    }
}
