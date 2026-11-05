import SwiftUI
import AppKit
import MyParrotCore

/// #2438 遙控器(spec §2,Apple TV Siri Remote 工業設計):320pt 圓角板,由上而下＝狀態藥丸(含模式／設定)
/// → 麥克風藥丸(裝置＋增益 popover,D 定案)→ 會議名稱藥丸 → 圓盤＋鸚鵡 → 收音點列 → 圓鍵格
/// (標記 ⌘⇧M／模式 ⌘1／設定 ⌘,,M1 定案:只留錄音本身的動作)。警示／權限／更新橫幅由 RootView 放在
/// 遙控器下方(不變)。M4:狀態藥丸加 B2 面板開關圖示(`PaneToggleIcons`),⋮⋮ 可拖曳整個控制欄換邊(K1)。
/// 2026-10-20 Eric A1:淺色改銀色鋁合金(拉絲銀板身、銀圓鍵黑字),兩主題同一套間距(藥丸間 10、圓盤上 6、
/// 圓盤到收音列 12、收音列到鍵列 8、圓鍵 50pt、鍵名緊貼鍵下);深色材質不變。
struct RemoteView: View {
    @Bindable var controller: RecordingController
    @Bindable var uiState: AppUIState
    let windowMode: WindowModeManager

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }
    @State private var loc = Localizer.shared
    @State private var micPopover = false
    @State private var sleepy = false
    @FocusState private var titleFocused: Bool

    static let width: CGFloat = 320

    /// PERF-02:整支遙控器只有這一個 10 Hz 時鐘在動(錄音中／暫停中／轉稿中且非 reduceMotion);紅光、呼吸燈、鸚鵡、電平環都吃同一個 tick,
    /// 每秒最多 10 次 SwiftUI pass(每個 pass 都要付一次 NSHostingView 整窗 layout,所以不能一個葉子一個時鐘)。
    private var decorActive: Bool {
        !reduceMotion && (controller.state == .recording || controller.state == .paused || controller.isTranscribing)
    }

    var body: some View {
        DecorTicker(active: decorActive) { tick in
            VStack(spacing: 10) {
                statusPill(tick: tick)
                micPill
                titlePill
                HStack(alignment: .bottom, spacing: 4) {
                    DialView(controller: controller, tick: tick, animating: decorActive && controller.state == .recording)
                    MascotBuddy(pose: pose, tick: tick)
                }
                .padding(.top, 6)
                signalRow.frame(height: 16).padding(.top, -4)
                keyRow
            }
        }
        .padding(EdgeInsets(top: 14, leading: 16, bottom: 16, trailing: 16))
        .frame(width: Self.width)
        .background(slab)
        .onChange(of: controller.state) { old, new in
            // 新一場開錄 ⇒ 上一場的標記清掉(M5 之前標記只累計在 uiState,M5 起寫進筆記)。
            if new == .recording, old == .idle { uiState.markers.removeAll() }
        }
        // 待錄音閒置 5 分鐘 ⇒ 打瞌睡;狀態一變就醒(task 取消)。
        .task(id: controller.state) {
            sleepy = false
            guard controller.state == .idle else { return }
            try? await Task.sleep(for: .seconds(300))
            if !Task.isCancelled { sleepy = true }
        }
    }

    // MARK: 狀態

    private var pose: MascotPose {
        if !controller.deadTrackAlarms.isEmpty || controller.silenceStopSuggestedAt != nil { return .alarm }
        switch controller.state {
        case .recording: return .recording
        case .paused: return .paused
        case .finished: return controller.isTranscribing ? .transcribing : .finished
        case .idle: return controller.isTranscribing ? .transcribing : (sleepy ? .sleep : .idle)
        }
    }

    private var stateKey: String {
        switch controller.state {
        case .idle: return "待錄音"
        case .recording: return "錄音中"
        case .paused: return "已暫停"
        case .finished: return "結束後"
        }
    }

    private var stateColor: Color {
        switch controller.state {
        case .recording: return MP.recRed
        case .paused: return .orange
        default: return .secondary
        }
    }

    /// 狀態點:錄音中呼吸(opacity 0.5↔1,1 s 一去一回);PERF-02:吃遙控器根的 10 Hz tick 查相位,不用 repeatForever。
    private func breathDot(tick: Date) -> some View {
        let breathing = controller.state == .recording && !reduceMotion
        return Circle().fill(stateColor).frame(width: 9, height: 9)
            .opacity(breathing ? 0.5 + 0.5 * DecorClock.eased(DecorClock.triangle(at: tick, period: 2.0)) : 1)
    }

    // MARK: 板身

    /// 淺色＝拉絲銀(三段漸層＋直紋＋上緣全白高光＋下緣內陰影＋1pt 深邊),深色＝石墨(原樣)。
    private var slab: some View {
        let shape = RoundedRectangle(cornerRadius: 30, style: .continuous)
        return shape
            .fill(LinearGradient(stops: [.init(color: RemoteTheme.slabTop, location: 0),
                                         .init(color: RemoteTheme.slabMid, location: 0.55),
                                         .init(color: RemoteTheme.slabBottom, location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay { if !isDark { BrushedTexture().clipShape(shape) } }
            .overlay(shape.strokeBorder(LinearGradient(colors: [.white.opacity(isDark ? 0.45 : 0.95), .clear],
                                                       startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.35)), lineWidth: 1))
            .overlay(shape.strokeBorder(LinearGradient(colors: [.clear, .black.opacity(isDark ? 0 : 0.14)],
                                                       startPoint: UnitPoint(x: 0.5, y: 0.65), endPoint: .bottom), lineWidth: 1))
            .overlay(shape.strokeBorder(RemoteTheme.slabEdge, lineWidth: isDark ? 0.5 : 1))
            // 外陰影:模糊的深色副本(不是 .shadow modifier)
            .background(
                shape.fill(Color.black.opacity(isDark ? 0.22 : 0.24))
                    .blur(radius: isDark ? 12 : 14)
                    .offset(y: isDark ? 8 : 10)
            )
    }

    // MARK: 三顆藥丸

    private func statusPill(tick: Date) -> some View {
        HStack(spacing: 7) {
            // M4(K1):拖曳整個控制欄換邊;放到內容欄上以視窗中線判定(WorkspaceView 的放下處理)。
            Text("⋮⋮").font(.system(size: 11)).foregroundStyle(.tertiary)
                .frame(height: 22).contentShape(Rectangle())
                .pointerStyle(.grabIdle)
                .onDrag {
                    uiState.dragPayload = WorkspaceDrop.remotePayload
                    return NSItemProvider(object: WorkspaceDrop.remotePayload as NSString)
                }
                .help(L("拖曳控制欄換邊"))
                .accessibilityLabel(L("拖曳控制欄換邊"))
            breathDot(tick: tick)
            Text(L(stateKey)).font(.system(size: 12, weight: .semibold)).foregroundStyle(stateColor)
                .lineLimit(1).fixedSize()
            Spacer(minLength: 4)
            // B2:面板開關(標準模式才可按;窄版／迷你沒有直欄)。
            PaneToggleIcons(uiState: uiState, enabled: windowMode.mode == .standard)
            Divider().frame(height: 14)
            pillIcon(windowMode.mode.icon, help: "\(L("切換模式")) ⌘1", label: L("切換模式")) { windowMode.cycle() }
                .mpShortcut("1")
            pillIcon("gearshape", help: "\(L("設定")) ⌘,", label: L("設定")) { uiState.showSettings = true }
        }
        .modifier(PillStyle())
    }

    private func pillIcon(_ name: String, help: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: name).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                .frame(width: 22, height: 22).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(label)
    }

    /// 麥克風藥丸:裝置名＋右端「增益 1.0×」;點整顆開 popover(裝置清單＋0.5～2.0× 滑桿,與設定頁同一個 binding)。
    private var micPill: some View {
        Button { micPopover.toggle() } label: {
            HStack(spacing: 7) {
                Image(systemName: "mic.fill").font(.system(size: 11)).foregroundStyle(MP.blue)
                Text(controller.selectedInputDevice.map(micLabel) ?? L("麥克風"))
                    .font(.system(size: 12)).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                // AUD-38:切麥／重建進行中 ⇒ 裝置名後接「切換中…」、chevron 換小轉圈。
                if controller.isSwitchingMic {
                    Text(L("切換中…")).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                Text("\(L("增益")) \(gainLabel)").font(.system(size: 11)).foregroundStyle(.tertiary).monospacedDigit()
                    .fixedSize()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .modifier(PillStyle())
        .help(L("麥克風與輸入增益"))
        .accessibilityLabel(L("麥克風與輸入增益"))
        .popover(isPresented: $micPopover, arrowEdge: .bottom) { micPopoverContent }
    }

    private var gainLabel: String { String(format: "%.1f×", controller.inputGain) }

    private var micPopoverContent: some View {
        VStack(alignment: .leading, spacing: MP.spS) {
            ForEach(controller.availableInputDevices) { dev in
                Button { controller.switchMic(to: dev) } label: {
                    HStack(spacing: MP.spS) {
                        // AUD-38:選中那列在切換中把 checkmark 換成小轉圈。
                        if controller.isSwitchingMic && controller.selectedInputDevice?.id == dev.id {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "checkmark").font(.system(size: 10, weight: .bold))
                                .opacity(controller.selectedInputDevice?.id == dev.id ? 1 : 0)
                        }
                        Text(micLabel(dev)).font(MPFont.body)
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(controller.isSwitchingMic)   // AUD-38:切換中不接受再切
            }
            if controller.availableInputDevices.isEmpty {
                Text(L("沒有可用的麥克風")).font(MPFont.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack(spacing: MP.spS) {
                Text(L("輸入增益")).font(MPFont.caption)
                Slider(value: $controller.inputGain, in: 0.5...2.0, step: 0.1)
                Text(gainLabel).font(MPFont.caption).monospacedDigit().foregroundStyle(.secondary)
                    .frame(width: 34, alignment: .trailing)
            }
        }
        .padding(MP.spM)
        .frame(width: 280)
    }

    private var titlePill: some View {
        TextField(L("會議名稱"), text: $controller.currentTitle)
            .textFieldStyle(.plain)
            .font(.system(size: 12))
            .focused($titleFocused)
            .modifier(PillStyle())
            .overlay(Capsule().stroke(titleFocused ? MP.blue : Color.clear, lineWidth: 1))
    }

    // MARK: 收音點列與圓鍵格

    @ViewBuilder private var signalRow: some View {
        switch controller.state {
        case .recording:
            HStack(spacing: 14) {
                signal(L("對方"), ok: controller.sysHasSignal, color: MP.coral)
                signal(L("你"), ok: controller.micHasSignal, color: MP.blue)
            }
        case .paused:
            HStack(spacing: 4) {
                Circle().fill(Color.secondary).frame(width: 6, height: 6)
                Text(L("已暫停")).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        default:
            // 🔴 不能用 EmptyView:它連外層 .frame(height: 16) 都不佔位,待錄音／結束後整支板子會比錄音中矮 16pt
            // (Eric 10/20「間距不平衡」的一部分)。用透明色佔位,四態板高一致。
            Color.clear
        }
    }

    private func signal(_ who: String, ok: Bool, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 6, height: 6)
            Text("\(who) \(L(ok ? "收音中" : "等待訊號"))").font(.system(size: 11)).foregroundStyle(ok ? color : .orange)
        }
    }

    private var keyRow: some View {
        HStack(spacing: 26) {
            RemoteKey(icon: "flag.fill", label: L("標記"), badge: "⌘⇧M",
                      enabled: controller.state == .recording || controller.state == .paused,
                      count: uiState.markers.count) {
                uiState.addMarker(at: controller.elapsedExact)
            }
            RemoteKey(icon: windowMode.mode.icon, label: L("模式"), badge: "⌘1", enabled: true) { windowMode.cycle() }
            RemoteKey(icon: "gearshape", label: L("設定"), badge: "⌘,", enabled: true) { uiState.showSettings = true }
        }
    }
}

/// 拉絲鋁的直紋(mockup `repeating-linear-gradient(90deg, white .10 0-1px, black .025 1-3px)`):每 3pt 一條
/// 1pt 白線＋2pt 極淡黑帶,只在淺色畫;Canvas 一次畫完,不吃事件。
private struct BrushedTexture: View {
    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { ctx, size in
            var x: CGFloat = 0
            while x < size.width {
                ctx.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)), with: .color(.white.opacity(0.10)))
                ctx.fill(Path(CGRect(x: x + 1, y: 0, width: 2, height: size.height)), with: .color(.black.opacity(0.025)))
                x += 3
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 藥丸:28pt 高、全寬、淡底。
private struct PillStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, 12)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(Capsule().fill(RemoteTheme.pillFill))
    }
}

/// 圓鍵格的一顆:50pt 凸圓鍵(三段漸層＋上緣高光＋下緣內陰影＋1pt 深邊＋落影)＋10pt 鍵名＋⌘ 膠囊;
/// 不可用變暗 .38 不消失。淺色＝銀鍵黑字,深色＝石墨鍵亮字(Eric 10/20:「下方三個按鍵也不像按鍵」)。
private struct RemoteKey: View {
    let icon: String
    let label: String
    let badge: String
    let enabled: Bool
    var count: Int = 0
    let action: () -> Void
    @Environment(\.colorScheme) private var colorScheme
    private var isDark: Bool { colorScheme == .dark }
    static let size: CGFloat = 50

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                ZStack(alignment: .topTrailing) {
                    Circle().fill(LinearGradient(stops: [.init(color: RemoteTheme.keyTop, location: 0),
                                                         .init(color: RemoteTheme.keyMid, location: 0.55),
                                                         .init(color: RemoteTheme.keyBottom, location: 1)],
                                                 startPoint: .top, endPoint: .bottom))
                        .overlay(Circle().strokeBorder(LinearGradient(colors: [.white.opacity(isDark ? 0.3 : 1), .clear],
                                                                      startPoint: .top, endPoint: .center), lineWidth: 1))
                        .overlay(Circle().strokeBorder(LinearGradient(colors: [.clear, .black.opacity(isDark ? 0.5 : 0.10)],
                                                                      startPoint: .center, endPoint: .bottom), lineWidth: 3)
                                    .blur(radius: 1).clipShape(Circle()))
                        .overlay(Circle().strokeBorder(RemoteTheme.keyRim, lineWidth: 1))
                        .frame(width: Self.size, height: Self.size)
                        // 落影(mockup 0 2px 4px):模糊深色副本,不用 .shadow
                        .background(Circle().fill(Color.black.opacity(isDark ? 0.5 : 0.30)).blur(radius: 2).offset(y: 2))
                    Image(systemName: icon).font(.system(size: 19, weight: .medium)).foregroundStyle(RemoteTheme.keyFg)
                        .frame(width: Self.size, height: Self.size)
                    if count > 0 {
                        Text("\(count)").font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 4).frame(minWidth: 15, minHeight: 15)
                            .background(Capsule().fill(MP.blue))
                            .offset(x: 3, y: -3)
                    }
                }
                Text(label).font(.system(size: 10)).foregroundStyle(RemoteTheme.keyLabel).lineLimit(1)
                ShortcutBadge(symbol: badge, size: 9)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(RemoteKeyStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.38)
        .help("\(label) \(badge)")
        .accessibilityLabel(label)
    }
}

private struct RemoteKeyStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .brightness(configuration.isPressed ? -0.06 : 0)
    }
}
