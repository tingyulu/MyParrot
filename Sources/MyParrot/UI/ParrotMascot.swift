import SwiftUI
import MyParrotCore

/// MyParrot mascot — a chibi parrot wearing headphones. While recording it
/// "sings": beak opens/closes, music notes float up, the head bobs, and
/// sound-wave rings pulse. Idle = still.
/// UI-32(2026-08-24):尊重系統「減少動態效果」——開啟時不動、藏聲波/音符,錄音狀態改由靜止姿勢與其他 UI(紅點/狀態列)傳達。
/// PERF-02(2026-11-04,TEST_PLAN Z 節,Eric A1):四個 `repeatForever`(點頭／聲波／唱歌／音符)＋0.35 s 換幀的 TimelineView
/// 合併成**一個** 10 Hz `DecorTicker`,每個 tick 用 `DecorClock` 查相位直接設值、不包動畫——之前每一幀都讓 SwiftUI 跑整窗
/// layout(錄音中主執行緒被吃 40～70%、打筆記卡)。週期沿用舊動畫:點頭 1.0 s 往復、聲波 1.7 s 單向、唱歌 0.32 s 往復、音符 1.25 s 單向。
struct ParrotMascot: View {
    var size: CGFloat = 58
    var isRecording: Bool = false
    /// PERF-02:外面(遙控器根)已有 10 Hz 時鐘就把 tick 傳進來;nil ＝ 自己起一個(迷你模式)。
    var tick: Date? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var s: CGFloat { size }
    private var live: Bool { isRecording && !reduceMotion }

    /// UI-32:PNG 幀模式——app bundle 的 Resources/mascot/{idle,sing}.png
    /// (idle=收翅閉嘴/sing=張翅張嘴;錄音中輪替=拍翅+唱歌,UI-33b Eric 2026-08-24 06:32)。
    /// 沒有資產(swift run 開發模式、美術未到)回落既有向量畫法;載一次全程共用。
    /// internal:adBar 的迷你 logo 共用(UI-33)。
    static let pngFrames: (idle: NSImage, sing: NSImage)? = {
        guard let res = Bundle.main.resourceURL else { return nil }
        let dir = res.appendingPathComponent("mascot")
        guard let idle = NSImage(contentsOf: dir.appendingPathComponent("idle.png")),
              let sing = NSImage(contentsOf: dir.appendingPathComponent("sing.png")) else { return nil }
        return (idle, sing)
    }()

    /// UI-33b:footer 用的大頭小圖(與 app icon 同美術,16pt 才辨識得出;全身縮
    /// 16pt 糊成一團)。缺檔回落 idle 幀→🦜(RootView 端處理)。
    static let headIcon: NSImage? = {
        guard let res = Bundle.main.resourceURL else { return nil }
        return NSImage(contentsOf: res.appendingPathComponent("mascot/head.png"))
    }()

    var body: some View {
        if let tick {
            animated(at: tick)
        } else {
            DecorTicker(active: live) { date in animated(at: date) }
        }
    }

    /// 相位全在這裡算一次;不錄音／reduceMotion 時 date 是固定值、下面都走靜止分支。
    private func animated(at date: Date) -> some View {
        let bob = live ? DecorClock.eased(DecorClock.triangle(at: date, period: 2.0)) : 0        // 0→1→0,頭 −3°↔+3°
        let ringP = live ? DecorClock.easeOut(DecorClock.sawtooth(at: date, period: 1.7)) : 0   // 0→1 單向,擴散淡出
        let notesP = live ? DecorClock.easeIn(DecorClock.sawtooth(at: date, period: 1.25)) : 0  // 0→1 單向,上飄淡出
        let open = live && DecorClock.on(at: date, period: 0.35)                                   // PNG 幀開合
        let beak = live ? DecorClock.eased(DecorClock.triangle(at: date, period: 0.64)) : 0      // 向量嘴 0.32 s 往復
        return ZStack {
            if live { rings(ringP) }
            character(open: open, beak: beak)
                .rotationEffect(.degrees(live ? -3 + 6 * bob : -3))
                .offset(y: live ? -s * 0.03 * bob : 0)
            if live { musicNotes(notesP) }
        }
        .frame(width: s, height: s)
    }

    /// PNG 幀優先,無資產回落向量 parrot。
    /// 換幀不能靠 withAnimation 的布林(布林不可插值,repeatForever 對「離散的
    /// 圖片切換」無效——設成 true 後就停住,嘴一直張著不動;Eric 2026-08-24 06:06
    /// 真機抓到)。改定時驅動,錄音中每 0.35s 開合一次(PERF-02 起由同一個 DecorTicker 供相位)。
    @ViewBuilder private func character(open: Bool, beak: Double) -> some View {
        if let f = Self.pngFrames {
            frameImage(open ? f.sing : f.idle)
        } else {
            parrot(beak: beak)
        }
    }

    private func frameImage(_ img: NSImage) -> some View {
        Image(nsImage: img)
            .resizable()
            .interpolation(.high)
            .scaledToFit()
            .frame(width: s, height: s)
    }

    // Pulsing sound-wave rings while recording. p: 0(小而亮)→1(大而透明)。
    private func rings(_ p: Double) -> some View {
        ZStack {
            Circle().stroke(MP.blue, lineWidth: 2).frame(width: s * 0.7, height: s * 0.7)
                .scaleEffect(0.5 + 1.0 * p).opacity(0.5 * (1 - p))
            Circle().stroke(MP.coral, lineWidth: 2).frame(width: s * 0.7, height: s * 0.7)
                .scaleEffect(0.5 + 0.85 * p).opacity(0.4 * (1 - p))
        }
    }

    // ♪ ♫ rising from the beak and fading. p: 0(嘴邊、實)→1(上方、透明)。
    private func musicNotes(_ p: Double) -> some View {
        ZStack {
            Text("♪").font(.system(size: s * 0.22, weight: .bold)).foregroundStyle(MP.coral)
                .offset(x: s * 0.30, y: -s * (0.02 + 0.40 * p)).opacity(0.95 * (1 - p))
            Text("♫").font(.system(size: s * 0.18, weight: .bold)).foregroundStyle(MP.blue)
                .offset(x: s * 0.42, y: s * (0.02 - 0.54 * p)).opacity(0.85 * (1 - p))
        }
    }

    /// 向量鸚鵡;`beak` 0＝閉嘴、1＝張嘴(下嘴殼下落 s*0.065)。
    private func parrot(beak: Double) -> some View {
        ZStack {
            Ellipse().fill(MP.blue).frame(width: s * 0.58, height: s * 0.64).offset(y: s * 0.14)
            Ellipse().fill(Color(red: 0.71, green: 0.83, blue: 0.96))
                .frame(width: s * 0.32, height: s * 0.42).offset(y: s * 0.18)
            // crest
            Triangle().fill(Color(red: 0.937, green: 0.624, blue: 0.153))
                .frame(width: s * 0.12, height: s * 0.16).offset(x: -s * 0.05, y: -s * 0.40)
            Triangle().fill(Color(red: 0.729, green: 0.459, blue: 0.090))
                .frame(width: s * 0.12, height: s * 0.16).offset(x: s * 0.05, y: -s * 0.40)
            // head
            Circle().fill(MP.blue).frame(width: s * 0.56, height: s * 0.56).offset(y: -s * 0.16)
            // eyes
            eye(dx: -s * 0.12)
            eye(dx: s * 0.12)
            // beak: upper fixed, lower drops open while singing
            BeakTri().fill(MP.coral).frame(width: s * 0.16, height: s * 0.12).offset(y: -s * 0.05)
            BeakTri().fill(Color(red: 0.66, green: 0.27, blue: 0.13))
                .frame(width: s * 0.14, height: s * 0.10).rotationEffect(.degrees(180))
                .offset(y: -s * 0.005 + s * 0.065 * beak)
            // headphones
            Band().stroke(headphone, style: StrokeStyle(lineWidth: s * 0.05, lineCap: .round))
                .frame(width: s * 0.62, height: s * 0.2).offset(y: -s * 0.30)
            earCup(dx: -s * 0.30)
            earCup(dx: s * 0.30)
        }
    }

    private var headphone: Color { Color(red: 0.17, green: 0.17, blue: 0.16) }

    private func eye(dx: CGFloat) -> some View {
        ZStack {
            Circle().fill(.white).frame(width: s * 0.14, height: s * 0.14)
            Circle().fill(Color(red: 0.016, green: 0.173, blue: 0.325)).frame(width: s * 0.07, height: s * 0.07)
        }.offset(x: dx, y: -s * 0.18)
    }

    private func earCup(dx: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: s * 0.04).fill(headphone)
            .frame(width: s * 0.1, height: s * 0.16).offset(x: dx, y: -s * 0.14)
    }
}

private struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.midX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// Downward-pointing beak triangle.
private struct BeakTri: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

// Headphone band: an arch from bottom-left over the top to bottom-right.
private struct Band: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.maxY),
                       control: CGPoint(x: r.midX, y: r.minY - r.height * 0.4))
        return p
    }
}
