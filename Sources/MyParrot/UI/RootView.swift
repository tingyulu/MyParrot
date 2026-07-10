import SwiftUI
import AppKit
import MyParrotCore

/// UI-16:build-app.sh 簽章前把 MPBuildStamp(MMdd-HHmm git短hash[*])蓋進
/// Info.plist;`swift run` 無 stamp → "build dev"。
private let buildStamp =
    (Bundle.main.infoDictionary?["MPBuildStamp"] as? String).map { "build \($0)" } ?? "build dev"

struct RootView: View {
    @Bindable var controller: RecordingController
    @Binding var miniMode: Bool
    @State private var loc = Localizer.shared
    @State private var fullTranscript = false
    @State private var showSettings = false
    /// UI-20: 最近錄音列表可收折省空間。@State(非 @AppStorage)=只在本次
    /// 執行內記住,嚴守「不加沒要求的功能」;預設展開維持原行為。
    @State private var listExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            // UI-20: 兩欄(左欄290|逐字稿)→單直欄,視窗可拉窄到 400。
            // 順序=Eric 指定:控制區 → 即時逐字稿(彈性主體) → 可收折列表。
            VStack(alignment: .leading, spacing: 12) {
                controlSection
                transcriptSection
                recordingsSection
            }
            .padding(14)
            adBar
        }
        .overlay(alignment: .bottomTrailing) {
            ParrotMascot(size: 58, isRecording: controller.state == .recording)
                .offset(x: -8, y: 4).allowsHitTesting(false)
        }
        // UI-20: 最小尺寸統一由 MyParrotApp 的 frame 管(單一真相),這裡不再
        // 自帶——雙重約束取大者曾讓本層的值被 App 層舊 720 蓋掉。
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { miniMode = true } label: { Label(L("迷你模式"), systemImage: "pip") }
                Button { showSettings = true } label: { Image(systemName: "gearshape") }
            }
        }
        .sheet(isPresented: $showSettings) { SettingsView(controller: controller) }
        .task { await controller.requestPermissions() }
    }

    /// 錄音控制區(單欄最上):狀態卡+警告/權限橫幅+控制列,內容原封不動。
    private var controlSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            statusCard
            if let warn = controller.deviceChangeWarning {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(warn).font(.system(size: 11)).foregroundStyle(.orange)
                    Spacer()
                    Button { controller.deviceChangeWarning = nil } label: { Image(systemName: "xmark") }
                        .buttonStyle(.plain)
                }
                .padding(8).background(Color.orange.opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.orange.opacity(0.5), lineWidth: 1))
            }
            if !controller.micPermission || !controller.speechPermission {
                permissionNotice
            }
            ControlBar(controller: controller)
        }
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Circle().fill(controller.state == .recording ? MP.recRed : Color.secondary)
                    .frame(width: 9, height: 9)
                Text(L(stateLabel)).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(controller.state == .recording ? MP.recRed : .secondary)
                Text(MP.clock(controller.elapsed))
                    .font(.system(size: 20, weight: .medium, design: .monospaced))
            }
            // UI-17/20: 單欄後「頂部右側」=這張卡,macOS 26 玻璃工具列(迷你/設定鈕)
            // 浮在其上——首列留出右側淨空,義務自逐字稿標題列搬來。
            .padding(.trailing, 76)
            LevelBar(label: L("對方"), value: controller.otherLevel, color: MP.coral,
                     recording: controller.state == .recording, hasSignal: controller.sysHasSignal)
            LevelBar(label: L("你"), value: controller.youLevel, color: MP.blue,
                     recording: controller.state == .recording, hasSignal: controller.micHasSignal)
            micPicker
            TextField(L("會議名稱"), text: $controller.currentTitle)
                .textFieldStyle(.roundedBorder).font(.system(size: 12))
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(MP.line, lineWidth: 1))
    }

    // 主畫面快速麥克風選擇器:一眼看到當下收音裝置、隨時可切(待機 + 錄音中都行,
    // 錄音中走熱切換不斷檔)。這是「本次臨時」選擇 → switchMic 不寫 UserDefaults;
    // 重開以設定裡的為主。藍牙標 ⚠️、iPhone 標 (iPhone)。
    private var micPicker: some View {
        HStack(spacing: 6) {
            Image(systemName: "mic.fill").font(.system(size: 10)).foregroundStyle(MP.blue)
            Picker("", selection: Binding(
                get: { controller.selectedInputDevice },
                set: { if let d = $0 { controller.switchMic(to: d) } })) {
                ForEach(controller.availableInputDevices) { dev in
                    Text(micLabel(dev)).tag(Optional(dev))
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .font(.system(size: 11))
        }
    }

    private var permissionNotice: some View {
        HStack(spacing: 8) {
            Image(systemName: "lock.shield").foregroundStyle(MP.blue)
            Text(L("需要麥克風 / 語音辨識 / 系統音訊權限")).font(.system(size: 11)).foregroundStyle(.secondary)
            Spacer()
            Button(L("授權")) { Task { await controller.requestPermissions() } }.font(.system(size: 11))
        }
        .padding(8).background(MP.blue.opacity(0.12))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(MP.blue.opacity(0.4), lineWidth: 1))
    }

    /// UI-20: 最近錄音(單欄最下),標題列可收折省空間。
    private var recordingsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { withAnimation(.easeOut(duration: 0.15)) { listExpanded.toggle() } } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .rotationEffect(.degrees(listExpanded ? 90 : 0))
                        Text(L("最近錄音")).font(.system(size: 12, weight: .medium))
                    }.foregroundStyle(.secondary)
                }.buttonStyle(.plain)
                Spacer()
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([controller.recordingsDir])
                } label: {
                    Label(L("在 Finder 打開"), systemImage: "folder").font(.system(size: 11))
                }.buttonStyle(.borderless)
            }
            // UI-17: 列表自己捲動、封頂高度,視窗縮放自由(單欄後封頂 300→200 再省空間)。
            if listExpanded {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(controller.recordings.prefix(10)) { rec in
                            RecordingRow(rec: rec, controller: controller)
                        }
                        if controller.recordings.isEmpty {
                            Text(L("尚無錄音")).font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
    }

    private var transcriptSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(L("即時逐字稿")).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $fullTranscript) {
                    Text(L("最近 3 分鐘")).tag(false)
                    Text(L("完整")).tag(true)
                }.pickerStyle(.segmented).frame(width: 190).labelsHidden()
            }
            // UI-17/20: 玻璃工具列淨空已搬到 statusCard 首列(單欄後這裡不在頂部)。
            if let err = controller.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text(err).font(.system(size: 11)).foregroundStyle(.red).lineLimit(3)
                    Spacer()
                    Button { controller.lastError = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .padding(8).background(Color.red.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.4), lineWidth: 1))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if controller.isTranscribing {
                            Text(L("轉逐字稿中…")).font(.system(size: 12)).foregroundStyle(.secondary)
                        }
                        ForEach(visibleTranscript) { line in
                            TranscriptBubble(line: line)
                        }
                        if visibleTranscript.isEmpty && !controller.isTranscribing {
                            Text(L("開始錄音後,逐字稿會即時顯示在這裡;或對任一錄音檔按「轉逐字稿」。"))
                                .font(.system(size: 12)).foregroundStyle(.tertiary).padding(.top, 4)
                        }
                        Color.clear.frame(height: 1).id("transcript-bottom")   // UI-18 錨點
                    }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }
                .frame(minHeight: 200, maxHeight: .infinity)   // UI-20: 單欄的彈性主體
                // UI-17: 泡泡原本沒被裁切,捲動時會溢出圓角框(macOS 26 還會
                // 透進工具列區)。
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.03)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(MP.line, lineWidth: 1))
                // UI-18: 會議進行中逐字稿自動跟到最新(新行、或 volatile 行更新都跟)。
                .onChange(of: controller.liveTranscript.count) { _, _ in autoScroll(proxy) }
                .onChange(of: controller.liveTranscript.last?.text) { _, _ in autoScroll(proxy) }
            }
            Label(L("分軌讓「誰說的」自動標好(對方左／你右)"), systemImage: "info.circle")
                .font(.system(size: 11)).foregroundStyle(.tertiary)
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

    // UI-19: 廣告欄位現階段放大叔的 LinkedIn(Eric 2026-07-02 指定);
    // 之後要放正式廣告再改這裡。URL/文字不進 L()——各語言相同,免翻譯表負擔。
    private var adBar: some View {
        HStack(spacing: 8) {
            Text("🦜").font(.system(size: 11))
            Link("大叔的 LinkedIn — linkedin.com/in/uncleeric",
                 destination: URL(string: "https://www.linkedin.com/in/uncleeric")!)
                .font(.system(size: 11))
                .lineLimit(1).truncationMode(.tail)      // UI-20: 窄視窗時截斷連結文字,別擠爆底列
            Spacer()
            Text(buildStamp)                             // UI-16:一眼確認測的是哪一版(UI-20 自左欄底移入)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .layoutPriority(1)                       // UI-20: 窄視窗時 stamp 優先存活(測試認版本用)
        }
        .padding(.horizontal, 14).padding(.vertical, 8).padding(.trailing, 64)
        .overlay(Rectangle().fill(MP.line).frame(height: 1), alignment: .top)
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
    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(color).frame(width: 34, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.10))
                    RoundedRectangle(cornerRadius: 3).fill(color)
                        .frame(width: max(2, geo.size.width * CGFloat(min(1, value))))
                }
            }.frame(height: 7)
            if recording {
                HStack(spacing: 3) {
                    Image(systemName: hasSignal ? "checkmark.circle.fill" : "circle.dotted")
                        .font(.system(size: 10))
                        .foregroundStyle(hasSignal ? Color.green : .orange)
                    Text(L(hasSignal ? "收音中" : "等待訊號"))
                        .font(.system(size: 10)).foregroundStyle(hasSignal ? Color.green : .orange)
                }.frame(width: 56, alignment: .leading)
            }
        }
    }
}

struct TranscriptBubble: View {
    let line: TranscriptLine
    var body: some View {
        VStack(alignment: line.isYou ? .trailing : .leading, spacing: 3) {
            Text("\(L(line.isYou ? "你" : "對方")) · \(time)")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(line.isYou ? MP.blue : MP.coral)
            Text(line.text.isEmpty ? "…" : line.text)
                .font(.system(size: 13))
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background((line.isYou ? MP.blue : MP.coral).opacity(line.isFinal ? 0.16 : 0.08))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke((line.isYou ? MP.blue : MP.coral).opacity(0.3), lineWidth: 1))
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
        HStack(spacing: 8) {
            Button { controller.togglePlay(rec) } label: {
                Image(systemName: isPlaying ? "stop.fill" : "play.fill")
                    .font(.system(size: 13)).foregroundStyle(isPlaying ? MP.recRed : MP.blue)
            }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 1) {
                Text(rec.title).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Text(subtitle)
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button { controller.transcribe(rec) } label: { Image(systemName: "doc.text") }
                .buttonStyle(.plain).foregroundStyle(rec.hasTranscript ? Color.green : .primary)
                .help(L("轉逐字稿"))
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(isPlaying ? MP.blue.opacity(0.08) : Color.primary.opacity(0.03)))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(isPlaying ? MP.blue.opacity(0.5) : MP.line, lineWidth: 1))
    }
}

struct ControlBar: View {
    let controller: RecordingController
    var body: some View {
        HStack(spacing: 8) {
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
        Button(action: act) { Label(L(key), systemImage: icon).font(.system(size: 13, weight: .medium)) }
            .buttonStyle(.borderedProminent).tint(MP.recRed)
    }
    private func plainButton(_ key: String, _ icon: String, _ act: @escaping () -> Void) -> some View {
        Button(action: act) { Label(L(key), systemImage: icon).font(.system(size: 13)) }
            .buttonStyle(.bordered)
    }
}
