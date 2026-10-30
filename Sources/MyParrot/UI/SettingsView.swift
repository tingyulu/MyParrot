import SwiftUI
import AppKit
import MyParrotCore

/// UI-16:build-app.sh 簽章前把 MPBuildStamp(MMdd-HHmm git短hash[*])蓋進
/// Info.plist;`swift run` 無 stamp → "build dev"。
/// UI-22:自 RootView 的 adBar 移來——主畫面淨空,設定頁底部留個小字驗版本用。
// 2026-08-23 Eric:footer 要回來顯示 build no(UI-22 搬走後他還是要看),改 internal 供 RootView 共用。
let buildStamp =
    (Bundle.main.infoDictionary?["MPBuildStamp"] as? String).map { "build \($0)" } ?? "build dev"

struct SettingsView: View {
    /// UI-57:「模型」區段的捲動錨點(首次提示「打開設定」用)。
    static let modelSectionID = "model"
    /// MAS-31:首啟卡片按「下載建議模型」後打開設定捲到「逐字稿」區段(看得到進度)。
    static let transcriptSectionID = "transcript"
    @AppStorage(AppearanceMode.key) private var appearanceRaw = AppearanceMode.system.rawValue
    @Bindable var controller: RecordingController
    @Bindable var updates: UpdateChecker
    /// #2438 M6:「模型」區段要讀寫會議記錄 session(自動更新／間隔)與共用的選擇流程。
    @Bindable var uiState: AppUIState
    @Bindable private var loc = Localizer.shared
    @Environment(\.dismiss) private var dismiss
    @State private var escMonitor: Any?

    // Whisper 模型管理(TR-16);MAS-31:下載進度與錯誤搬到 WhisperDownloads(首啟卡片共用)
    private var downloads: WhisperDownloads { .shared }
    @State private var installedIDs: Set<String> = []
    @State private var activeModelID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                // UI-22: 手寫 16pt medium 換系統語意字型,跟下方 Form section header
                // 是同一套渲染邏輯。
                Text(L("設定")).font(.title3.weight(.semibold))
                Spacer()
                Button(L("完成")) { dismiss() }.keyboardShortcut(.defaultAction)

            }.padding(MP.spL)
            Divider()

            ScrollViewReader { proxy in
            Form {
                Section {
                    Picker(L("介面語言"), selection: $loc.language) {
                        ForEach(AppLanguage.allCases) { l in Text(l.label).tag(l) }
                    }
                    // UI-56(Eric 2026-10-20):外觀三選一,預設跟隨系統;改了立刻套到所有視窗,重開記得。
                    Picker(L("外觀"), selection: $appearanceRaw) {
                        ForEach(AppearanceMode.allCases) { m in Text(L(m.labelKey)).tag(m.rawValue) }
                    }
                    .onChange(of: appearanceRaw) { _, _ in AppearanceMode.applyStored() }
                } header: { Text(L("介面語言")) }

                Section {
                    LabeledContent(L("對方聲音(左軌)")) { Text(L("系統音訊 · 全部")).foregroundStyle(.secondary) }
                    Picker(L("你的麥克風(右軌)"), selection: Binding(
                        get: { controller.selectedInputDevice },
                        set: { controller.setPreferredInputDevice($0) })) {
                        ForEach(controller.availableInputDevices) { dev in
                            Text(micLabel(dev)).tag(Optional(dev))
                        }
                    }
                    LabeledContent(L("聆聽輸出")) { Text(L("跟隨系統 · 不影響錄音")).foregroundStyle(.secondary) }
                } header: { Text(L("輸入來源(分兩軌)")) }
                footer: { Text(L("提醒:麥克風別選藍牙耳機,否則整條藍牙掉 HFP,對方聲音也會變糊。")).font(MPFont.caption).foregroundStyle(.tertiary).lineSpacing(3) }

                Section {
                    VStack(alignment: .leading, spacing: MP.spS) {
                        HStack {
                            Text(L("麥克風靈敏度"))
                            Spacer()
                            Text(String(format: "%.1f×", controller.inputGain)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: $controller.inputGain, in: 0.5...2.0, step: 0.1)
                        HStack(spacing: MP.spS) {
                            Image(systemName: controller.meterActive ? "waveform.circle.fill" : "waveform.circle")
                                .foregroundStyle(controller.meterActive ? MP.blue : .secondary)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.10))
                                    RoundedRectangle(cornerRadius: 3).fill(MP.blue)
                                        // 2026-08-23:與主畫面/播放列同一套 dB 刻度(MeterScale)。
                                        .frame(width: max(2, geo.size.width * CGFloat(MeterScale.fraction(controller.meterLevel))))
                                }
                            }.frame(height: 8)
                            Text(controller.meterActive ? L(controller.state == .recording ? "錄音中收音" : "對著麥克風講話測試") : "")
                                .font(MPFont.caption).foregroundStyle(.tertiary)
                        }
                    }
                    Toggle(L("錄音時即時逐字稿"), isOn: $controller.liveTranscribeEnabled)
                    VStack(alignment: .leading, spacing: MP.spXS) {
                        Toggle(L("回音消除(喇叭外放·停止後處理)"), isOn: $controller.aecEnabled)
                        Text(L("用喇叭(非耳機)開會時,停止後自動消掉對方聲音被麥克風收進去的回音;純後製、不影響開會當下的聲音。"))
                            .font(MPFont.caption).foregroundStyle(.tertiary).lineSpacing(3)
                    }
                    LabeledContent(L("錄音格式")) { Text(L("錄製 PCM → 存檔 m4a(雙聲道)")).foregroundStyle(.secondary) }
                } header: { Text(L("錄音")) }

                Section {
                    Picker(L("辨識語言"), selection: $controller.language) {
                        ForEach(TranscriptionLanguage.allCases) { lang in Text(L(lang.label)).tag(lang) }
                    }
                    Text(L("預設跟隨系統語言;不支援的語言會用英文。支援:英/繁中/日/韓/簡中/西/德/法/葡(巴西)。"))
                        .font(MPFont.caption).foregroundStyle(.tertiary).lineSpacing(3)
                    // 2026-08-23 Eric:雲端(自帶 API)尚未實作,選單先藏(enum 保留給 Core/CLI 相容;舊設定值 .cloud 由 Core 回退原生)。
                    Picker(L("引擎"), selection: $controller.engine) {
                        ForEach(TranscriptionEngine.allCases.filter { $0 != .cloud }) { e in Text(L(e.label)).tag(e) }
                    }
                    // 2026-08-23 Eric:模型管理原本只在引擎=Whisper 時顯示,但「結束後自動高精度」也吃 Whisper 模型
                    // → 引擎=原生時使用者找不到下載入口。兩者任一開啟就顯示。
                    if controller.engine == .whisperKit || controller.transcribePolicy != .never { whisperModelRows }
                    VStack(alignment: .leading, spacing: MP.spXS) {
                        // #2483 E(TRX-05):三選一取代開關;預設「閒置時」。
                        Picker(L("結束後高精度重轉"), selection: $controller.transcribePolicy) {
                            Text(L("立刻")).tag(TranscribePolicy.immediately)
                            Text(L("閒置時(接電、沒在錄音)")).tag(TranscribePolicy.whenIdle)
                            Text(L("不重轉")).tag(TranscribePolicy.never)
                        }
                        Text(L("錄音停止後用 Whisper 高精度重轉一次;即時稿僅供會中參考。"))
                            .font(MPFont.caption).foregroundStyle(.tertiary).lineSpacing(3)
                    }
                } header: { Text(L("逐字稿")) }
                .id(Self.transcriptSectionID)

                // #2438 T3／MDL-03:單一「模型」區段(取代 #2417「逐字稿校正」區段;每個能力各選後端,預設全關)。
                ModelSettingsSection(controller: controller, uiState: uiState).id(Self.modelSectionID)

                CalendarReminderSettingsSection()   // #2407 會議前提醒錄音(預設關閉)

                Section {
                    LabeledContent(L("存檔目錄")) {
                        HStack(spacing: MP.spS) {
                            if controller.needsRecordingsFolder {   // MAS-07:商店版沒有可用的錄音夾 ⇒ 顯示原因而不是佔位路徑
                                Text(RecordingsFolderPicker.promptMessage(for: controller.recordingsFolderState))
                                    .font(MPFont.caption).foregroundStyle(.orange).lineLimit(2)
                            } else {
                                Text(controller.recordingsDir.path).font(MPFont.caption).foregroundStyle(.secondary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                            Button(L("選擇…")) { chooseDir() }
                                .disabled(controller.state == .recording || controller.state == .paused)   // C2 二審:錄音中不換夾
                        }
                    }
                    LabeledContent(L("檔名範本")) { Text(L("日期+時間+會議名稱")).foregroundStyle(.secondary) }
                } header: { Text(L("存檔")) }

                Section {
                    LabeledContent(L("麥克風")) { statusDot(controller.micPermission) }
                    LabeledContent(L("語音辨識")) { statusDot(controller.speechPermission) }
                    Button(L("重新請求權限")) { Task { await controller.requestPermissions() } }
                } header: { Text(L("權限")) }

                // UPD:目前版本+自動檢查開關+立即檢查+結果字串。
                // MAS-14(2.4.5 vii):商店版沒有更新檢查——開關與「立即檢查」不編,區段標題改「關於」(MAS-16 的法務區塊接在這裡)。
                Section {
                    LabeledContent(L("目前版本")) { Text(UpdateChecker.currentVersion ?? "dev").foregroundStyle(.secondary) }
                    AboutLegalRows()   // MAS-16:隱私政策／原始碼與授權／第三方授權(兩版都有)
                    #if !MYPARROT_MAS
                    Toggle(L("啟動時自動檢查更新"), isOn: $updates.enabled)
                    HStack {
                        Button(L("立即檢查")) { Task { await updates.checkNow() } }
                        updateStatusText
                    }
                    #endif
                } header: { Text(L(BuildFlavor.isMAS ? "關於" : "軟體更新")) }
            }
            .formStyle(.grouped)
            // UI-57:「打開設定」要直接捲到「模型」區段;設定頁剛開 Form 還在排版,延遲一拍再捲。
            .onChange(of: uiState.settingsScrollTo, initial: true) { _, target in
                guard let target else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    withAnimation { proxy.scrollTo(target, anchor: .top) }
                    uiState.settingsScrollTo = nil
                }
            }
            }
            // UI-22 item 9: build stamp 自 adBar 搬到這裡——設定頁底部小字,主畫面淨空。
            Text(buildStamp)
                .font(MPFont.caption.monospaced())
                .foregroundStyle(.tertiary)
                .padding(.horizontal, MP.spL).padding(.vertical, MP.spS)
        }
        .frame(width: 480, height: 640)
        // #2438 M6(MDL-03):模型後端的隱私確認框(掛根節點,不受 Form 延遲載入影響)。
        .modifier(ModelPrivacyPrompt(controller: controller, uiState: uiState))
        // UI-24: Esc 關閉(Return 已用 .keyboardShortcut(.defaultAction) 掛在「完成」)。
        // 2026-08-23 真機驗:.onExitCommand 與隱藏 .cancelAction 鈕在 sheet 內都接不到 Esc
        // (焦點留在主視窗輸入框)→ 改掛 NSEvent 本地監聽,sheet 存在期間 keyCode 53 即 dismiss。
        .onAppear {
            escMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53, event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty else { return event }
                // v0.3.0 二審:輸入法組字中(marked text)的 Esc 是「取消組字」,不該整張關掉;
                // 帶修飾鍵的 Esc 也放行給控制項。
                if let tv = event.window?.firstResponder as? NSTextView, tv.hasMarkedText() { return event }
                dismiss(); return nil
            }
        }
        .onDisappear { if let m = escMonitor { NSEvent.removeMonitor(m); escMonitor = nil } }
        .onAppear { controller.startMicMonitor() }
        .onDisappear { controller.stopMicMonitor() }
    }

    // MARK: - Whisper 模型管理(TR-16)

    private var whisperModelRows: some View {
        VStack(alignment: .leading, spacing: MP.spS) {
            Text(L("Whisper 模型")).font(MPFont.label)
            ForEach(WhisperModel.knownModels) { m in
                HStack(spacing: MP.spS) {
                    Text(L(m.display)).font(MPFont.caption)
                    Spacer()
                    if let p = downloads.progress[m.id] {
                        ProgressView(value: p).frame(width: 80)
                        Text("\(Int(p * 100))%").font(MPFont.caption).monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else if installedIDs.contains(m.id) {
                        if activeModelID == m.id {
                            Text(L("使用中")).font(MPFont.caption).foregroundStyle(.green)
                        } else {
                            Button(L("使用")) { setActiveModel(m) }.controlSize(.small)
                        }
                        Button(L("刪除")) {
                            WhisperModelStore.delete(m)
                            refreshModels()
                            controller.reloadTranscriptionEngine()
                        }.controlSize(.small)
                    } else if m.downloadURL != nil {
                        Button(L("下載")) { downloads.start(m, controller: controller) }.controlSize(.small)
                    }
                }
            }
            if let e = downloads.error {
                Text(e).font(MPFont.caption).foregroundStyle(.red)
            }
            // MAS-31:設定頁可重跑首啟導引(下次回主視窗就跳)
            Button(L("重新顯示首次導引")) { Onboarding.reset(); uiState.showOnboarding = true }.controlSize(.small)
        }
        .onAppear { refreshModels() }
        .onChange(of: downloads.completedCount) { _, _ in refreshModels() }
    }

    private func refreshModels() {
        let inst = WhisperModelStore.installed()
        installedIDs = Set(inst.map(\.model.id))
        let pref = UserDefaults.standard.string(forKey: "whisperModel")
        activeModelID = inst.first(where: { $0.model.id == pref })?.model.id
            ?? inst.first(where: { $0.model.id == "large-v3-turbo" })?.model.id
            ?? inst.first?.model.id
    }

    private func setActiveModel(_ m: WhisperModel) {
        UserDefaults.standard.set(m.id, forKey: "whisperModel")
        controller.reloadTranscriptionEngine()
        refreshModels()
    }

    private func chooseDir() { RecordingsFolderPicker.present(controller: controller) }   // MAS-06:與首啟提示共用

    private func statusDot(_ ok: Bool) -> some View {
        HStack(spacing: MP.spS) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(L(ok ? "已授權" : "未授權")).foregroundStyle(.secondary)
        }
    }

    // MARK: - UPD 軟體更新(商店版不編,MAS-14)

    #if !MYPARROT_MAS
    @ViewBuilder
    private var updateStatusText: some View {
        switch updates.status {
        case .idle:
            EmptyView()
        case .checking:
            HStack(spacing: MP.spXS) {
                ProgressView().controlSize(.small)
                Text(L("檢查中…")).font(MPFont.caption).foregroundStyle(.secondary)
            }
        case .upToDate:
            Text(L("已是最新版本")).font(MPFont.caption).foregroundStyle(.secondary)
        case .updateAvailable(let ver, let url):
            HStack(spacing: MP.spXS) {
                Text(L("有新版本") + " v\(ver)").font(MPFont.caption).foregroundStyle(.secondary)
                Button(L("前往下載")) { NSWorkspace.shared.open(url) }.controlSize(.small)
            }
        case .failed:
            Text(L("檢查失敗")).font(MPFont.caption).foregroundStyle(.red)
        }
    }
    #endif
}
