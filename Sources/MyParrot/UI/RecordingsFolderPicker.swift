import AppKit
import MyParrotCore

/// 選錄音資料夾(設定頁「選擇…」與 MAS-06 首啟提示共用同一條路)。
/// 商店版:NSOpenPanel 就是 powerbox,選到的 URL 自帶 security scope,交給 `setRecordingsDir` 存書籤。
@MainActor
enum RecordingsFolderPicker {
    static func present(controller: RecordingController) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = L("選擇…")
        panel.message = L("MyParrot 會把錄音與逐字稿存在你選的資料夾;之後可在設定更改。")
        // 沙盒下 controller.recordingsDir 可能是容器內的佔位夾,起始位置改用真的家目錄 Documents(只是提示,powerbox 自己管權限)。
        panel.directoryURL = controller.needsRecordingsFolder
            ? URL(fileURLWithPath: NSHomeDirectoryForUser(NSUserName()) ?? NSHomeDirectory(), isDirectory: true).appendingPathComponent("Documents", isDirectory: true)
            : controller.recordingsDir
        if panel.runModal() == .OK, let url = panel.url { controller.setRecordingsDir(url) }
    }

    /// MAS-07:依書籤狀態給提示文(首啟／搬走／刪除／權限撤回)。
    static func promptMessage(for state: RecordingsFolderAccess.State) -> String {
        switch state {
        case .missing: return L("找不到原本的錄音資料夾(可能被搬走或刪除),請重新選擇。")
        case .denied:  return L("沒有權限寫入原本的錄音資料夾,請重新選擇。")
        case .unset, .valid, .stale: return L("MyParrot 會把錄音與逐字稿存在你選的資料夾;之後可在設定更改。")
        }
    }
}
