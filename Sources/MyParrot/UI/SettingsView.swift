import SwiftUI
import AppKit
import MyParrotCore

struct SettingsView: View {
    @Bindable var controller: RecordingController
    @Bindable private var loc = Localizer.shared
    @Environment(\.dismiss) private var dismiss

    // Whisper 模型管理(TR-16)
    @State private var modelProgress: [String: Double] = [:]
    @State private var modelError: String?
    @State private var installedIDs: Set<String> = []
    @State private var activeModelID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(L("設定")).font(.system(size: 16, weight: .medium))
                Spacer()
                Button(L("完成")) { dismiss() }.keyboardShortcut(.defaultAction)
            }.padding(16)
            Divider()

            Form {
                Section {
                    Picker(L("介面語言"), selection: $loc.language) {
                        ForEach(AppLanguage.allCases) { l in Text(l.label).tag(l) }
                    }
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
                footer: { Text(L("提醒:麥克風別選藍牙耳機,否則整條藍牙掉 HFP,對方聲音也會變糊。")).font(.system(size: 11)).foregroundStyle(.tertiary) }

                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(L("麥克風靈敏度"))
                            Spacer()
                            Text(String(format: "%.1f×", controller.inputGain)).foregroundStyle(.secondary).monospacedDigit()
                        }
                        Slider(value: $controller.inputGain, in: 0.5...2.0, step: 0.1)
                        HStack(spacing: 8) {
                            Image(systemName: controller.meterActive ? "waveform.circle.fill" : "waveform.circle")
                                .foregroundStyle(controller.meterActive ? MP.blue : .secondary)
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.10))
                                    RoundedRectangle(cornerRadius: 3).fill(MP.blue)
                                        .frame(width: max(2, geo.size.width * CGFloat(min(1, controller.meterLevel))))
                                }
                            }.frame(height: 8)
                            Text(controller.meterActive ? L(controller.state == .recording ? "錄音中收音" : "對著麥克風講話測試") : "")
                                .font(.system(size: 11)).foregroundStyle(.tertiary)
                        }
                    }
                    Toggle(L("錄音時即時逐字稿"), isOn: $controller.liveTranscribeEnabled)
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(L("回音消除(喇叭外放·停止後處理)"), isOn: $controller.aecEnabled)
                        Text(L("用喇叭(非耳機)開會時,停止後自動消掉對方聲音被麥克風收進去的回音;純後製、不影響開會當下的聲音。"))
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                    LabeledContent(L("錄音格式")) { Text(L("錄製 PCM → 存檔 m4a(雙聲道)")).foregroundStyle(.secondary) }
                } header: { Text(L("錄音")) }

                Section {
                    Picker(L("辨識語言"), selection: $controller.language) {
                        ForEach(TranscriptionLanguage.allCases) { lang in Text(lang.label).tag(lang) }
                    }
                    Text(L("預設跟隨系統語言;不支援的語言會用英文。支援:英/繁中/日/韓/簡中。"))
                        .font(.system(size: 11)).foregroundStyle(.tertiary)
                    Picker(L("引擎"), selection: $controller.engine) {
                        ForEach(TranscriptionEngine.allCases) { e in Text(e.label).tag(e) }
                    }
                    if controller.engine == .whisperKit { whisperModelRows }
                    VStack(alignment: .leading, spacing: 2) {
                        Toggle(L("結束後自動產出高精度逐字稿"), isOn: $controller.autoTranscribeAfterStop)
                        Text(L("錄音停止後用 Whisper 高精度重轉一次;即時稿僅供會中參考。"))
                            .font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                } header: { Text(L("逐字稿")) }

                Section {
                    LabeledContent(L("存檔目錄")) {
                        HStack(spacing: 8) {
                            Text(controller.recordingsDir.path).font(.system(size: 11)).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Button(L("選擇…")) { chooseDir() }
                        }
                    }
                    LabeledContent(L("檔名範本")) { Text(L("日期+時間+會議名稱")).foregroundStyle(.secondary) }
                } header: { Text(L("存檔")) }

                Section {
                    LabeledContent(L("麥克風")) { statusDot(controller.micPermission) }
                    LabeledContent(L("語音辨識")) { statusDot(controller.speechPermission) }
                    Button(L("重新請求權限")) { Task { await controller.requestPermissions() } }
                } header: { Text(L("權限")) }
            }
            .formStyle(.grouped)
        }
        .frame(width: 480, height: 640)
        .onAppear { controller.startMicMonitor() }
        .onDisappear { controller.stopMicMonitor() }
    }

    // MARK: - Whisper 模型管理(TR-16)

    private var whisperModelRows: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Whisper 模型")).font(.system(size: 12, weight: .medium))
            ForEach(WhisperModel.knownModels) { m in
                HStack(spacing: 8) {
                    Text(m.display).font(.system(size: 11))
                    Spacer()
                    if let p = modelProgress[m.id] {
                        ProgressView(value: p).frame(width: 80)
                        Text("\(Int(p * 100))%").font(.system(size: 11)).monospacedDigit()
                            .foregroundStyle(.secondary)
                    } else if installedIDs.contains(m.id) {
                        if activeModelID == m.id {
                            Text(L("使用中")).font(.system(size: 11)).foregroundStyle(.green)
                        } else {
                            Button(L("使用")) { setActiveModel(m) }.controlSize(.small)
                        }
                        Button(L("刪除")) {
                            WhisperModelStore.delete(m)
                            refreshModels()
                            controller.reloadTranscriptionEngine()
                        }.controlSize(.small)
                    } else if m.downloadURL != nil {
                        Button(L("下載")) { downloadModel(m) }.controlSize(.small)
                    }
                }
            }
            if let e = modelError {
                Text(e).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .onAppear { refreshModels() }
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

    private func downloadModel(_ m: WhisperModel) {
        modelProgress[m.id] = 0
        modelError = nil
        Task {
            do {
                _ = try await WhisperModelStore.download(m) { p in
                    Task { @MainActor in modelProgress[m.id] = p }
                }
                modelProgress[m.id] = nil
                if UserDefaults.standard.string(forKey: "whisperModel") == nil {
                    UserDefaults.standard.set(m.id, forKey: "whisperModel")
                }
                controller.reloadTranscriptionEngine()
                refreshModels()
            } catch {
                modelProgress[m.id] = nil
                modelError = "\(L("下載失敗")):\(error)"
            }
        }
    }

    private func chooseDir() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L("選擇…")
        panel.directoryURL = controller.recordingsDir
        if panel.runModal() == .OK, let url = panel.url { controller.setRecordingsDir(url) }
    }

    private func statusDot(_ ok: Bool) -> some View {
        HStack(spacing: 6) {
            Circle().fill(ok ? Color.green : Color.orange).frame(width: 8, height: 8)
            Text(L(ok ? "已授權" : "未授權")).foregroundStyle(.secondary)
        }
    }
}
