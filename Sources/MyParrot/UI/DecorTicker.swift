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
#if DEBUG
/// GATE-05 正控(TEST_PLAN AA 節):DebugControl `perf storm <hz>` 把裝飾時鐘催到每秒 N 次 ⇒ 每個 tick 一次整窗 pass,
/// 重現修前「高頻狀態變動 ⇒ 每幀整窗 layout」的機制;效能閘對它必須量到紅(render／CPU 爆門檻),否則閘的尺有問題。
/// 只在 DEBUG;`off`(nil)還原 10 Hz。泛型 struct 不能放 static 儲存屬性,所以放這裡。
@MainActor enum DecorTickerDebug { static var hz: Double? = nil }
#endif

struct DecorTicker<Content: View>: View {
    @MainActor static var interval: Duration {
        #if DEBUG
        if let hz = DecorTickerDebug.hz, hz > 0 { return .milliseconds(max(1, Int(1000 / hz))) }
        #endif
        return .milliseconds(100)
    }
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
