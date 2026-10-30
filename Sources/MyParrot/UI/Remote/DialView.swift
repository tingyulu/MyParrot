import SwiftUI
import MyParrotCore

/// #2438 圓盤(spec §2 C1＋P＋Q1＋R1):外盤 176pt 深色玻璃、40 段霓虹 LED 環(左半對方／右半你,
/// 刻度沿用 `MeterScale`)、中央 136pt 黑曜石玻璃。中央依狀態換臉:待錄音＝整顆「⏺ 開始錄音」;
/// 錄音中／已暫停＝上 56% 計時(Share Tech Mono)＋下 44% 順著圓弧切成兩個扇形鍵(暫停／繼續、結束);
/// 結束後＝整顆「＋ 新錄音」。沒有長按、沒有說明文字(Eric 10/19 17:44)。
/// 淺色(Eric 2026-10-20 A1 銀色鋁合金):外盤銀色內凹、中心緞面銀瓷、扇形鍵銀面黑字、計時深紅印刷字不發光,
/// 顏色在 `RemoteTheme` 依外觀切換,陰影／高光／發光的不透明度在這裡看 `colorScheme`。
/// 🚫 全檔不用 `.shadow`(memory swiftui-shadow-paint-crash);發光與落影用 Canvas 模糊圖層與模糊副本。
struct DialView: View {
    @Bindable var controller: RecordingController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }
    @State private var pulse = false
    @State private var peakOther = PeakHold()
    @State private var peakYou = PeakHold()

    static let size: CGFloat = 176
    static let centerSize: CGFloat = 136
    static let segments = 20

    /// 只有錄音中／暫停中電平環才亮(暫停時收音仍在跑,看得到輸入);結束後與待錄音全暗,不顯示停錄當下殘留的值。
    private var live: Bool { controller.state == .recording || controller.state == .paused }

    var body: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [RemoteTheme.dialOuterA, RemoteTheme.dialOuterB, RemoteTheme.dialOuterC],
                                         center: UnitPoint(x: 0.5, y: 0.36), startRadius: 10, endRadius: 100))
            // 盤面內凹:上緣內陰影(模糊的寬描邊,外側被 clipShape 裁掉)＋下緣 1pt 高光
            Circle().strokeBorder(LinearGradient(colors: [.black.opacity(isDark ? 0.5 : 0.22), .clear],
                                                 startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.5)), lineWidth: 8)
                .blur(radius: 3).clipShape(Circle())
            Circle().strokeBorder(LinearGradient(colors: [.clear, .white.opacity(isDark ? 0.08 : 0.7)],
                                                 startPoint: UnitPoint(x: 0.5, y: 0.5), endPoint: .bottom), lineWidth: 1)
            Circle().strokeBorder(RemoteTheme.dialRim, lineWidth: 1)
            LEDRing(other: live ? MeterScale.segments(controller.otherLevel, of: Self.segments) : 0,
                    you: live ? MeterScale.segments(controller.youLevel, of: Self.segments) : 0,
                    peakOther: live ? peakOther.held : 0, peakYou: live ? peakYou.held : 0, glow: !reduceMotion)
            centerDisc
        }
        .frame(width: Self.size, height: Self.size)
        // 盤外下緣 1pt 亮邊(mockup 0 1px 0 white):同心白圈往下挪 1pt,只露出底下那一弧
        .background(Circle().stroke(Color.white.opacity(isDark ? 0.35 : 0.8), lineWidth: 1).offset(y: 1))
        .onChange(of: controller.otherLevel) { _, v in peakOther.update(MeterScale.segments(v, of: Self.segments)) }
        .onChange(of: controller.youLevel) { _, v in peakYou.update(MeterScale.segments(v, of: Self.segments)) }
        .onAppear { updatePulse() }
        .onChange(of: controller.state) { _, _ in
            updatePulse()
            peakOther = PeakHold(); peakYou = PeakHold()   // 停錄／新錄音:峰值歸零(停錄後沒有新電平事件,否則會停在最後一格)
        }
        .onChange(of: reduceMotion) { _, _ in updatePulse() }
    }

    // MARK: 中央黑曜石

    private var centerDisc: some View {
        ZStack {
            Circle().fill(RadialGradient(colors: [RemoteTheme.obsidianA, RemoteTheme.obsidianB, RemoteTheme.obsidianC],
                                         center: UnitPoint(x: 0.5, y: 0.25), startRadius: 0, endRadius: 96))
            content
            // 下緣內陰影(inset 0 -10px 18px;淺色只有 .10):寬描邊由透明到黑,外側被 clipShape 裁掉
            Circle().strokeBorder(LinearGradient(colors: [.clear, .clear, .black.opacity(isDark ? 0.5 : 0.10)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 12)
                .allowsHitTesting(false)
            // 上緣 1pt 高光(淺色緞面銀近全白)
            Circle().strokeBorder(LinearGradient(colors: [.white.opacity(isDark ? 0.28 : 0.95), .clear],
                                                 startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.6)), lineWidth: 1)
                .allowsHitTesting(false)
        }
        .frame(width: Self.centerSize, height: Self.centerSize)
        .clipShape(Circle())
        // 中心鍵浮在盤上的落影(mockup 0 4px 10px):模糊深色副本,不用 .shadow
        .background(Circle().fill(Color.black.opacity(isDark ? 0.5 : 0.30)).blur(radius: 5).offset(y: 4))
        // 淺色 1pt 邊,深色靠落影就夠
        .overlay(Circle().stroke(Color.black.opacity(isDark ? 0 : 0.10), lineWidth: 1).allowsHitTesting(false))
        .overlay {
            if controller.state == .recording {
                // 錄音中外緣 2pt 紅光脈動(opacity 0.45↔0.75;reduceMotion 固定 0.6)
                Circle().stroke(RemoteTheme.pulseRed, lineWidth: 2)
                    .opacity(reduceMotion ? 0.6 : (pulse ? 0.75 : 0.45))
                    .allowsHitTesting(false)
            }
        }
    }

    @ViewBuilder private var content: some View {
        // #949 REC-35:CLI 在錄(別的進程持有租約)⇒ 中央鍵停用,改顯示「CLI 正在錄音」;停止／暫停走橫幅的鈕。
        if controller.externalRecording != nil, controller.state == .idle || controller.state == .finished {
            externalBusyKey
        } else {
            ownContent
        }
    }

    /// 別的進程在錄時的中央:不可按、沒有快捷鍵(⌘R 選單同步停用)。
    private var externalBusyKey: some View {
        VStack(spacing: 6) {
            Image(systemName: "terminal").font(.system(size: 26, weight: .regular)).foregroundStyle(.orange)
            Text(L("CLI 正在錄音")).font(.system(size: 11)).foregroundStyle(RemoteTheme.keyText)
        }
        .frame(width: Self.centerSize, height: Self.centerSize)
        .opacity(0.85)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(L("CLI 正在錄音"))
    }

    @ViewBuilder private var ownContent: some View {
        switch controller.state {
        case .idle:
            wholeKey(icon: "record.circle", tint: RemoteTheme.recordGlyph, label: L("開始錄音"), badge: "⌘R", key: "r") {
                RecordingConsent.confirmThen { controller.startRecording() }   // MAS-17:首次一次性提示
            }
        case .finished:
            wholeKey(icon: "plus", tint: RemoteTheme.plusGlyph, label: L("新錄音"), badge: "⌘N", key: "n") {
                controller.newRecording()
            }
        case .recording, .paused:
            VStack(spacing: 0) {
                display.frame(height: (Self.centerSize * 0.56).rounded())
                keys.frame(maxHeight: .infinity)
            }
        }
    }

    /// 待錄音／結束後:整顆中央圓就是一個鍵。
    private func wholeKey(icon: String, tint: Color, label: String, badge: String, key: Character,
                          action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 30, weight: .regular)).foregroundStyle(tint)
                HStack(spacing: 5) {
                    Text(label).font(.system(size: 11)).foregroundStyle(RemoteTheme.keyText)
                    ShortcutBadge(symbol: badge, onAccent: isDark)
                }
            }
            .frame(width: Self.centerSize, height: Self.centerSize)
            .contentShape(Circle())
        }
        .buttonStyle(WholeKeyStyle())
        .mpShortcut(key)
        .help("\(label) \(badge)")
        .accessibilityLabel(label)
    }

    /// 上 56%:計時。字級 21pt＋兩側各 10pt 留白,靠顯示區最寬的那條弦放(Eric 10/19 18:08:數字不可貼邊)。
    private var display: some View {
        let color = controller.state == .recording ? RemoteTheme.timerRecording : RemoteTheme.timerPaused
        let clock = Text(MP.clock(controller.elapsed))
            .font(MPFont.timer(21)).kerning(1).monospacedDigit().lineLimit(1)
        return ZStack(alignment: .bottom) {
            // 顯示區微內凹:由下往上的暗暈(淺色只留一點點)
            RadialGradient(colors: [.black.opacity(isDark ? 0.42 : 0.08), .clear], center: UnitPoint(x: 0.5, y: 0.7),
                           startRadius: 0, endRadius: 70)
            ZStack {
                clock.foregroundStyle(color).blur(radius: 6).opacity(isDark ? 0.55 : 0)   // 微光(text-shadow 的替身;淺色印刷字不發光)
                clock.foregroundStyle(color)
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 9)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityLabel(MP.clock(controller.elapsed))
    }

    /// 下 44%:兩個扇形鍵(父層 clipShape(Circle()) 把外緣裁成弧),中間 1pt 接縫,與顯示區之間同款接縫。
    private var keys: some View {
        HStack(spacing: 0) {
            if controller.state == .recording {
                SectorKey(side: .left, icon: "pause.fill", label: L("暫停"), badge: "⌘P", stop: false) { controller.pause() }
                    .mpShortcut("p")
            } else {
                SectorKey(side: .left, icon: "play.fill", label: L("繼續"), badge: "⌘P", stop: false) { controller.resume() }
                    .mpShortcut("p")
            }
            Rectangle().fill(RemoteTheme.seam).frame(width: 1)
            SectorKey(side: .right, icon: "stop.fill", label: L("結束"), badge: "⌘E", stop: true) { controller.stop() }
                .mpShortcut("e")
        }
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                Rectangle().fill(RemoteTheme.seam).frame(height: 1)
                Rectangle().fill(RemoteTheme.seamHighlight).frame(height: 1)
            }
            .allowsHitTesting(false)
        }
    }

    private func updatePulse() {
        guard controller.state == .recording, !reduceMotion else {
            var t = Transaction(); t.disablesAnimations = true
            withTransaction(t) { pulse = false }
            return
        }
        withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) { pulse = true }
    }
}

/// 峰值保持:比目前亮段高的峰值停 1.5 秒再掉下來(畫 0.45 不透明度的段)。
struct PeakHold: Equatable {
    var held = 0
    var since = Date.distantPast
    mutating func update(_ lit: Int, now: Date = Date()) {
        if lit >= held || now.timeIntervalSince(since) > 1.5 {
            held = lit
            since = now
        }
    }
}

/// C1 霓虹 LED 環:左右各 20 段弧(半徑 80、線寬 11、每段 9°、段間 2.8°),由盤底往上長;
/// 每半最上 3 段琥珀;亮段的光暈＝Canvas 圖層加 blur 再畫一次(reduceMotion 不畫)。
private struct LEDRing: View {
    let other: Int
    let you: Int
    let peakOther: Int
    let peakYou: Int
    let glow: Bool

    static let count = 20
    static let radius: CGFloat = 80
    static let width: CGFloat = 11

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            let c = CGPoint(x: size.width / 2, y: size.height / 2)
            let span = 180.0 / Double(Self.count)
            for i in 0..<Self.count {
                // 左半(對方):6 點鐘往 9 點鐘再往 12 點鐘;右半(你):6 點鐘往 3 點鐘再往 12 點鐘。
                let a0 = 90 + Double(i) * span + 1.4, a1 = 90 + Double(i + 1) * span - 1.4
                let b0 = 90 - Double(i + 1) * span + 1.4, b1 = 90 - Double(i) * span - 1.4
                stroke(ctx, c, a0, a1, RemoteTheme.ringBg, 1)
                stroke(ctx, c, b0, b1, RemoteTheme.ringBg, 1)
                let hot = i >= Self.count - 3
                if i < other { lit(ctx, c, a0, a1, hot ? RemoteTheme.ledHot : RemoteTheme.ledOther) }
                if i < you { lit(ctx, c, b0, b1, hot ? RemoteTheme.ledHot : RemoteTheme.ledYou) }
                if peakOther > other, i == peakOther - 1 { stroke(ctx, c, a0, a1, RemoteTheme.ledOther, 0.45) }
                if peakYou > you, i == peakYou - 1 { stroke(ctx, c, b0, b1, RemoteTheme.ledYou, 0.45) }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func arc(_ c: CGPoint, _ a0: Double, _ a1: Double) -> Path {
        var p = Path()
        p.addArc(center: c, radius: Self.radius, startAngle: .degrees(a0), endAngle: .degrees(a1), clockwise: false)
        return p
    }

    private func stroke(_ ctx: GraphicsContext, _ c: CGPoint, _ a0: Double, _ a1: Double, _ color: Color, _ opacity: Double) {
        ctx.stroke(arc(c, a0, a1), with: .color(color.opacity(opacity)),
                   style: StrokeStyle(lineWidth: Self.width, lineCap: .butt))
    }

    private func lit(_ ctx: GraphicsContext, _ c: CGPoint, _ a0: Double, _ a1: Double, _ color: Color) {
        if glow {
            ctx.drawLayer { layer in
                layer.addFilter(.blur(radius: 2.6))
                layer.stroke(arc(c, a0, a1), with: .color(color.opacity(0.9)),
                             style: StrokeStyle(lineWidth: Self.width + 2, lineCap: .butt))
            }
        }
        stroke(ctx, c, a0, a1, color, 1)
    }
}

/// 整顆中央鍵的按下回饋:壓暗。
private struct WholeKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .overlay(Circle().fill(Color.black.opacity(configuration.isPressed ? 0.28 : 0)).allowsHitTesting(false))
    }
}

/// 扇形鍵(Q1):凸面黑玻璃三層漸層(淺色＝銀面黑字),結束鍵帶珊瑚色相;按下＝內凹、內容下沉 1pt。
/// 內容靠接縫側與上方放(左鍵左內距 16、右鍵右內距 16、上內距 5),文字不貼圓邊。
private struct SectorKey: View {
    enum Side { case left, right }
    let side: Side
    let icon: String
    let label: String
    let badge: String
    let stop: Bool
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Button(action: action) {
            VStack(spacing: 1) {
                Image(systemName: icon).font(.system(size: 13, weight: .semibold))
                Text(label).font(.system(size: 10)).lineLimit(1).minimumScaleFactor(0.8)
                ShortcutBadge(symbol: badge, onAccent: colorScheme == .dark, size: 9).padding(.top, 1)
            }
            .foregroundStyle(stop ? RemoteTheme.stopText : RemoteTheme.keyText)
            .padding(.top, 5)
            .padding(.leading, side == .left ? 16 : 2)
            .padding(.trailing, side == .right ? 16 : 2)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .contentShape(Rectangle())
        }
        .buttonStyle(SectorKeyStyle(side: side, stop: stop))
        .help("\(label) \(badge)")
        .accessibilityLabel(label)
    }
}

private struct SectorKeyStyle: ButtonStyle {
    let side: SectorKey.Side
    let stop: Bool
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        return configuration.label
            .offset(y: pressed ? 1 : 0)
            .background { face(pressed: pressed) }
    }

    private var base: [Gradient.Stop] {
        if stop {
            return [.init(color: RemoteTheme.sectorStopA, location: 0),
                    .init(color: RemoteTheme.sectorStopB, location: 0.48),
                    .init(color: RemoteTheme.sectorStopC, location: 1)]
        }
        return [.init(color: RemoteTheme.sectorA, location: 0),
                .init(color: RemoteTheme.sectorB, location: 0.48),
                .init(color: RemoteTheme.sectorC, location: 1)]
    }

    /// 深色＝黑玻璃的重陰影,淺色＝銀面的淡陰影(數字照 remote-light-options.html 方案 1)。
    @ViewBuilder private func face(pressed: Bool) -> some View {
        ZStack {
            if pressed {
                LinearGradient(colors: [RemoteTheme.sectorPressedA, RemoteTheme.sectorPressedB],
                               startPoint: .top, endPoint: .bottom)
                // 內凹:上緣深影
                LinearGradient(colors: [.black.opacity(isDark ? 0.7 : 0.25), .clear], startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.25))
            } else {
                LinearGradient(stops: base, startPoint: .top, endPoint: .bottom)
                // 鍵頂橢圓高光
                RadialGradient(colors: [.white.opacity(isDark ? (stop ? 0.38 : 0.42) : 0.9), .white.opacity(isDark ? 0.14 : 0.3), .clear],
                               center: UnitPoint(x: side == .left ? 0.58 : 0.42, y: 0.04), startRadius: 0, endRadius: 54)
                    .scaleEffect(x: 1.8, y: 1)
                // 外側落暗(弧那一側)
                LinearGradient(colors: [.black.opacity(isDark ? 0.45 : 0.12), .clear],
                               startPoint: side == .left ? .leading : .trailing,
                               endPoint: side == .left ? UnitPoint(x: 0.4, y: 0.5) : UnitPoint(x: 0.6, y: 0.5))
                // 底部深影
                LinearGradient(colors: [.clear, .black.opacity(isDark ? 0.65 : 0.14)], startPoint: UnitPoint(x: 0.5, y: 0.45), endPoint: .bottom)
                // 上緣 1pt 高光
                VStack(spacing: 0) { Rectangle().fill(Color.white.opacity(isDark ? 0.32 : 0.95)).frame(height: 1); Spacer(minLength: 0) }
                // 接縫旁 1pt 亮線(右鍵左緣)
                if side == .right {
                    HStack(spacing: 0) { Rectangle().fill(RemoteTheme.seamHighlight).frame(width: 1); Spacer(minLength: 0) }
                }
            }
        }
    }
}
