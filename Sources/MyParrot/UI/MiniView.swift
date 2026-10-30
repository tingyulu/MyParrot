import SwiftUI
import MyParrotCore

/// Floating mini mode — always-on-top pill with the mascot, timer, dual meters,
/// and transport. (Window-level "float above all" is set via NSWindow in v1.x.)
/// v3 定稿:迷你模式只留 icon,不印 ShortcutBadge 膠囊(空間小)——每顆鈕改用
/// .help() 帶出「功能名 ⌘鍵」提示;⌘R/⌘P/⌘E/⌘1 的實際鍵盤處理走 App 層
/// AppCommands(Commands 掛在 Scene,跟目前顯示哪個 View 無關,mini 模式下
/// 天生就有效,不用在這裡重複接線)。
struct MiniView: View {
    let controller: RecordingController
    let windowMode: WindowModeManager

    var body: some View {
        HStack(spacing: MP.spS) {
            ParrotMascot(size: 22, isRecording: controller.state == .recording)
            Circle().fill(MP.recRed).frame(width: 8, height: 8)
                .opacity(controller.state == .recording ? 1 : 0.25)
            Text(MP.clock(controller.elapsed))
                .font(MPFont.timer(15)).kerning(0.6).monospacedDigit()   // R1:與圓盤同款計時字型
            VStack(spacing: MP.spXS) {
                miniMeter(controller.otherLevel, MP.coral,
                          live: controller.state == .recording, ok: controller.sysHasSignal)
                miniMeter(controller.youLevel, MP.blue,
                          live: controller.state == .recording, ok: controller.micHasSignal)
            }.frame(width: 52)

            switch controller.state {
            case .recording:
                iconBtn("pause", label: L("暫停"), shortcut: "⌘P") { controller.pause() }
                iconBtn("stop", label: L("結束"), shortcut: "⌘E") { controller.stop() }
            case .paused:
                iconBtn("play", label: L("繼續"), shortcut: "⌘P") { controller.resume() }
                iconBtn("stop", label: L("結束"), shortcut: "⌘E") { controller.stop() }
            default:
                iconBtn("record.circle", label: L("開始錄音"), shortcut: "⌘R") { RecordingConsent.confirmThen { controller.startRecording() } }   // MAS-17
                    .disabled(controller.externalRecording != nil)   // #949:CLI 在錄就不開第二份
            }
            // v0.3.0 二審:錄音/暫停中也能按「新錄音」→ 與選單 finished-only 規則不一致。
            iconBtn("plus", label: L("新錄音")) { controller.newRecording() }
                .disabled(controller.state != .finished)
            // 「展開」= 回標準視窗,跟按 ⌘1 從迷你往下一態走是同一個 cycle() 動作
            // (定稿:迷你「展開」=回①,不是額外一個獨立按鈕)。
            iconBtn(windowMode.mode.icon, label: L("切換模式"), shortcut: "⌘1") { windowMode.cycle() }
        }
        .padding(.horizontal, MP.spM).padding(.vertical, MP.spS)
        .frame(minWidth: 300)
    }

    // UI-29 補漏(Eric 2026-08-24 06:07 抓):迷你模式當初漏套 MeterScale,還在線性
    // 標度(語音只到 ~16% 像沒聲音);與主畫面/播放列/設定頁同一 dB 刻度。
    private func miniMeter(_ v: Float, _ c: Color, live: Bool = false, ok: Bool = false) -> some View {
        HStack(spacing: MP.spXS) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.15))
                    RoundedRectangle(cornerRadius: 3).fill(c)
                        .frame(width: max(1, geo.size.width * CGFloat(MeterScale.fraction(v))))
                }
            }.frame(height: 5)
            if live {
                Circle().fill(ok ? Color.green : Color.orange).frame(width: 5, height: 5)
            }
        }
    }

    private func iconBtn(_ name: String, label: String, shortcut: String? = nil,
                          _ act: @escaping () -> Void) -> some View {
        Button(action: act) { Image(systemName: name).font(MPFont.title) }
            .buttonStyle(.plain)
            .help(shortcut.map { "\(label) \($0)" } ?? label)
            .accessibilityLabel(label)
    }
}
