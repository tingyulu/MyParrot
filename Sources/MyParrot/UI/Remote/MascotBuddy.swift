import SwiftUI
import AppKit
import MyParrotCore

/// 鸚鵡的姿勢(spec §11 I3 表)。
enum MascotPose: Equatable {
    case idle, sleep, recording, paused, finished, alarm, transcribing
}

/// #2438 I3／J1:鸚鵡站在圓盤右側,依狀態換姿勢。錄音中＝既有 `ParrotMascot`(拍翅唱歌、音符、光圈)原樣;
/// 新幀 `mascot/pant.png`(趴著喘氣)、`mascot/sleep.png`(打瞌睡)存在就用,缺檔用 idle 幀變形模擬;
/// reduceMotion 一律只換幀不動,氣泡照顯示。
struct MascotBuddy: View {
    let pose: MascotPose
    /// PERF-02:遙控器根的 10 Hz tick(錄音中拍翅／暫停喘氣／轉稿搖頭都吃它);`.distantPast`＝靜止。
    var tick: Date = .distantPast
    var size: CGFloat = 76
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var cheer = false
    @State private var cheerCount = 0

    static let extraFrames: [String: NSImage] = {
        guard let res = Bundle.main.resourceURL else { return [:] }
        var out: [String: NSImage] = [:]
        for name in ["pant", "sleep"] {
            if let img = NSImage(contentsOf: res.appendingPathComponent("mascot/\(name).png")) { out[name] = img }
        }
        return out
    }()

    var body: some View {
        ZStack(alignment: .topTrailing) {
            character.frame(width: size, height: size)
            if let say = bubbleText {
                Text(say).font(.system(size: 9, weight: .medium))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(.thinMaterial))
                    .overlay(Capsule().stroke(MP.line, lineWidth: 0.5))
                    .offset(x: 8, y: -8)
                    .transition(.opacity)
            }
        }
        .frame(width: size + 14, height: size + 10, alignment: .bottomLeading)
        .onAppear { if pose == .finished { startCheer() } }
        .onChange(of: pose) { _, p in if p == .finished { startCheer() } else { cheer = false } }
        .task(id: cheerCount) {
            guard cheer else { return }
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { withAnimation(.easeOut(duration: 0.3)) { cheer = false } }
        }
        .animation(.easeInOut(duration: 0.25), value: pose)
        // 整欄搬家(停靠換邊、視窗加寬)時位移不能被點頭的 phaseAnimator 帶上動畫(M4 真機抓到「鸚鵡慢慢飛過來」):
        // 幾何當一個整體,位移只套在這一層。
        .geometryGroup()
        .accessibilityHidden(true)
    }

    private func startCheer() {
        cheer = true
        cheerCount += 1
    }

    private var bubbleText: String? {
        switch pose {
        case .paused: return L("呼…呼…")
        case .finished: return cheer ? L("好耶") : nil
        case .alarm: return "?"
        case .sleep: return Self.extraFrames["sleep"] == nil ? "Zz" : nil
        default: return nil
        }
    }

    @ViewBuilder private var character: some View {
        switch pose {
        case .recording:
            ParrotMascot(size: size, isRecording: true, tick: tick)
        case .idle:
            ParrotMascot(size: size, isRecording: false).modifier(Nod(active: !reduceMotion))
        case .sleep:
            if let f = Self.extraFrames["sleep"] { frame(f) } else { ParrotMascot(size: size) }
        case .paused:
            if let f = Self.extraFrames["pant"] {
                frame(f).modifier(Breathe(active: !reduceMotion, tick: tick))
            } else {
                ParrotMascot(size: size).rotationEffect(.degrees(-28)).offset(x: -10, y: 2)
                    .modifier(Breathe(active: !reduceMotion, tick: tick))
            }
        case .finished:
            // 舉翅「好耶」:sing 幀單次伸懶腰(0 → −10° → 0,2.4 秒),之後回站姿。
            Group {
                if cheer, let f = ParrotMascot.pngFrames?.sing { frame(f) } else { ParrotMascot(size: size) }
            }
            .modifier(Stretch(trigger: cheerCount, active: !reduceMotion))
        case .alarm:
            ParrotMascot(size: size).rotationEffect(.degrees(15))
        case .transcribing:
            ParrotMascot(size: size).modifier(Sway(active: !reduceMotion, tick: tick))
        }
    }

    private func frame(_ img: NSImage) -> some View {
        Image(nsImage: img).resizable().interpolation(.high).scaledToFit().frame(width: size, height: size)
    }
}

// MARK: - 姿勢動畫(都是 phase／keyframe 動畫,不用 repeatForever 布林;reduceMotion 時整個不掛)

/// 待錄音:每 4 秒點頭一次。
private struct Nod: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active {
            content.phaseAnimator([false, true]) { view, phase in
                view.offset(y: phase ? 2 : 0)
            } animation: { phase in
                phase ? .easeInOut(duration: 0.2) : .easeInOut(duration: 0.2).delay(3.6)
            }
        } else {
            content
        }
    }
}

/// 已暫停:趴著喘氣,身體一鼓一縮(1.3 秒往復)。PERF-02:持續動畫改吃遙控器根的 10 Hz tick 查相位(暫停中也可能在打筆記)。
private struct Breathe: ViewModifier {
    let active: Bool
    let tick: Date
    func body(content: Content) -> some View {
        let p = active ? DecorClock.eased(DecorClock.triangle(at: tick, period: 2.6)) : 0
        content.scaleEffect(x: 1 + 0.05 * p, y: 1 - 0.04 * p, anchor: .bottom)
    }
}

/// 轉稿中:低頭聽、左右輕搖(2 秒往復)。PERF-02:同上(轉稿中使用者常在補筆記)。
private struct Sway: ViewModifier {
    let active: Bool
    let tick: Date
    func body(content: Content) -> some View {
        let p = active ? DecorClock.eased(DecorClock.triangle(at: tick, period: 2.0)) : 0.5
        content.rotationEffect(.degrees(-3 + 6 * p))
    }
}

/// 結束後:伸懶腰一次(0 → −10° → 0,2.4 秒),由 trigger 觸發。
private struct Stretch: ViewModifier {
    let trigger: Int
    let active: Bool
    func body(content: Content) -> some View {
        if active {
            content.keyframeAnimator(initialValue: 0.0, trigger: trigger) { view, angle in
                view.rotationEffect(.degrees(angle), anchor: .bottom)
            } keyframes: { _ in
                KeyframeTrack {
                    CubicKeyframe(-10, duration: 1.2)
                    CubicKeyframe(0, duration: 1.2)
                }
            }
        } else {
            content
        }
    }
}
