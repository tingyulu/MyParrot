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
            .frame(minWidth: miniMode ? 300 : 720,
                   minHeight: miniMode ? 60 : 480)
            .onAppear { appDelegate.controller = controller }
        }
        .windowResizability(.contentSize)
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
    static let blue = Color(red: 0.216, green: 0.541, blue: 0.867)   // 你 / brand
    static let coral = Color(red: 0.847, green: 0.353, blue: 0.188)  // 對方
    static let recRed = Color(red: 0.639, green: 0.176, blue: 0.176)

    // Stronger, clearly-visible lines (the faint 0.5px ones were hard to read).
    static let line = Color.primary.opacity(0.22)
    static let strongLine = Color.primary.opacity(0.32)
    static func card(_ scheme: ColorScheme) -> Color { Color.primary.opacity(0.04) }

    static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }
}

/// Shared mic-picker label: ⚠️ for Bluetooth (avoid), (iPhone) for Continuity.
/// Used by both the Settings picker and the main-screen quick picker so the
/// two never disagree about how a device is marked.
@MainActor func micLabel(_ d: AudioInputDevice) -> String {
    if d.isBluetooth { return "⚠️ \(d.name)" + L("(藍牙)") }
    if d.isContinuity { return "\(d.name)" + L("(iPhone)") }
    return d.name
}
