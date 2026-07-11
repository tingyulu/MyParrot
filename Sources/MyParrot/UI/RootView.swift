import SwiftUI
import AppKit
import MyParrotCore

/// UI-22 Phase B:三種警示 banner(裝置變更警告/權限提示/錯誤)共用同一份材質底
/// +左側 4pt 色條語言,取代原本三處各自複製的 background(色.opacity)+overlay stroke。
private struct MPBannerStyle: ViewModifier {
    let color: Color
    func body(content: Content) -> some View {
        content
            .padding(MP.spS)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            .overlay(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 4)
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

extension View {
    func mpBanner(color: Color) -> some View { modifier(MPBannerStyle(color: color)) }
}

struct RootView: View {
    @Bindable var controller: RecordingController
    @Binding var miniMode: Bool
    @State private var loc = Localizer.shared
    @State private var fullTranscript = false
    @State private var showSettings = false
    /// UI-20: 最近錄音列表可收折省空間。@State(非 @AppStorage)=只在本次
    /// 執行內記住,嚴守「不加沒要求的功能」;預設展開維持原行為。
    @State private var listExpanded = true
    /// UI-22:錄音中狀態紅點呼吸動畫的驅動值(見 statusCard)。
    @State private var recDotBreathe = false
    /// UI-22:會議名稱欄位改 .plain 樣式後,focus 時邊框變 MP.blue 需要自己追蹤。
    @FocusState private var titleFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // UI-20: 兩欄(左欄290|逐字稿)→單直欄,視窗可拉窄到 400。
            // 順序=Eric 指定:控制區 → 即時逐字稿(彈性主體) → 可收折列表。
            VStack(alignment: .leading, spacing: MP.spM) {
                controlSection
                // UI-21 v4: 逐字稿/最近錄音之間加可拖曳分隔(Eric 2026-07-11 指定)——
                // 比例由使用者拉,不再硬寫死列表高度。列表收折時鎖住下格高度,
                // 分隔線拖不動(等同以前的固定 header)。
                VSplitView {
                    transcriptSection
                        .frame(minHeight: 140, maxHeight: .infinity)
                    recordingsSection
                        .frame(minHeight: listExpanded ? 88 : 30,
                               maxHeight: listExpanded ? .infinity : 30)
                }
            }
            .padding(MP.spL)
            adBar
        }
        .overlay(alignment: .bottomTrailing) {
            ParrotMascot(size: 58, isRecording: controller.state == .recording)
                .offset(x: -8, y: 4).allowsHitTesting(false)
        }
        // UI-20: 最小尺寸統一由 MyParrotApp 的 frame 管(單一真相),這裡不再
        // 自帶——雙重約束取大者曾讓本層的值被 App 層舊 720 蓋掉。
        // UI-21: 移除 macOS 工具列——迷你/設定兩鈕改放 statusCard 首列右側(內容區,
        // 保證顯示、靠右、320pt 窄視窗不會被收進「»」)。原生標題列置中顯示視窗名。
        .sheet(isPresented: $showSettings) { SettingsView(controller: controller) }
        .task { await controller.requestPermissions() }
    }

    /// 錄音控制區(單欄最上):狀態卡+警告/權限橫幅+控制列,內容原封不動。
    private var controlSection: some View {
        VStack(alignment: .leading, spacing: MP.spM) {
            statusCard
            if let warn = controller.deviceChangeWarning {
                HStack(spacing: MP.spS) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(warn).font(MPFont.caption).foregroundStyle(.orange).lineSpacing(3)
                    Spacer()
                    Button { controller.deviceChangeWarning = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                }
                .mpBanner(color: .orange)
            }
            if !controller.micPermission || !controller.speechPermission {
                permissionNotice
            }
            ControlBar(controller: controller)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: MP.spS) {
            HStack(spacing: MP.spS) {
                Circle().fill(controller.state == .recording ? MP.recRed : Color.secondary)
                    .frame(width: 9, height: 9)
                    // UI-22: 錄音中呼吸(opacity 0.5↔1.0);非錄音靜止(固定不透明)。
                    .opacity(controller.state == .recording ? (recDotBreathe ? 1.0 : 0.5) : 1.0)
                    .onAppear { updateRecDotBreathing() }
                    .onChange(of: controller.state) { _, _ in updateRecDotBreathing() }
                Text(L(stateLabel)).font(MPFont.label)
                    .foregroundStyle(controller.state == .recording ? MP.recRed : .secondary)
                Text(MP.clock(controller.elapsed))
                    .font(MPFont.display)
                    .lineLimit(1).fixedSize()   // UI-22: 320pt 首列擠時計時器絕不折行
                Spacer(minLength: MP.spXS)
                // UI-21: 迷你/設定鈕(自 macOS 工具列搬來)——放這張卡首列右側,靠右、
                // 窄視窗不收合。狀態文字/計時在左,兩鈕在右,一列到底。
                Button { miniMode = true } label: {
                    // UI-22: 14pt 是圖示視覺尺寸(非文字級距),刻意不收進 MPFont。
                    Image(systemName: "pip").font(.system(size: 14))
                }.buttonStyle(.accessoryBar).help(L("迷你模式"))
                Button { showSettings = true } label: {
                    Image(systemName: "gearshape").font(.system(size: 14))
                }.buttonStyle(.accessoryBar).help(L("設定"))
            }
            LevelBar(label: L("對方"), value: controller.otherLevel, color: MP.coral,
                     recording: controller.state == .recording, hasSignal: controller.sysHasSignal)
            LevelBar(label: L("你"), value: controller.youLevel, color: MP.blue,
                     recording: controller.state == .recording, hasSignal: controller.micHasSignal)
            micPicker
            // UI-22: .roundedBorder(系統樣式)換成 .plain+自訂底,對齊卡片本身的
            // cornerRadius+stroke 語言;focus 時邊框亮 MP.blue。
            TextField(L("會議名稱"), text: $controller.currentTitle)
                .textFieldStyle(.plain)
                .font(MPFont.label)
                .focused($titleFieldFocused)
                .padding(.horizontal, MP.spS).padding(.vertical, MP.spXS)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.04)))
                .overlay(RoundedRectangle(cornerRadius: 8)
                    .stroke(titleFieldFocused ? MP.blue : Color.clear, lineWidth: 1))
        }
        .padding(MP.spM)
        // UI-22 Phase B: 三層材質最厚重的一層——.ultraThinMaterial+頂部 2pt accent bar
        // (待錄 MP.blue/錄音 MP.recRed),用 overlay(top) 疊上再一起 clipShape,讓
        // accent bar 左右上角跟卡片圓角切齊,不外露方角。去 stroke,改陰影立體感。
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
        .overlay(alignment: .top) {
            Rectangle()
                .fill(controller.state == .recording ? MP.recRed : MP.blue)
                .frame(height: 2)
        }
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.08), radius: 6, y: 2)
    }

    // UI-22: 錄音中啟動呼吸(repeatForever);非錄音時停掉並歸零(靜止實心)。
    private func updateRecDotBreathing() {
        guard controller.state == .recording else { recDotBreathe = false; return }
        withAnimation(.easeInOut(duration: 1).repeatForever(autoreverses: true)) {
            recDotBreathe = true
        }
    }

    // 主畫面快速麥克風選擇器:一眼看到當下收音裝置、隨時可切(待機 + 錄音中都行,
    // 錄音中走熱切換不斷檔)。這是「本次臨時」選擇 → switchMic 不寫 UserDefaults;
    // 重開以設定裡的為主。藍牙標 ⚠️、iPhone 標 (iPhone)。
    private var micPicker: some View {
        HStack(spacing: MP.spS) {
            Image(systemName: "mic.fill").font(MPFont.caption).foregroundStyle(MP.blue)
            Picker("", selection: Binding(
                get: { controller.selectedInputDevice },
                set: { if let d = $0 { controller.switchMic(to: d) } })) {
                ForEach(controller.availableInputDevices) { dev in
                    Text(micLabel(dev)).tag(Optional(dev))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(MPFont.caption)
        }
    }

    private var permissionNotice: some View {
        HStack(spacing: MP.spS) {
            Image(systemName: "lock.shield").foregroundStyle(MP.blue)
            Text(L("需要麥克風 / 語音辨識 / 系統音訊權限")).font(MPFont.caption).foregroundStyle(.secondary).lineSpacing(3)
            Spacer()
            Button(L("授權")) { Task { await controller.requestPermissions() } }.font(MPFont.caption)
        }
        .mpBanner(color: MP.blue)
    }

    /// UI-20: 最近錄音(單欄最下),標題列可收折省空間。
    private var recordingsSection: some View {
        VStack(alignment: .leading, spacing: MP.spS) {
            // UI-22 Phase B: VSplitView 分隔把手視覺提示——純裝飾,不攔截點擊,
            // 不影響 VSplitView 拖曳行為(拖曳仍由系統分隔線本身處理)。
            Capsule().fill(Color.primary.opacity(0.25))
                .frame(width: 36, height: 4)
                .frame(maxWidth: .infinity, alignment: .center)
                .allowsHitTesting(false)
            HStack {
                Button { withAnimation(.easeOut(duration: 0.15)) { listExpanded.toggle() } } label: {
                    HStack(spacing: MP.spXS) {
                        Image(systemName: "chevron.right")
                            .font(MPFont.caption.weight(.semibold))
                            .rotationEffect(.degrees(listExpanded ? 90 : 0))
                        Text(L("最近錄音")).font(MPFont.label)
                    }.foregroundStyle(.secondary)
                }.buttonStyle(.plain)
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([controller.recordingsDir])
                } label: {
                    Label(L("在 Finder 打開"), systemImage: "folder").font(MPFont.caption)
                }.buttonStyle(.borderless)
            }
            // UI-17: 列表自己捲動、封頂高度,視窗縮放自由(單欄後封頂 300→200 再省空間)。
            if listExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: MP.spS) {
                        ForEach(controller.recordings.prefix(10)) { rec in
                            RecordingRow(rec: rec, controller: controller)
                        }
                        if controller.recordings.isEmpty {
                            Text(L("尚無錄音")).font(MPFont.caption).foregroundStyle(.tertiary)
                        }
                    }
                }
                // UI-21 v4: 高度交給 VSplitView 分隔(使用者拖曳決定),不再硬封頂。
                .frame(maxHeight: .infinity)
            }
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: MP.spS) {
            HStack {
                Text(L("即時逐字稿")).font(MPFont.label).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $fullTranscript) {
                    // UI-22:「最近 3 分鐘」→「3 分鐘」,跟「完整」視覺配重更平衡。
                    Text(L("3 分鐘")).tag(false)
                    Text(L("完整")).tag(true)
                }.pickerStyle(.segmented).frame(width: 190).labelsHidden()
            }
            // UI-17/20: 玻璃工具列淨空已搬到 statusCard 首列(單欄後這裡不在頂部)。
            if let err = controller.lastError {
                HStack(spacing: MP.spS) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(err).font(MPFont.caption).foregroundStyle(.red).lineLimit(3).lineSpacing(3)
                    Spacer()
                    Button { controller.lastError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .mpBanner(color: .red)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: MP.spM) {
                        if controller.isTranscribing {
                            Text(L("轉逐字稿中…")).font(MPFont.label).foregroundStyle(.secondary)
                        }
                        ForEach(visibleTranscript) { line in
                            TranscriptBubble(line: line)
                        }
                        if visibleTranscript.isEmpty && !controller.isTranscribing {
                            Text(L("開始錄音後,逐字稿會即時顯示在這裡;或對任一錄音檔按「轉逐字稿」。"))
                                .font(MPFont.label).foregroundStyle(.tertiary).lineSpacing(3).padding(.top, MP.spXS)
                        }
                        Color.clear.frame(height: 1).id("transcript-bottom")   // UI-18 錨點
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(MP.spM)
                }
                .frame(minHeight: 80, maxHeight: .infinity)   // UI-21 v4: 下限交給外層 pane(140)管
                // UI-17: 泡泡原本沒被裁切,捲動時會溢出圓角框(macOS 26 還會
                // 透進工具列區)。
                .clipShape(RoundedRectangle(cornerRadius: 10))
                // UI-22 Phase B: 三層材質中間層——保留極淡 fill 當底色,去 stroke
                // (跟 statusCard 的材質厚重感拉開主從)。
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
                // UI-18: 會議進行中逐字稿自動跟到最新(新行、或 volatile 行更新都跟)。
                .onChange(of: controller.liveTranscript.count) { _, _ in autoScroll(proxy) }
                .onChange(of: controller.liveTranscript.last?.text) { _, _ in autoScroll(proxy) }
            }
            Label(L("分軌讓「誰說的」自動標好(對方左／你右)"), systemImage: "info.circle")
                .font(MPFont.caption).foregroundStyle(.tertiary)
        }
    }

    // UI-18: follow the newest line while recording. Not gated on "near bottom"
    // (macOS scroll-offset tracking isn't worth the complexity yet) — the 3-minute
    // window keeps the list short, and pausing auto-follow = switch to「完整」.
    private func autoScroll(_ proxy: ScrollViewProxy) {
        guard controller.state == .recording else { return }
        withAnimation(.easeOut(duration: 0.15)) {
            proxy.scrollTo("transcript-bottom", anchor: .bottom)
        }
    }

    // 「最近 3 分鐘」錨定最後一行時間(非牆鐘)→ 錄音中/結束後/舊檔轉稿語意
    // 一致,不再有 state gate(BUG-20:結束後 gate 讓切換形同虛設)。
    private var visibleTranscript: [TranscriptLine] {
        TranscriptWindow.visible(controller.liveTranscript, full: fullTranscript)
    }

    // UI-19: 廣告欄位現階段放大叔的 LinkedIn(Eric 2026-07-02 指定)。
    // UI-21: 上下兩行(Eric 2026-07-11 PDF 批註)——窄視窗時舊橫排把連結擠成多行直欄
    //       (macOS 26 的 Link 不繼承環境 lineLimit,559eea9 的截斷保護實測失效)。
    //       第 1 行 ViewThatFits:放得下顯全文,放不下顯短版;永不折行。
    // UI-22: build stamp 移去 SettingsView 底部(item 9),adBar 只剩 🦜+連結一行,
    //       VStack 兩行結構不再需要。
    private var adBar: some View {
        HStack(alignment: .firstTextBaseline, spacing: MP.spS) {
            Text("🦜").font(MPFont.caption)
            ViewThatFits(in: .horizontal) {
                adLink("大叔的 LinkedIn — linkedin.com/in/uncleeric")
                adLink("大叔的 LinkedIn")
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, MP.spL).padding(.vertical, MP.spS)
        .padding(.trailing, 58 + 8)  // = mascot 58 + inset 8
        .background(.bar)
        .overlay(Rectangle().fill(MP.line).frame(height: 1), alignment: .top)
    }

    // UI-21: Link 的 label 明確包 Text 並直接掛 lineLimit(環境傳遞在 macOS 26 對
    //       Link 失效);兩個寬度版本共用,URL 單一真相。
    private func adLink(_ label: String) -> some View {
        Link(destination: URL(string: "https://www.linkedin.com/in/uncleeric")!) {
            Text(label).font(MPFont.caption).lineLimit(1)
        }
    }

    private var stateLabel: String {
        switch controller.state {
        case .idle: return "待錄音"
        case .recording: return "錄音中"
        case .paused: return "已暫停"
        case .finished: return "結束後"
        }
    }
}

struct LevelBar: View {
    let label: String
    let value: Float
    let color: Color
    var recording: Bool = false
    var hasSignal: Bool = false
    // UI-22 Phase C: 20 段 Capsule 陣列取代單條連續 bar,更有「專業電平表」感——
    // 亮段數 = 段位映射(非連續寬度),錄音中亮段加發光,段數變化時彈簧動畫。
    private static let segmentCount = 20
    // UI-22 主 session 補修:低電平不歸零——有訊號(value>微小門檻)至少亮 1 段,
    // 對齊舊連續條 max(2px) 的「收音中永遠看得到」語意(實測 say 有收音卻 0 段亮)。
    private var litSegments: Int {
        let v = min(1, max(0, value))
        guard v > 0.005 else { return 0 }
        return max(1, Int((v * Float(Self.segmentCount)).rounded()))
    }
    var body: some View {
        HStack(spacing: MP.spS) {
            Text(label).font(MPFont.caption.weight(.medium)).foregroundStyle(color).frame(width: 34, alignment: .leading)
            HStack(spacing: 2) {
                ForEach(0..<Self.segmentCount, id: \.self) { i in
                    Capsule()
                        .fill(i < litSegments
                              ? AnyShapeStyle(LinearGradient(colors: [color, color.opacity(0.7)],
                                                              startPoint: .top, endPoint: .bottom))
                              : AnyShapeStyle(Color.primary.opacity(0.08)))
                        // UI-22 主 session 補修:發光只給亮段(原本套整條,灰暗段也泛色暈顯髒)。
                        .shadow(color: (recording && i < litSegments) ? color.opacity(0.5) : .clear, radius: 3)
                }
            }
            .frame(height: 7)
            .animation(.spring(duration: 0.25), value: litSegments)
            if recording {
                HStack(spacing: MP.spXS) {
                    Image(systemName: hasSignal ? "checkmark.circle.fill" : "circle.dotted")
                        .font(MPFont.caption)
                        .foregroundStyle(hasSignal ? Color.green : .orange)
                    Text(L(hasSignal ? "收音中" : "等待訊號"))
                        .font(MPFont.caption).foregroundStyle(hasSignal ? Color.green : .orange)
                }.frame(width: 56, alignment: .leading)
            }
        }
    }
}

struct TranscriptBubble: View {
    let line: TranscriptLine
    var body: some View {
        VStack(alignment: line.isYou ? .trailing : .leading, spacing: MP.spXS) {
            Text("\(L(line.isYou ? "你" : "對方")) · \(time)")
                .font(MPFont.caption.weight(.medium))
                .foregroundStyle(line.isYou ? MP.blue : MP.coral)
            Text(line.text.isEmpty ? "…" : line.text)
                .font(MPFont.body)
                .padding(.horizontal, MP.spM).padding(.vertical, MP.spS)
                .background((line.isYou ? MP.blue : MP.coral).opacity(line.isFinal ? 0.16 : 0.08))
                // UI-22 Phase C: volatile(非 final)虛線描邊區分「還在辨識中」,
                // final 維持實線——比原本只靠 opacity 微調更一眼可辨。
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(
                    (line.isYou ? MP.blue : MP.coral).opacity(0.3),
                    style: StrokeStyle(lineWidth: 1, dash: line.isFinal ? [] : [4, 3])))
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
        .frame(maxWidth: .infinity, alignment: line.isYou ? .trailing : .leading)
    }
    private var time: String {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f.string(from: line.time)
    }
}

struct RecordingRow: View {
    let rec: Recording
    let controller: RecordingController
    // UI-22 Phase B: 三層材質最輕的一層——無底色,hover 才浮出淡底;不加逐項描邊,
    // 行與行之間靠卡片間距(MP.spS)分隔,不加 hairline。
    @State private var isHovering = false
    private var isPlaying: Bool { controller.playingURL == rec.url }
    // 副標：處理中… / [時長 · ]雙聲道[ · 已轉稿]
    private var subtitle: String {
        if rec.isConverting { return L("處理中…") }
        let kind = L(rec.hasTranscript ? "雙聲道 · 已轉稿" : "雙聲道")
        guard rec.duration > 0 else { return kind }
        return "\(Self.durationLabel(rec.duration)) · \(kind)"
    }
    private static func durationLabel(_ t: TimeInterval) -> String {
        let s = Int(t.rounded())
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
    var body: some View {
        HStack(spacing: MP.spS) {
            Button { controller.togglePlay(rec) } label: {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(MPFont.body).foregroundStyle(isPlaying ? MP.recRed : MP.blue)
            }.buttonStyle(.accessoryBar)
            // UI-22: 標題 13pt semibold / 副標 caption——主從不再只靠顏色分辨。
            VStack(alignment: .leading, spacing: MP.spXS) {
                Text(rec.title).font(MPFont.body.weight(.semibold)).lineLimit(1)
                Text(subtitle)
                    .font(MPFont.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { controller.transcribe(rec) } label: { Image(systemName: "doc.text") }
                .buttonStyle(.accessoryBar).foregroundStyle(rec.hasTranscript ? Color.green : .primary)
                .help(L("轉逐字稿"))
        }
        .padding(MP.spS)
        .background(RoundedRectangle(cornerRadius: 8).fill(
            isPlaying ? MP.blue.opacity(0.08) : (isHovering ? Color.primary.opacity(0.06) : Color.clear)))
        .onHover { isHovering = $0 }
    }
}

struct ControlBar: View {
    let controller: RecordingController
    var body: some View {
        HStack(spacing: MP.spS) {
            switch controller.state {
            case .idle:
                redButton("開始錄音", "record.circle") { controller.startRecording() }
            case .recording:
                plainButton("暫停", "pause") { controller.pause() }
                redButton("結束", "stop") { controller.stop() }
            case .paused:
                plainButton("繼續", "play") { controller.resume() }
                redButton("結束", "stop") { controller.stop() }
                plainButton("新錄音", "plus") { controller.newRecording() }
            case .finished:
                if let last = controller.recordings.first {
                    plainButton("轉逐字稿", "doc.text") { controller.transcribe(last) }
                }
                plainButton("新錄音", "plus") { controller.newRecording() }
            }
        }
    }

    private func redButton(_ key: String, _ icon: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) { Label(L(key), systemImage: icon).font(MPFont.body.weight(.medium)) }
            .buttonStyle(.borderedProminent).tint(MP.recRed)
    }
    private func plainButton(_ key: String, _ icon: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) { Label(L(key), systemImage: icon).font(MPFont.body) }
            .buttonStyle(.bordered)
    }
}
