import SwiftUI
import AppKit
import MyParrotCore

@main
struct MyParrotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var controller = RecordingController()
    @State private var miniMode = false

    var body: some Scene {
        WindowGroup("MyParrot") {
            Group {
                if miniMode {
                    MiniView(controller: controller, miniMode: $miniMode)
                } else {
                    RootView(controller: controller, miniMode: $miniMode)
                }
            }
            // UI-20: 視窗最小尺寸的**單一真相**(RootView 不再自帶 frame——雙重約束
            // 取大者,曾讓 RootView 的 320 被這裡的舊 720 蓋掉而失效)。
            // 320 = 逐字稿標題+190pt picker 的內容下限。
            // UI-21 v4: minHeight 620——逐字稿/列表間改 VSplitView 可拖曳分隔後,
            // 內容下限=控制卡+逐字稿 pane min 140+列表 pane min 88+adBar;620 保證
            // footer 兩行完整、其餘比例使用者自己拖(不再硬寫死列表高度)。
            .frame(minWidth: miniMode ? 300 : 320,
                   minHeight: miniMode ? 60 : 620)
            .onAppear { appDelegate.controller = controller }
        }
        .windowResizability(.contentSize)
        // UI-21: 移除 hiddenTitleBar(它把內容拉進標題列、與工具列疊字=Eric 回報的
        // header overlap)。改用原生標題列(內容乾淨落在其下),迷你/設定兩鈕移進內容
        // 首列的 statusCard(見 RootView),不再靠 macOS 工具列(窄視窗會收「»」)。
    }
}

/// Intercepts quit while a recording is in progress so it isn't lost. Default
/// action keeps recording; choosing to quit stops & saves first (the CAF is
/// finalized synchronously in stop(); m4a conversion resumes on next launch).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: RecordingController?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let c = controller, c.state == .recording || c.state == .paused else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L("錄音還在進行中")
        alert.informativeText = L("要先結束並儲存這段錄音,還是繼續錄音?")
        alert.alertStyle = .warning
        alert.addButton(withTitle: L("繼續錄音"))        // first button = default (Return)
        alert.addButton(withTitle: L("結束錄音並離開"))
        if alert.runModal() == .alertFirstButtonReturn {
            return .terminateCancel                      // 繼續錄音
        }
        c.stop()                                         // 存檔後離開
        return .terminateNow
    }
}

// Shared formatting + palette.
enum MP {
    // UI-22 Phase C: 品牌色深色模式提高明度/飽和度(淺色底下的飽和色到深色底
    // 會顯髒灰);用 NSColor dynamicProvider 讓同一個 Color 依系統外觀自動切換,
    // 不用 xcassets(SwiftPM 加 resources 要動 Package.swift,越界)。
    private static func dynamicColor(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil, dynamicProvider: { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            let rgb = isDark ? dark : light
            return NSColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1.0)
        }))
    }

    static let blue = dynamicColor(light: (0.216, 0.541, 0.867), dark: (0.32, 0.62, 0.93))   // 你 / brand
    static let coral = dynamicColor(light: (0.847, 0.353, 0.188), dark: (0.91, 0.45, 0.30))  // 對方
    static let recRed = dynamicColor(light: (0.639, 0.176, 0.176), dark: (0.85, 0.32, 0.32))

    // Stronger, clearly-visible lines (the faint 0.5px ones were hard to read).
    static let line = Color.primary.opacity(0.22)
    static let strongLine = Color.primary.opacity(0.32)
    static func card(_ scheme: ColorScheme) -> Color { Color.primary.opacity(0.04) }

    // UI-22:8pt 網格間距 tokens——外層/卡內/row 各處各寫一個數字改成這 4 階,
    // 0-12 之間的雜數(1/2/3/6/9/10/11)就近併過來(平手取大)。
    static let spXS: CGFloat = 4
    static let spS: CGFloat = 8
    static let spM: CGFloat = 12
    static let spL: CGFloat = 16

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

/// UI-22:字級 tokens——5 階就近映射全 UI 既有的字級數字寫法
/// (9/10/11→caption;12→label;13/14→body;15/16→title;20→display),
/// 收斂成統一字級語言而非各處各寫一個 size/weight。icon-only 鈕(pip/gear)
/// 的 14pt 是視覺尺寸不是文字,刻意不收斂,見 RootView 該處註解。
enum MPFont {
    static let display = Font.system(size: 18, weight: .semibold, design: .monospaced) // 計時器(20→18 拉近級距)
    static let title   = Font.system(size: 15, weight: .semibold)   // 卡片/Sheet 標題
    static let body    = Font.system(size: 13)                      // 內文/按鈕
    static let label   = Font.system(size: 12, weight: .medium)     // 狀態/列表標題輔助
    static let caption = Font.system(size: 11)                      // 副標/meta
}

/// Shared mic-picker label: ⚠️ for Bluetooth (avoid), (iPhone) for Continuity.
/// Used by both the Settings picker and the main-screen quick picker so the
/// two never disagree about how a device is marked.
@MainActor func micLabel(_ d: AudioInputDevice) -> String {
    if d.isBluetooth { return "⚠️ \(d.name)" + L("(藍牙)") }
    if d.isContinuity { return "\(d.name)" + L("(iPhone)") }
    return d.name
}
