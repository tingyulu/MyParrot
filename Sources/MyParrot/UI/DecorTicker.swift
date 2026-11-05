import SwiftUI
import MyParrotCore

/// PERF-02(TEST_PLAN Z 節,Eric 2026-11-04 A1):錄音中裝飾動畫的唯一時鐘。
/// 之前紅光脈動、呼吸燈、鸚鵡點頭／聲波／唱歌／音符各掛一個 `withAnimation(.repeatForever)`,SwiftUI 在 ProMotion
/// 每一幀都走一次整窗 layout(11/04 實測主執行緒錄音中被吃 40～70%、打字卡)。
/// 這裡用 **Timer 式的 @State 時鐘**:每 0.1 s 改一次 `tick`,SwiftUI 就只跑一次 pass;每個 tick 用 `DecorClock` 查相位、直接設值、
/// **不包任何動畫**。一個視窗只放一個(遙控器根、迷你模式各一):每個 SwiftUI 更新都要付一次 NSHostingView 整窗 layout pass。
/// 🚫 不用 `TimelineView`:11/04 實測(macOS 27.0)只要樹上有 TimelineView——哪怕 `.periodic(by: 86400)`——display link 就每一幀
/// 進一次 layout pass(fix2 待錄音 render 樣本 148→777);基線鸚鵡 0.35 s 換幀的 TimelineView 也是同一個洞。
/// 🚫 之後工作區裡的持續動畫一律接這個,不准再用 `repeatForever`／`TimelineView`。
struct DecorTicker<Content: View>: View {
    static var interval: Duration { .milliseconds(100) }
    let active: Bool
    @ViewBuilder let content: (Date) -> Content
    @State private var tick: Date = .distantPast

    var body: some View {
        content(active ? tick : .distantPast)
            .task(id: active) {
                guard active else { return }
                tick = .now
                while !Task.isCancelled {
                    do { try await Task.sleep(for: Self.interval) } catch { return }   // 取消或任何錯誤都收工,不會變成快速迴圈
                    tick = .now
                }
            }
    }
}
