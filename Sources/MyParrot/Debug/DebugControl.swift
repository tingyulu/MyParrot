#if DEBUG
import AppKit
import SwiftUI
import os
import MyParrotCore

/// #2412 只在 DEBUG 建置存在的控制通道(Shiyin 研究 B):讓驗證腳本不靠 AX 按鈕、
/// 合成滑鼠、視窗 id 就能操作 GUI、讀狀態、截圖(含螢幕鎖定時)。
/// 傳輸:`DistributedNotificationCenter`(只在同一台、同一使用者),指令＝參數以
/// `\u{1F}` 分隔;結果寫到指令給的檔(只准暫存區/家目錄)。用 `scripts/dev/myparrotctl` 送。
/// 🔒 整檔 `#if DEBUG`;install 也只在 DEBUG 呼叫。每個指令只呼叫既有公開方法,
/// 不新增 DEBUG 才有的捷徑邏輯(否則驗的是另一條路)。
@MainActor
enum DebugControl {
    /// 通知名稱只在這個 DEBUG 檔與 scripts/dev/myparrotctl.swift 出現,release 二進位 grep 不到。
    /// #949(2026-10-20 實踩):DistributedNotificationCenter 是**廣播**——機上同時有兩個 DEBUG 建置(例如 Eric 平常用的
    /// ~/Applications 版也是 debug 組態)時,`myparrotctl quit` 會把兩個都關掉、`state` 會被兩個搶著回。
    /// 驗證用實例帶環境變數 `MYPARROT_DEBUG_CHANNEL=<名字>` ⇒ 通知名加後綴,只收自己頻道的指令(myparrotctl 讀同一個變數)。
    static var notificationName: String {
        let base = "tw.uncle.MyParrot.debug"
        guard let raw = getenv("MYPARROT_DEBUG_CHANNEL") else { return base }
        let ch = String(cString: raw)
        return ch.isEmpty ? base : "\(base).\(ch)"
    }
    private static var controller: RecordingController?
    private static var updates: UpdateChecker?
    private static var uiState: AppUIState?
    private static var windowMode: WindowModeManager?
    private static var installed = false

    static func install(controller: RecordingController, updates: UpdateChecker,
                        uiState: AppUIState, windowMode: WindowModeManager) {
        guard !installed else { return }
        installed = true
        self.controller = controller; self.updates = updates; self.uiState = uiState; self.windowMode = windowMode
        DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(notificationName), object: nil, queue: .main) { note in
            guard let raw = note.object as? String else { return }
            MainActor.assumeIsolated { handle(DebugCommand.parse(raw)) }
        }
    }

    // MARK: - 指令

    /// 第一個參數＝指令;最後一個參數＝結果檔路徑(每個指令都要給,壞指令也會寫錯誤進去)。
    private static func handle(_ args: [String]) {
        guard let cmd = args.first else { return }
        // snapshot／window-shot 的「結果檔」是圖本身＝第 2 個參數(後面可接選項);其他指令是最後一個參數。
        let imageFirst = cmd == "snapshot" || cmd == "window-shot"
        let outCandidate: String? = imageFirst ? (args.count >= 2 ? args[1] : nil) : args.last
        guard args.count >= 2, let out = outCandidate, DebugCommand.isAllowedResultPath(out) else {
            // 沒有合法結果檔就沒地方回報;只在 stderr 留一行,不做任何動作。
            FileHandle.standardError.write(Data("[debug] rejected: \(cmd) (result path missing or not allowed)\n".utf8))
            return
        }
        let params = imageFirst ? Array(args.dropFirst(2)) : Array(args.dropFirst().dropLast())
        guard let c = controller, let u = updates, let ui = uiState, let wm = windowMode else {
            write(["ok": false, "error": "not installed"], to: out); return
        }
        func recording(_ spec: String) -> Recording? {
            if spec == "latest" { return c.recordings.first }
            guard let n = Int(spec), n >= 0, n < c.recordings.count else { return nil }
            return c.recordings[n]
        }
        switch cmd {
        case "state":
            write(state(c, ui, wm), to: out)
        case "record":
            c.startRecording(); write(["ok": true, "state": "\(c.state)"], to: out)
        case "pause":
            c.pause(); write(["ok": true, "state": "\(c.state)"], to: out)
        case "resume":
            c.resume(); write(["ok": true, "state": "\(c.state)"], to: out)
        case "stop":
            c.stop(); write(["ok": true, "state": "\(c.state)"], to: out)
        case "new":
            c.newRecording(); write(["ok": true, "state": "\(c.state)"], to: out)
        case "title":
            c.currentTitle = params.first ?? ""; write(["ok": true, "title": c.currentTitle], to: out)
        case "dismiss-warning":
            c.warning = nil; write(["ok": true], to: out)
        case "mic":
            // AUD-38(#2529):mic list | select <index|名稱片段>(先比 index,再用名稱片段不分大小寫比對)。
            let devices = c.availableInputDevices
            switch params.first ?? "" {
            case "list":
                write(["ok": true, "devices": devices.enumerated().map { i, d -> [String: Any] in
                    ["index": i, "name": d.name, "bluetooth": d.isBluetooth, "selected": c.selectedInputDevice?.uid == d.uid] }],
                      to: out)
            case "select":
                guard params.count >= 2 else { write(["ok": false, "error": "usage: mic select <index|name>"], to: out); return }
                let spec = params[1]
                let hit: AudioInputDevice? = Int(spec).flatMap { n in devices.indices.contains(n) ? devices[n] : nil }
                    ?? devices.first { $0.name.localizedCaseInsensitiveContains(spec) }
                guard let dev = hit else {
                    write(["ok": false, "error": "no such mic: \(spec)", "devices": devices.map(\.name)], to: out); return
                }
                c.switchMic(to: dev)
                write(["ok": true, "name": dev.name, "isSwitchingMic": c.isSwitchingMic], to: out)
            default:
                write(["ok": false, "error": "usage: mic list | mic select <index|name>"], to: out)
            }
        case "transcribe":
            guard let rec = recording(params.first ?? "latest") else { write(["ok": false, "error": "no such recording"], to: out); return }
            c.transcribe(rec); write(["ok": true, "title": rec.title], to: out)
        case "load-transcript":
            guard let rec = recording(params.first ?? "latest") else { write(["ok": false, "error": "no such recording"], to: out); return }
            let ok = c.loadTranscript(for: rec)
            write(["ok": ok, "title": rec.title, "lines": c.liveTranscript.count], to: out)
        case "check-transcript":
            Task { @MainActor in
                await c.checkTranscript()
                write(["ok": c.lastError == nil, "error": c.lastError ?? NSNull(),
                       "suggestions": c.correctionSuggestions.map { ["id": $0.id, "segment": $0.suggestion.segment,
                                                                      "original": $0.suggestion.original, "suggestion": $0.suggestion.suggestion,
                                                                      "state": "\($0.state)"] },
                       "usage": c.lastCorrectionUsage.map { ["input": $0.inputTokens, "output": $0.outputTokens, "ms": $0.durationMs] } ?? NSNull()],
                      to: out)
            }
        case "correction":
            guard params.count >= 2 else { write(["ok": false, "error": "usage: correction accept|ignore|revert|focus <id>"], to: out); return }
            guard c.correctionSuggestions.contains(where: { $0.id == params[1] }) else {
                write(["ok": false, "error": "no suggestion with id \(params[1])", "ids": c.correctionSuggestions.map(\.id)], to: out); return
            }
            switch params[0] {
            case "accept": c.acceptCorrection(params[1])
            case "ignore": c.ignoreCorrection(params[1])
            case "revert": c.revertCorrection(params[1])
            case "focus": ui.focusedSuggestionID = params[1]   // UI-60:走點列同一條路(AppUIState → TranscriptPane.onChange)
            default: write(["ok": false, "error": "unknown correction action"], to: out); return
            }
            write(["ok": true, "suggestions": c.correctionSuggestions.map { ["id": $0.id, "state": "\($0.state)"] }], to: out)
        case "transcript":
            // UI-60 驗證用:transcript scroll bottom|<index>(走逐字稿 ScrollView 的 reader,對照「跟到最新」路徑)
            guard params.count >= 2, params[0] == "scroll" else { write(["ok": false, "error": "usage: transcript scroll bottom|<index>"], to: out); return }
            ui.transcriptScrollRequest = "\(params[1])#\(Date().timeIntervalSince1970)"
            write(["ok": true, "request": params[1]], to: out)
        case "corrections":
            if params.first == "ignore-all" { c.ignoreAllCorrections() } else if params.first == "clear" { c.clearCorrections() }
            else { write(["ok": false, "error": "usage: corrections ignore-all|clear"], to: out); return }
            write(["ok": true], to: out)
        case "backend":
            guard let b = CorrectionBackend(rawValue: params.first ?? "") else { write(["ok": false, "error": "usage: backend off|claudeCLI|codexCLI|appleFM|localFake"], to: out); return }
            c.correctionBackend = b; write(["ok": true, "backend": b.rawValue], to: out)
        case "model":
            // #2438 M6(MDL-05):model list | get <cap> | set|use <cap> <id> | request <cap> <id> | privacy accept|cancel
            // set＝直接寫(走 `ModelBackendRegistry.select`,**不跳**隱私框;校正同步 controller.correctionBackend);
            // request＝走設定頁 picker 同一條路(`ModelSelectionFlow.request`:出機後端沒同意過 ⇒ 掛起等確認框)。
            handleModel(params, c, ui, to: out)
        case "appearance":
            // #2438 M6(UI-55):App 內覆寫外觀(不碰系統設定、不寫偏好);system＝還原跟隨系統。
            // UI-56:`appearance set light|dark|system` 走設定頁同一條路(寫偏好 `appearanceMode` 並套用);
            // `appearance get` 回偏好值與目前生效值。
            switch params.first {
            case "light": NSApp.appearance = NSAppearance(named: .aqua)
            case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
            case "system": NSApp.appearance = nil
            case "set":
                guard params.count > 1, let m = AppearanceMode(rawValue: params[1]) else {
                    write(["ok": false, "error": "usage: appearance set light|dark|system"], to: out); return
                }
                AppearanceMode.select(m)
            case "get": break
            default: write(["ok": false, "error": "usage: appearance light|dark|system | set <mode> | get"], to: out); return
            }
            write(["ok": true, "appearance": NSApp.appearance?.name.rawValue ?? "system",
                   "appearanceMode": AppearanceMode.stored.rawValue], to: out)
        case "transcribe-policy":
            // #2483 E:get | set immediately|whenIdle|never
            if params.first == "set", params.count > 1, let p = TranscribePolicy(rawValue: params[1]) { c.transcribePolicy = p }
            else if params.first != "get" { write(["ok": false, "error": "usage: transcribe-policy get|set <immediately|whenIdle|never>"], to: out); return }
            write(["ok": true, "policy": c.transcribePolicy.rawValue, "pending": c.pendingHighAccuracy.count], to: out)
        case "transcribe-idle":
            // #2483 E:status | force(忽略閒置條件立刻挑一筆重轉)
            switch params.first {
            case "status": break
            case "force": c.idleTranscribeTick(force: true)
            default: write(["ok": false, "error": "usage: transcribe-idle status|force"], to: out); return
            }
            write(["ok": true, "pending": c.pendingHighAccuracy.count, "isTranscribing": c.isTranscribing,
                   "onAC": RecordingController.isOnACPower(), "idleSeconds": RecordingController.secondsSinceLastUserInput()], to: out)
        case "afm":
            // #2438 Phase 3a(AFM-01/08):status | force deviceNotEligible|appleIntelligenceNotEnabled|modelNotReady|unknown|unsupported | clear
            let afm = AppleFMAvailability.shared
            switch params.first {
            case "status": afm.refresh()
            case "force":
                guard params.count > 1 else { write(["ok": false, "error": "usage: afm force <reason|unsupported>"], to: out); return }
                if params[1] == "unsupported" { afm.forced = .unsupportedOS }
                else if let r = AFMReason(rawValue: params[1]) { afm.forced = .unavailable(r) }
                else { write(["ok": false, "error": "unknown reason \(params[1])"], to: out); return }
            case "clear": afm.forced = nil
            default: write(["ok": false, "error": "usage: afm status|force <reason>|clear"], to: out); return
            }
            write(["ok": true] .merging(afmJSON(), uniquingKeysWith: { a, _ in a }), to: out)
        case "folder-prompt":
            // MAS-06／07:status | show(叫出「選擇錄音資料夾」框)| later(＝按「稍後」)| revalidate(重探書籤)
            switch params.first {
            case "status": break
            case "show": ui.showFolderPrompt = true
            case "later": ui.showFolderPrompt = false
            case "revalidate": c.revalidateRecordingsFolder()
            default: write(["ok": false, "error": "usage: folder-prompt status|show|later|revalidate"], to: out); return
            }
            write(["ok": true, "presented": ui.showFolderPrompt, "needsFolder": c.needsRecordingsFolder,
                   "state": String(describing: c.recordingsFolderState), "recordingsDir": c.recordingsDir.path], to: out)
        case "whisper":
            // MAS-11／12／13:list(已裝＋sha 驗證)| download <id>(真下載,結束才寫結果)| delete <id> | verify <id>
            let store = WhisperModelStore.self
            func info(_ m: WhisperModel) -> [String: Any] {
                let u = store.modelsDir.appendingPathComponent(m.fileName)
                let installed = store.installed().contains { $0.model.id == m.id }
                return ["id": m.id, "installed": installed, "path": u.path, "approxMB": m.approxMB,
                        "sha256ok": installed ? store.verify(u, expectedSHA256: m.sha256) : NSNull()]
            }
            switch params.first {
            case "list":
                write(["ok": true, "modelsDir": store.modelsDir.path, "active": store.activeModelURL()?.path ?? NSNull(),
                       "engine": c.engine.rawValue, "models": WhisperModel.knownModels.map(info)], to: out)
            case "download":
                guard let m = WhisperModel.knownModels.first(where: { $0.id == params.dropFirst().first ?? "" }) else {
                    write(["ok": false, "error": "unknown model id"], to: out); return
                }
                Task {
                    let started = Date()
                    do {
                        let u = try await store.download(m) { _ in }
                        if UserDefaults.standard.string(forKey: "whisperModel") == nil { UserDefaults.standard.set(m.id, forKey: "whisperModel") }
                        await MainActor.run { c.reloadTranscriptionEngine() }
                        write(["ok": true, "path": u.path, "seconds": Date().timeIntervalSince(started),
                               "sha256ok": store.verify(u, expectedSHA256: m.sha256)], to: out)
                    } catch {
                        write(["ok": false, "error": "\(error)", "seconds": Date().timeIntervalSince(started),
                               "partLeft": FileManager.default.fileExists(atPath: store.modelsDir.appendingPathComponent(m.fileName + ".part").path)], to: out)
                    }
                }
                return   // 結果由 Task 寫
            case "delete":
                guard let m = WhisperModel.knownModels.first(where: { $0.id == params.dropFirst().first ?? "" }) else {
                    write(["ok": false, "error": "unknown model id"], to: out); return
                }
                store.delete(m); c.reloadTranscriptionEngine()
                write(["ok": true, "models": WhisperModel.knownModels.map(info)], to: out)
            case "verify":
                guard let m = WhisperModel.knownModels.first(where: { $0.id == params.dropFirst().first ?? "" }) else {
                    write(["ok": false, "error": "unknown model id"], to: out); return
                }
                write(info(m).merging(["ok": true]) { $1 }, to: out)
            default: write(["ok": false, "error": "usage: whisper list|download <id>|delete <id>|verify <id>"], to: out)
            }
        case "engine":
            // get | set appleNative|whisperKit(同設定頁 picker:寫偏好、閒置時立刻重建引擎)
            switch params.first {
            case "get": break
            case "set":
                guard let e = TranscriptionEngine(rawValue: params.dropFirst().first ?? "") else { write(["ok": false, "error": "usage: engine set appleNative|whisperKit"], to: out); return }
                c.engine = e   // didSet 寫偏好＋閒置時重建引擎
            default: write(["ok": false, "error": "usage: engine get|set <appleNative|whisperKit>"], to: out); return
            }
            write(["ok": true, "engine": c.engine.rawValue, "activeModel": WhisperModelStore.activeModelURL()?.lastPathComponent ?? NSNull()], to: out)
        case "onboarding":
            // MAS-31:status | reset | show | download(＝按「下載建議模型」)| later
            switch params.first {
            case "status": break
            case "reset": Onboarding.reset()
            case "show": ui.showOnboarding = true
            case "download":
                Onboarding.markShown(); ui.showOnboarding = false
                WhisperDownloads.shared.start(Onboarding.recommended, controller: c)
                ui.settingsScrollTo = SettingsView.transcriptSectionID; ui.showSettings = true
            case "later": Onboarding.markShown(); ui.showOnboarding = false
            default: write(["ok": false, "error": "usage: onboarding status|reset|show|download|later"], to: out); return
            }
            write(["ok": true, "shown": Onboarding.shown, "presented": ui.showOnboarding, "shouldShow": Onboarding.shouldShow(),
                   "downloading": Array(WhisperDownloads.shared.progress.keys), "message": Onboarding.message()], to: out)
        case "scope-probe":
            // MAS-33:書籤解出的 URL startAccessing 應 true;用 path 重建的 URL startAccessing 應 false(沒有 scope 屬性)。
            guard let data = UserDefaults.standard.data(forKey: RecordingController.recordingsDirBookmarkKey) else {
                write(["ok": false, "error": "no bookmark"], to: out); return
            }
            var stale = false
            guard let scoped = try? URL(resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale) else {
                write(["ok": false, "error": "resolve failed"], to: out); return
            }
            // 先把 controller 持有的 scope 放掉:process 已拿到該夾的 extension 時,任何同路徑 URL 的 startAccessing 都會回 true
            //(第一版探針就是這樣量到 rebuilt=true),量不到「重建 URL 沒有 scope」這件事。量完 revalidate 把 scope 拿回來。
            c.releaseRecordingsFolderAccess()
            let rebuilt = URL(fileURLWithPath: scoped.path, isDirectory: true)
            let b = rebuilt.startAccessingSecurityScopedResource()
            if b { rebuilt.stopAccessingSecurityScopedResource() }
            let a = scoped.startAccessingSecurityScopedResource()
            if a { scoped.stopAccessingSecurityScopedResource() }
            c.revalidateRecordingsFolder()
            write(["ok": true, "isMAS": BuildFlavor.isMAS, "bookmarkURLStart": a, "rebuiltURLStart": b, "stale": stale,
                   "restored": String(describing: c.recordingsFolderState)], to: out)
        case "consent":
            // MAS-17:status | reset(下次按錄音再跳)| show(走真的提示,同意會開錄)| accept | cancel(回答掛著的 sheet)
            switch params.first {
            case "status": break
            case "reset": RecordingConsent.reset()
            case "show": RecordingConsent.confirmThen { c.startRecording() }
            case "accept": if !RecordingConsent.respond(accept: true) { write(["ok": false, "error": "no sheet"], to: out); return }
            case "cancel": if !RecordingConsent.respond(accept: false) { write(["ok": false, "error": "no sheet"], to: out); return }
            default: write(["ok": false, "error": "usage: consent status|reset|show|accept|cancel"], to: out); return
            }
            write(["ok": true, "shown": RecordingConsent.shown, "presented": RecordingConsent.isPresented, "state": "\(c.state)"], to: out)
        case "legal":
            // MAS-16:連結與第三方授權全文有沒有打進 bundle
            write(["ok": true, "privacyPolicy": AppLinks.privacyPolicy.absoluteString, "repository": AppLinks.repository.absoluteString,
                   "licenses": ThirdPartyLicense.all.map { ["name": $0.id, "license": $0.license, "file": $0.file, "bundled": $0.bundled, "bytes": $0.text.utf8.count] }], to: out)
        case "prefs":
            // MAS-05 隔離驗證:只印**自己這個網域**(persistentDomain(forName: bundle id))的鍵與可讀值;
            // Data 型(書籤)只印長度,不把路徑／書籤內容吐出去。
            let domain = Bundle.main.bundleIdentifier ?? "?"
            let dict = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
            var shown: [String: Any] = [:]
            for (k, v) in dict {
                if let d = v as? Data { shown[k] = "<data \(d.count) bytes>" }
                else if let s = v as? String { shown[k] = s.count > 80 ? String(s.prefix(80)) + "…" : s }
                else if v is NSNumber || v is Bool || v is Int || v is Double { shown[k] = v }
                else if let a = v as? [Any] { shown[k] = "<array \(a.count)>" }
                else { shown[k] = "<\(type(of: v))>" }
            }
            write(["ok": true, "domain": domain, "count": dict.count, "keys": shown], to: out)
        case "sandbox-probe":
            // MAS-03:試在指定絕對路徑寫一個檔再刪(沙盒版對真 ~/Documents 應 EPERM;GitHub 版正控應成功)。
            guard let target = params.first, target.hasPrefix("/") else { write(["ok": false, "error": "usage: sandbox-probe </abs/path/file>"], to: out); return }
            let url = URL(fileURLWithPath: target)
            var result: [String: Any] = ["path": target, "home": NSHomeDirectory(),
                                         "containerID": ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? NSNull(),
                                         "isMAS": BuildFlavor.isMAS]
            do {
                try Data("probe".utf8).write(to: url, options: .atomic)
                try? FileManager.default.removeItem(at: url)
                result["ok"] = true; result["wrote"] = true
            } catch {
                result["ok"] = true; result["wrote"] = false; result["error"] = "\(error)"
            }
            write(result, to: out)
        case "model-hint":
            // UI-57:status(偏好 shown、框是否正顯示)| reset(刪偏好,下次啟動再跳)| show(立刻叫出框)
            switch params.first {
            case "status": break
            case "reset": ModelHint.reset()
            case "show": ui.showModelHint = true
            case "open": ui.modelHintOpenSettings()   // ＝按「打開設定」
            case "later": ui.modelHintLater()         // ＝按「稍後」
            default: write(["ok": false, "error": "usage: model-hint status|reset|show|open|later"], to: out); return
            }
            write(["ok": true, "modelHintShown": ModelHint.shown, "presented": ui.showModelHint], to: out)
        case "settings":
            switch params.first {
            case "open": ui.showSettings = true
            case "close": ui.showSettings = false
            case "scroll":
                // #2438 M6(UI-55 截圖):把設定頁 Form 的捲動區捲到 0～1 的位置(模型區段在第一屏之下)。只動捲軸,不動任何設定。
                guard params.count >= 2, let f = Double(params[1]), let sv = settingsScrollView() else {
                    write(["ok": false, "error": "usage: settings scroll <0..1>(設定頁要先開)"], to: out); return
                }
                let doc = sv.documentView?.frame.height ?? 0
                let maxY = max(0, doc - sv.contentView.bounds.height)
                sv.contentView.scroll(to: NSPoint(x: 0, y: maxY * min(1, max(0, f))))
                sv.reflectScrolledClipView(sv.contentView)
                write(["ok": true, "documentHeight": Double(doc), "y": Double(sv.contentView.bounds.minY)], to: out); return
            default: write(["ok": false, "error": "usage: settings open|close|scroll <0..1>"], to: out); return
            }
            write(["ok": true, "showSettings": ui.showSettings], to: out)
        case "window":
            // MAS-17:window hide|show ＝ 關窗模式(orderOut,同 -backgroundStart)／叫回視窗,驗關窗時的 Dock badge 與選單列指示。
            if params.first == "hide" {
                BackgroundStart.hideWindows()
                write(["ok": true, "visibleWindows": NSApp.windows.filter(\.isVisible).count,
                       "indicator": ["badge": (RecordingIndicator.badge as Any?) ?? NSNull(), "statusItem": RecordingIndicator.isShowing]], to: out); return
            }
            if params.first == "show" {
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil)
                write(["ok": true, "visibleWindows": NSApp.windows.filter(\.isVisible).count], to: out); return
            }
            // window size <w> <h>:直接設視窗 frame(模擬使用者拖視窗邊;AppKit 會夾到內容最小尺寸),驗 UI-47 最小寬度與壓縮。
            if params.first == "size" {
                guard params.count >= 3, let w = Double(params[1]), let h = Double(params[2]), let win = wm.currentWindow() else {
                    write(["ok": false, "error": "usage: window size <w> <h>"], to: out); return
                }
                let f = win.frame
                win.setFrame(NSRect(x: f.minX, y: f.maxY - h, width: w, height: h), display: true)
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(300))
                    var r = panesState(ui, wm); r["contentMinSize"] = ["w": Double(win.contentMinSize.width), "h": Double(win.contentMinSize.height)]
                    write(r, to: out)
                }
                return
            }
            guard let target = WindowMode(rawValue: params.first ?? "") else { write(["ok": false, "error": "usage: window standard|compact|mini | window size <w> <h>"], to: out); return }
            var guardCount = 0
            while wm.mode != target && guardCount < 3 { wm.cycle(); guardCount += 1 }   // 走既有的切換路徑,frame 才會套
            write(["ok": wm.mode == target, "mode": wm.mode.rawValue], to: out)
        case "panes":
            // #2438 M4(UI-45):面板工作區狀態(與偏好 `panes.standard` 同一份 JSON)＋畫面上實際顯示的欄。
            write(panesState(ui, wm), to: out)
        case "pane":
            // pane <transcript|notes|minutes|files> on|off ; pane order <a,b,c> ; pane width <kind> <pt>
            // 開關走 UI 同一條路(`PaneState.toggle`／`filesExpanded`);order 直接設完整順序(正規化後);
            // width 走欄間把手放開時的同一個 `setWidth`(下限 320),用來在寬螢幕上逼出 A1 的壓縮路徑。
            guard params.count >= 2 else {
                write(["ok": false, "error": "usage: pane <transcript|notes|minutes|files> on|off | pane order <a,b,c> | pane width <kind> <pt>"], to: out); return
            }
            if params[0] == "width" {
                guard params.count >= 3, let kind = PaneKind(rawValue: params[1]), let w = Double(params[2]) else {
                    write(["ok": false, "error": "usage: pane width <transcript|notes|minutes> <pt>"], to: out); return
                }
                ui.panes.setWidth(CGFloat(w), for: kind)
            } else if params[0] == "order" {
                let parsed = params[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                let kinds = parsed.compactMap(PaneKind.init(rawValue:))
                guard !kinds.isEmpty, kinds.count == parsed.count else {
                    write(["ok": false, "error": "unknown pane in order: \(params[1])"], to: out); return
                }
                ui.panes.order = PaneState.normalizedOrder(kinds)
            } else {
                guard params[1] == "on" || params[1] == "off" else {
                    write(["ok": false, "error": "usage: pane <kind> on|off"], to: out); return
                }
                let on = params[1] == "on"
                if params[0] == "files" {
                    ui.panes.filesExpanded = on
                } else if let kind = PaneKind(rawValue: params[0]) {
                    if ui.panes.open.contains(kind) != on { ui.panes.toggle(kind) }
                } else {
                    write(["ok": false, "error": "unknown pane: \(params[0])"], to: out); return
                }
            }
            writeAfterLayout(to: out, ui, wm)
        case "dock":
            guard let side = RemoteSide(rawValue: params.first ?? "") else {
                write(["ok": false, "error": "usage: dock left|right"], to: out); return
            }
            ui.panes.dock(side)
            writeAfterLayout(to: out, ui, wm)
        case "snapshot":
            snapshot(to: out, scheme: params.first ?? "light", target: params.count > 1 ? params[1] : "main", c, u, ui, wm)
        case "window-shot":
            // #2438 真視窗截圖(UI-43 驗收用):ImageRenderer 畫不出 AppKit 支援的 TextField／ScrollView(黃底 🚫),
            // 自己截自己的視窗不需要螢幕錄製權限。結果＝圖本身,另寫 .json。
            // #2438 M6:第 2 個參數選視窗——main(預設)／sheet(設定頁 sheet)／alert(設定頁上的確認框 sheet)。
            // `snapshot … settings` 的 ImageRenderer 連整個 grouped Form 都畫不出來(全白),設定頁只能用這條。
            // 10/22:第 3 個參數可指定渲染倍率(視窗在非 Retina 外接螢幕時 backingScaleFactor=1,README 截圖要 2 倍)。
            windowShot(to: out, target: params.first ?? "main", scale: params.count > 1 ? Double(params[1]) : nil)
            return
        case "calendar":
            // CAL-14:會議提醒排程器。inject 的假事件只進記憶體,不碰真日曆。
            let s = MeetingReminderScheduler.shared
            switch params.first {
            case "status":
                write(calendarState(s), to: out)
            case "reload":
                Task { @MainActor in await s.refresh(); write(calendarState(s), to: out) }
            case "enable":
                s.setEnabled(true)   // 會跳行事曆/通知權限詢問(第一次)
                Task { @MainActor in try? await Task.sleep(for: .seconds(2)); write(calendarState(s), to: out) }
            case "disable":
                s.setEnabled(false); write(calendarState(s), to: out)
            case "calendars":
                // calendar calendars <id1,id2,…>|all
                guard params.count >= 2 else { write(["ok": false, "error": "usage: calendar calendars <id,…>|all"], to: out); return }
                let ids: Set<String> = params[1] == "all" ? Set(s.calendars.map(\.id)) : Set(params[1].split(separator: ",").map(String.init))
                s.update { $0.calendarIDs = ids }
                Task { @MainActor in await s.refresh(); write(calendarState(s), to: out) }
            case "keywords":
                guard params.count >= 2 else { write(["ok": false, "error": "usage: calendar keywords <a,b,c>"], to: out); return }
                s.update { $0.keywords = ReminderSettings.parseKeywords(params[1]) }
                Task { @MainActor in await s.refresh(); write(calendarState(s), to: out) }
            case "lead":
                guard params.count >= 2, let m = Int(params[1]) else { write(["ok": false, "error": "usage: calendar lead <minutes>"], to: out); return }
                s.update { $0.leadMinutes = m }
                Task { @MainActor in await s.refresh(); write(calendarState(s), to: out) }
            case "command":
                s.update { $0.externalCommand = params.count >= 2 ? params[1] : "" }
                write(calendarState(s), to: out)
            case "inject":
                let iso = ISO8601DateFormatter()
                guard params.count >= 4, let st = iso.date(from: params[2]), let en = iso.date(from: params[3]) else {
                    write(["ok": false, "error": "usage: calendar inject <title> <startISO> <endISO>"], to: out); return
                }
                s.inject(title: params[1], start: st, end: en)
                Task { @MainActor in await s.refresh(); write(calendarState(s), to: out) }
            case "clear-injected":
                s.clearInjected()
                Task { @MainActor in await s.refresh(); write(calendarState(s), to: out) }
            case "fire":
                guard params.count >= 2 else { write(["ok": false, "error": "usage: calendar fire <key>"], to: out); return }
                let ok = s.fireNow(key: params[1])
                var st = calendarState(s); st["ok"] = ok
                write(st, to: out)
            default:
                write(["ok": false, "error": "usage: calendar status|reload|enable|disable|calendars <ids|all>|keywords <a,b>|lead <min>|command [cmd]|inject <title> <startISO> <endISO>|clear-injected|fire <key>"], to: out)
            }
        case "alarms":
            // CAL-08/11 驗證用:把 3 分鐘/30 分鐘改短。alarms dead <sec> | silence <sec>
            guard params.count >= 2, let sec = Double(params[1]) else { write(["ok": false, "error": "usage: alarms dead|silence <seconds>"], to: out); return }
            switch params[0] {
            case "dead": c.deadTrackAlarmAfter = sec
            case "silence": c.silenceStopAfter = sec
            default: write(["ok": false, "error": "usage: alarms dead|silence <seconds>"], to: out); return
            }
            write(["ok": true, "dead": c.deadTrackAlarmAfter, "silence": c.silenceStopAfter], to: out)
        case "lease":
            // #949:lease status(租約檔內容＋locked)| lease break(測試用:刪租約檔;只准示範夾＋MYPARROT_CONFIG_DIR 覆寫時)
            switch params.first {
            case "status", nil:
                write(leaseJSON(c), to: out)
            case "break":
                guard isDemoSetup(c) else {
                    write(["ok": false, "error": "lease break 只准在示範夾(錄音資料夾不在 ~/Documents 且有設 MYPARROT_CONFIG_DIR)"], to: out); return
                }
                let ok = RecordingLeaseHolder.breakLease()
                var j = leaseJSON(c); j["ok"] = ok; write(j, to: out)
            default:
                write(["ok": false, "error": "usage: lease status|break"], to: out)
            }
        case "external":
            // #949:external status(externalRecording 內容)| external stop|pause|resume(＝橫幅的鈕,呼叫 requestExternal*)
            switch params.first {
            case "status", nil:
                // 不在這裡 refresh:要驗的是「監看自己」有沒有在 2 秒內更新(手動 refresh 會蓋掉監看失效)。
                write(["ok": true, "externalRecording": externalJSON(c)], to: out)
            case "stop": c.requestExternalStop(); write(["ok": true, "externalRecording": externalJSON(c)], to: out)
            case "pause": c.requestExternalPause(); write(["ok": true, "externalRecording": externalJSON(c)], to: out)
            case "resume": c.requestExternalResume(); write(["ok": true, "externalRecording": externalJSON(c)], to: out)
            default:
                write(["ok": false, "error": "usage: external status|stop|pause|resume"], to: out)
            }
        case "notify":
            // notify status | request | action start [title] | action stop
            let n = AppNotifications.shared
            switch params.first {
            case "status":
                write(notifyState(n), to: out)
            case "request":
                Task { @MainActor in let ok = await n.requestAuthorization(); var st = notifyState(n); st["ok"] = ok; write(st, to: out) }
            case "delivered":
                Task { @MainActor in let ids = await n.deliveredIDs(); write(["ok": true, "delivered": ids], to: out) }
            case "action":
                guard params.count >= 2 else { write(["ok": false, "error": "usage: notify action start [title]|stop"], to: out); return }
                if params[1] == "start" {
                    n.handle(action: AppNotifications.actionStart, category: AppNotifications.categoryReminder,
                             userInfo: ["title": params.count > 2 ? params[2] : ""])
                } else if params[1] == "stop" {
                    n.handle(action: AppNotifications.actionStop, category: AppNotifications.categorySilence, userInfo: [:])
                } else { write(["ok": false, "error": "usage: notify action start [title]|stop"], to: out); return }
                write(["ok": true, "state": "\(c.state)", "title": c.currentTitle], to: out)
            default:
                write(["ok": false, "error": "usage: notify status|request|delivered|action start [title]|action stop"], to: out)
            }
        // #2438 M5:筆記／檔案／會議記錄(NOTE-01/02/07、UI-52/53/54、MIN-00 驗證用)
        case "notes":
            guard let n = ui.notes else { write(["ok": false, "error": "no notes session"], to: out); return }
            switch params.first {
            case "get":
                write(["ok": true, "text": n.store.text, "path": n.store.url?.path ?? "", "draft": n.isDraft,
                       "dirty": n.store.isDirty, "locked": n.lockedStem != nil], to: out)
            case "set":
                n.store.setText(params.dropFirst().joined(separator: " ").replacingOccurrences(of: "\\n", with: "\n"))
                write(["ok": true, "length": (n.store.text as NSString).length, "dirty": n.store.isDirty], to: out)
            case "append":
                n.appendBlock(params.dropFirst().joined(separator: " ").replacingOccurrences(of: "\\n", with: "\n"))
                write(["ok": true, "length": (n.store.text as NSString).length], to: out)
            case "mark":
                ui.addMarker(at: c.elapsed)
                write(["ok": true, "text": n.store.text, "markers": ui.markers.count], to: out)
            case "quote":
                guard let i = params.dropFirst().first.flatMap({ Int($0) }), i >= 0, i < c.liveTranscript.count else {
                    write(["ok": false, "error": "quote <index 0..\(max(0, c.liveTranscript.count - 1))>"], to: out); return
                }
                let line = c.liveTranscript[i]
                n.appendQuote(speakerLabel: L(line.isYou ? "你" : "對方"), elapsed: line.start, text: line.text)
                write(["ok": true, "text": n.store.text], to: out)
            case "flush":
                let ok = n.store.flush()
                write(["ok": ok, "path": n.store.url?.path ?? "", "error": n.store.lastError ?? "",
                       "writeCount": n.store.writeCount], to: out)
            case "path":
                write(["ok": true, "path": n.store.url?.path ?? "", "draft": n.isDraft, "stem": n.stem?.path ?? "",
                       "locked": n.lockedStem?.path ?? "", "writeCount": n.store.writeCount], to: out)
            default:
                write(["ok": false, "error": "notes get|set <text>|append <md>|mark|quote <idx>|flush|path"], to: out)
            }
        case "files":
            switch params.first {
            case "search":
                ui.filesQuery = params.dropFirst().joined(separator: " ")
                let q = ui.filesQuery
                let hits = c.recordings.filter { q.isEmpty || $0.title.localizedCaseInsensitiveContains(q) }
                write(["ok": true, "query": q, "matches": hits.map(\.title)], to: out)
            case "select":
                guard params.count >= 2, let r = recording(params[1]) else { write(["ok": false, "error": "bad index"], to: out); return }
                ui.selectedRecording = r.id
                write(["ok": true, "title": r.title, "url": r.url.path, "notesPath": ui.notes?.store.url?.path ?? "",
                       "locked": ui.notes?.lockedStem != nil], to: out)
            case "locked":
                guard params.count >= 2, let r = recording(params[1]) else { write(["ok": false, "error": "bad index"], to: out); return }
                write(["ok": true, "locked": c.isFileActionLocked(r)], to: out)
            case "rename":
                guard params.count >= 3, let r = recording(params[1]) else { write(["ok": false, "error": "rename <n> <title>"], to: out); return }
                ui.notes?.flushAll()
                do {
                    let newURL = try c.rename(r, to: params.dropFirst(2).joined(separator: " "))
                    if newURL != r.url { ui.notes?.renamed(from: r.url, to: newURL) }
                    write(["ok": true, "url": newURL.path,
                           "sidecars": SidecarSet.existing(stem: SidecarSet.stem(of: newURL)).map(\.lastPathComponent)], to: out)
                } catch { write(["ok": false, "error": FileActions.message(for: error)], to: out) }
            case "trash":
                guard params.count >= 2, let r = recording(params[1]) else { write(["ok": false, "error": "trash <n>"], to: out); return }
                ui.notes?.flushAll()
                do {
                    try c.trash(r)
                    ui.notes?.trashed(r.url)
                    write(["ok": true, "remaining": c.recordings.count], to: out)
                } catch { write(["ok": false, "error": FileActions.message(for: error)], to: out) }
            default:
                write(["ok": false, "error": "files search <q>|select <n>|locked <n>|rename <n> <title>|trash <n>"], to: out)
            }
        case "minutes":
            guard let n = ui.notes else { write(["ok": false, "error": "no notes session"], to: out); return }
            switch params.first {
            case "update":
                Task { @MainActor in
                    await n.updateMinutesNow(controller: c)
                    write(["ok": n.minutes.lastError == nil && n.minutes.document != nil, "hasDocument": n.minutes.document != nil,
                           "error": n.minutes.lastError ?? "", "md": n.minutes.markdownURL?.path ?? "",
                           "inputTokens": n.minutes.inputTokens, "outputTokens": n.minutes.outputTokens,
                           "consumed": n.minutes.transcriptLinesConsumed, "failures": n.minutes.consecutiveFailures,
                           "backend": n.minutes.backendID], to: out)
                }
            case "cadence":
                n.minutes.cadenceMinutes = params.count >= 2 ? (Int(params[1]) ?? 5) : 5
                write(["ok": true, "cadence": n.minutes.cadenceMinutes], to: out)
            case "auto":
                n.minutes.autoEnabled = params.count >= 2 && params[1] == "on"
                write(["ok": true, "auto": n.minutes.autoEnabled], to: out)
            case "status":
                write(["ok": true, "available": n.minutes.isAvailable, "cadence": n.minutes.cadenceMinutes, "auto": n.minutes.autoEnabled,
                       "hasDocument": n.minutes.document != nil, "updating": n.minutes.isUpdating,
                       "lastUpdate": n.minutes.lastUpdate.map { "\($0)" } ?? "", "md": n.minutes.markdownURL?.path ?? "",
                       // Phase 2(MIN-14)
                       "backend": n.minutes.backendID, "unavailableReason": n.minutes.unavailableReason ?? "",
                       "consumed": n.minutes.transcriptLinesConsumed, "failures": n.minutes.consecutiveFailures,
                       "autoPaused": n.minutes.autoPaused, "canGenerate": n.canGenerateMinutes(controller: c),
                       "transcriptSource": "\(n.minutesTranscript(controller: c).source)",
                       "error": n.minutes.lastError ?? ""], to: out)
            default:
                write(["ok": false, "error": "minutes update|cadence <n>|auto on|off|status"], to: out)
            }
        case "tokens":
            // #2623 TOK-06:tokens status(目前那場 totals) | inject <feature> <backend> <in> <out>(DEBUG 驗證用)
            guard let n = ui.notes else { write(["ok": false, "error": "no notes session"], to: out); return }
            switch params.first {
            case "status": write(tokensJSON(n), to: out)
            case "inject":
                guard params.count >= 5, let s = n.stem, let cap = ModelCapability(rawValue: params[1]), let i = Int(params[3]), let o = Int(params[4]) else {
                    write(["ok": false, "error": "usage: tokens inject correction|minutes|translation <backend> <in> <out>(要先選一場)"], to: out); return
                }
                let ok = TokenLedger.append(stem: s, TokenEntry(feature: cap, backend: params[2], inputTokens: i, outputTokens: o, durationMs: 0, units: 0))
                write(["ok": ok, "file": TokenLedger.url(stem: s).path], to: out)
            default: write(["ok": false, "error": "tokens status|inject <feature> <backend> <in> <out>"], to: out)
            }
        case "translation":
            // #2612 TRL-13:translation status|update|whole|retry|target <x>|cadence <sec>|show on|off|availability force <x>|clear
            guard let n = ui.notes else { write(["ok": false, "error": "no notes session"], to: out); return }
            let t = n.translation
            switch params.first {
            case "status": write(translationJSON(t, session: n, c), to: out)
            case "update": t.translateNow(); write(["ok": true], to: out)
            case "whole": n.translateWholeNow(controller: c); write(["ok": true, "pending": t.pending.count], to: out)
            case "retry": t.retryAllFailed(); write(["ok": true], to: out)
            case "live":
                // 驗證用:把畫面上這份稿當「錄音中」來源起／停自動翻譯 loop(TRL-04 的節奏與排隊路徑,不必真錄音)。
                if params.count >= 2, params[1] == "on" { t.startAuto(transcript: { c.liveTranscript }, language: { c.language }) } else { t.endAuto() }
                write(["ok": true, "live": params.count >= 2 && params[1] == "on"], to: out)
            case "target":
                guard params.count >= 2, let tg = TranslationTarget(rawValue: params[1]) else { write(["ok": false, "error": "usage: translation target zh-Hant|en|ja|ko|zh-Hans"], to: out); return }
                t.target = tg; write(["ok": true, "target": t.target.rawValue], to: out)
            case "cadence":
                guard params.count >= 2, let s = Int(params[1]), TranslationPlan.cadenceOptions.contains(s) else { write(["ok": false, "error": "usage: translation cadence 30|60|120|300"], to: out); return }
                t.cadenceSeconds = s; write(["ok": true, "cadence": t.cadenceSeconds], to: out)
            case "show":
                t.showTranslations = params.count >= 2 && params[1] == "on"; write(["ok": true, "show": t.showTranslations], to: out)
            case "availability":
                if params.count >= 3, params[1] == "force", let a = TranslationController.Availability(rawValue: params[2]) { t.forcedAvailability = a }
                else if params.count >= 2, params[1] == "clear" { t.forcedAvailability = nil }
                else { write(["ok": false, "error": "usage: translation availability force installed|supported|unsupported|clear"], to: out); return }
                write(["ok": true, "availability": t.effectiveAvailability.rawValue, "forced": t.forcedAvailability?.rawValue ?? ""], to: out)
            default:
                write(["ok": false, "error": "translation status|update|whole|retry|live on|off|target <x>|cadence <sec>|show on|off|availability force <x>|clear"], to: out)
            }
        case "quit":
            write(["ok": true], to: out)
            // 走正常退出流程(含錄音中/轉稿中的確認框)。🔴 不能從主 dispatch queue 的 block
            // 裡呼叫 terminate(同步或 DispatchQueue.main.async 都一樣):applicationShouldTerminate
            // 回 terminateLater 後,AppKit 在 terminate: 裡開巢狀事件迴圈等 reply,而 reply 來自
            // 主佇列上的下一個 Task——序列佇列正卡在這個 block,永遠排不到(sample 定讞:
            // _dispatch_main_queue_drain → handle → terminate: → nextEventMatchingMask 死等)。
            // 用 run loop 的 performSelector 排程,從事件迴圈進 terminate:,主佇列才是空的。
            NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0)
        default:
            write(["ok": false, "error": "unknown command: \(cmd)"], to: out)
        }
    }

    // MARK: - 狀態 JSON(DBG-02)

    private static func state(_ c: RecordingController, _ ui: AppUIState, _ wm: WindowModeManager) -> [String: Any] {
        [
            "ok": true,
            "state": "\(c.state)",
            "elapsed": c.elapsed,
            "otherLevel": Double(c.otherLevel), "youLevel": Double(c.youLevel),
            "otherHasSignal": c.sysHasSignal, "youHasSignal": c.micHasSignal,
            "isSwitchingMic": c.isSwitchingMic,                       // AUD-38
            "mic": c.selectedInputDevice?.name ?? NSNull(),           // AUD-38
            "warning": c.deviceChangeWarning ?? NSNull(),
            "lastError": c.lastError ?? NSNull(),
            "title": c.currentTitle,
            "transcriptSource": c.transcriptSource?.title ?? NSNull(),
            "transcriptLines": c.liveTranscript.count,
            "isTranscribing": c.isTranscribing,
            "transcribingID": c.transcribingID?.uuidString ?? NSNull(),
            "correctionBackend": c.correctionBackend.rawValue,
            // #2438 M6(MDL-05):每個能力目前選的後端(經登錄表解析)＋掛起中的隱私確認。
            "model": modelSelections(),
            "modelPending": ui.modelFlow.pending.map { ["capability": $0.capability.rawValue, "backend": $0.backendID] } ?? NSNull(),
            "minutesEnabled": ui.minutesEnabled,
            "focusedSuggestion": ui.focusedSuggestionID ?? NSNull(),   // UI-60
            "fullTranscript": ui.fullTranscript,
            "transcriptScroll": ui.transcriptScroll,
            "translation": ui.notes.map { translationJSON($0.translation, session: $0, c) } ?? [:],   // #2612
            "tokens": ui.notes.map { tokensJSON($0) } ?? [:],   // #2623
            "isCheckingTranscript": c.isCheckingTranscript,
            "suggestions": c.correctionSuggestions.map { ["id": $0.id, "state": "\($0.state)"] },
            "holdingSleepAssertion": c.isHoldingSleepAssertion,
            "windowMode": wm.mode.rawValue,
            // #2438 M4:面板工作區與視窗 frame(UI-47 量視窗寬)。
            "selectedRecording": ui.selectedRecording?.uuidString ?? "",
            "notes": ui.notes.map { n -> [String: Any] in
                ["path": n.store.url?.path ?? "", "draft": n.isDraft, "locked": n.lockedStem != nil, "dirty": n.store.isDirty,
                 "length": (n.store.text as NSString).length, "focused": n.proxy.isFocused, "writeCount": n.store.writeCount] } ?? [:],
            "minutes": ui.notes.map { n -> [String: Any] in
                ["available": n.minutes.isAvailable, "cadence": n.minutes.cadenceMinutes, "auto": n.minutes.autoEnabled,
                 "hasDocument": n.minutes.document != nil, "inputTokens": n.minutes.inputTokens, "outputTokens": n.minutes.outputTokens,
                 "backend": n.minutes.backendID, "consumed": n.minutes.transcriptLinesConsumed,
                 "failures": n.minutes.consecutiveFailures, "autoPaused": n.minutes.autoPaused] } ?? [:],
            "panes": panesJSON(ui.panes),
            "windowFrame": windowFrame(wm),
            "showSettings": ui.showSettings,
            "uiLanguage": Localizer.shared.language.rawValue,
            // UI-56:外觀偏好(system|light|dark)與目前生效的 NSApp.appearance(nil＝跟隨系統)。
            "appearanceMode": AppearanceMode.stored.rawValue,
            "appearance": NSApp.appearance?.name.rawValue ?? "system",
            // UI-57:首次模型提示有沒有跳過、現在是否正顯示。
            "modelHintShown": ModelHint.shown,
            "modelHintPresented": ui.showModelHint,
            // AFM-01:Apple 本機模型可用性(status/reason/forced/message)。
            "afm": afmJSON(),
            // #2483 C/E:重轉政策、待閒置重轉筆數、重轉版本。
            "transcribePolicy": c.transcribePolicy.rawValue,
            "pendingHighAccuracy": c.pendingHighAccuracy.count,
            "transcriptVersion": c.transcriptVersion,
            "recordingsDir": c.recordingsDir.path,
            // MAS-17:一次性錄音提示與錄音中指示(Dock badge／選單列)
            "consent": ["shown": RecordingConsent.shown, "presented": RecordingConsent.isPresented],
            "onboarding": ["shown": Onboarding.shown, "presented": ui.showOnboarding],   // MAS-31
            "indicator": ["badge": (RecordingIndicator.badge as Any?) ?? NSNull(), "statusItem": RecordingIndicator.isShowing],
            // MAS-03／06／07:書籤狀態、是否要先選夾、沙盒容器 id(非沙盒＝null)、NSHomeDirectory(沙盒＝容器 Data)。
            "recordingsFolder": ["state": String(describing: c.recordingsFolderState), "needsFolder": c.needsRecordingsFolder,
                                 "promptPresented": ui.showFolderPrompt],
            "sandbox": ["isMAS": BuildFlavor.isMAS, "home": NSHomeDirectory(),
                        "containerID": ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? NSNull()],
            "recordings": c.recordings.map { ["title": $0.title, "hasTranscript": $0.hasTranscript, "isConverting": $0.isConverting] },
            "build": buildStamp,
            // #2438 R1:打包字型有沒有註冊成功(驗證計時字型)。
            "fontRegistered": FontRegistrar.registered,
            // #2407
            "alarms": ["dead": c.deadTrackAlarmAfter, "silence": c.silenceStopAfter,
                       "deadTrackAlarms": c.deadTrackAlarms.map(\.rawValue),
                       "silenceStopSuggestedAt": c.silenceStopSuggestedAt.map { MeetingReminderScheduler.iso($0) } ?? NSNull(),
                       "micFloor": Double(c.speechGauge.micFloor), "micSpeechThreshold": Double(c.speechGauge.micThreshold),
                       "sysFloor": Double(c.speechGauge.sysFloor), "sysSpeechThreshold": Double(c.speechGauge.sysThreshold)],
            "calendar": calendarState(MeetingReminderScheduler.shared),
            "notify": notifyState(AppNotifications.shared),
            // #949 第一段:租約、別的進程的錄音、主視窗是否可見(REC-39 -backgroundStart)
            "lease": leaseJSON(c),
            "externalRecording": externalJSON(c),
            "windowVisible": wm.currentWindow()?.isVisible ?? NSNull(),
            "activationPolicy": NSApp.activationPolicy() == .regular ? "regular" : "\(NSApp.activationPolicy().rawValue)",
            "recordingsDetail": c.recordings.map { ["title": $0.title, "path": $0.url.path, "isConverting": $0.isConverting,
                                                    "needsManualRepair": $0.needsManualRepair] },
        ]
    }

    // MARK: - #949 租約／外部錄音

    private static func leaseJSON(_ c: RecordingController) -> [String: Any] {
        let path = RecordingLeaseHolder.leaseURL(in: RecordingLeaseHolder.directory())
        let raw = FileManager.default.contents(atPath: path.path)
        let content: Any = raw.flatMap { try? JSONSerialization.jsonObject(with: $0) } ?? NSNull()
        let inspection = RecordingLeaseHolder.inspect()
        let kind: String
        switch inspection {
        case .none: kind = "none"
        case .alive: kind = "alive"
        case .dead: kind = "dead"
        case .unreadable(let e): kind = "unreadable(\(e))"
        }
        let locked: Any
        switch inspection {
        case .alive: locked = true
        case .dead: locked = false
        default: locked = NSNull()
        }
        return ["ok": true, "path": path.path, "lease": content, "locked": locked, "inspection": kind,
                "holdsLease": c.holdsLease, "sessionId": c.sessionId ?? NSNull()]
    }

    private static func externalJSON(_ c: RecordingController) -> Any {
        guard let e = c.externalRecording else { return NSNull() }
        return ["owner": e.lease.owner, "sessionId": e.lease.sessionId, "pid": Int(e.lease.pid), "name": e.lease.name,
                "protocolVersion": e.lease.protocolVersion, "elapsed": e.elapsed(), "paused": e.paused,
                "unresponsive": e.unresponsive, "supportsCommands": e.supportsCommands,
                "other": e.state?.levels.other ?? NSNull(), "you": e.state?.levels.you ?? NSNull(),
                "stateUpdatedAt": e.state?.updatedAt ?? NSNull()] as [String: Any]
    }

    /// `lease break` 的保險:錄音資料夾不在 ~/Documents、而且設定目錄是 MYPARROT_CONFIG_DIR 覆寫的(不是真的 ~/.config/myparrot)。
    private static func isDemoSetup(_ c: RecordingController) -> Bool {
        let docs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Documents").standardizedFileURL.path
        let overridden = getenv("MYPARROT_CONFIG_DIR").map { !String(cString: $0).isEmpty } ?? false
        return overridden && !c.recordingsDir.standardizedFileURL.path.hasPrefix(docs)
    }

    // MARK: - 模型(#2438 M6,MDL-05)

    private static func modelSelections() -> [String: String] {
        Dictionary(uniqueKeysWithValues: ModelCapability.allCases.map { ($0.rawValue, ModelBackendRegistry.selected(for: $0).id) })
    }

    private static func modelState(_ c: RecordingController, _ ui: AppUIState) -> [String: Any] {
        [
            "model": modelSelections(),
            "correctionBackend": c.correctionBackend.rawValue,
            "minutesEnabled": ui.minutesEnabled,
            "minutesAvailable": ui.notes?.minutes.isAvailable ?? false,
            "pending": ui.modelFlow.pending.map { ["capability": $0.capability.rawValue, "backend": $0.backendID] } ?? NSNull(),
            "privacyAccepted": Dictionary(uniqueKeysWithValues: ModelBackendRegistry.all.filter { !$0.isLocal }.map {
                ($0.id, UserDefaults.standard.bool(forKey: ModelBackendRegistry.privacyAcceptedKey(for: $0.id))) }),
        ]
    }

    private static func handleModel(_ params: [String], _ c: RecordingController, _ ui: AppUIState, to out: String) {
        let usage = "usage: model list | get <correction|minutes|translation> | set <cap> <id> | request <cap> <id> | privacy accept|cancel"
        func cap(_ i: Int) -> ModelCapability? { params.count > i ? ModelCapability(rawValue: params[i]) : nil }
        switch params.first {
        case "list":
            var caps: [String: Any] = [:]
            for k in ModelCapability.allCases {
                caps[k.rawValue] = ["selected": ModelBackendRegistry.selected(for: k).id,
                                    "backends": ModelBackendRegistry.backends(for: k).map(\.id),
                                    "cloud": ModelBackendRegistry.backends(for: k).filter { !$0.isLocal }.map(\.id)]
            }
            var st = modelState(c, ui); st["ok"] = true; st["capabilities"] = caps
            write(st, to: out)
        case "get":
            guard let k = cap(1) else { write(["ok": false, "error": usage], to: out); return }
            let sel = ModelBackendRegistry.selected(for: k)
            write(["ok": true, "capability": k.rawValue, "selected": sel.id, "isLocal": sel.isLocal,
                   "enabled": ModelBackendRegistry.isEnabled(k)], to: out)
        case "set", "use":
            guard let k = cap(1), params.count > 2 else { write(["ok": false, "error": usage], to: out); return }
            ModelSelectionFlow.apply(params[2], for: k, controller: c, ui: ui)
            ui.refreshMinutesEnabled()
            var st = modelState(c, ui)
            st["ok"] = ModelBackendRegistry.selected(for: k).id == params[2]
            st["requested"] = params[2]
            write(st, to: out)
        case "request":
            guard let k = cap(1), params.count > 2 else { write(["ok": false, "error": usage], to: out); return }
            ui.modelFlow.request(params[2], for: k, controller: c, ui: ui)
            var st = modelState(c, ui); st["ok"] = true
            write(st, to: out)
        case "privacy":
            switch params.count > 1 ? params[1] : "" {
            case "accept": ui.modelFlow.confirm(controller: c, ui: ui)
            case "cancel": ui.modelFlow.cancel(controller: c, ui: ui)
            default: write(["ok": false, "error": usage], to: out); return
            }
            var st = modelState(c, ui); st["ok"] = true
            write(st, to: out)
        default:
            write(["ok": false, "error": usage], to: out)
        }
    }

    // MARK: - 面板工作區(#2438 M4)

    private static func panesJSON(_ p: PaneState) -> Any {
        guard let data = try? JSONEncoder().encode(p),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return NSNull() }
        return obj
    }

    private static func rectJSON(_ r: NSRect) -> [String: Double] {
        ["x": Double(r.minX), "y": Double(r.minY), "width": Double(r.width), "height": Double(r.height)]
    }

    private static func windowFrame(_ wm: WindowModeManager) -> Any {
        guard let w = wm.currentWindow() else { return NSNull() }
        return rectJSON(w.frame)
    }

    private static func panesState(_ ui: AppUIState, _ wm: WindowModeManager) -> [String: Any] {
        let visible = wm.mode == .standard ? ui.panes.visibleColumns(minutesEnabled: ui.minutesEnabled) : []
        return [
            "ok": true,
            "panes": panesJSON(ui.panes),
            "visibleColumns": visible.map(\.rawValue),
            "columnWidths": visible.map { Double(ui.panes.width(of: $0)) },
            "renderedWidths": visible.map { Double(ui.renderedColumnWidths[$0] ?? 0) },
            "minutesEnabled": ui.minutesEnabled,
            "windowMode": wm.mode.rawValue,
            "windowFrame": windowFrame(wm),
            "screenVisibleFrame": wm.currentVisibleFrame().map(rectJSON) ?? NSNull(),
        ]
    }

    /// 開關／停靠會觸發視窗 resolve(下一輪 runloop＋0.2 s 動畫);等它落定再回報,frame 才是新的。
    private static func writeAfterLayout(to out: String, _ ui: AppUIState, _ wm: WindowModeManager) {
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            write(panesState(ui, wm), to: out)
        }
    }

    private static func calendarState(_ s: MeetingReminderScheduler) -> [String: Any] {
        [
            "ok": true,
            "enabled": s.settings.enabled, "running": s.running,
            "authorized": s.source.isAuthorized, "authorizationDenied": s.authorizationDenied,
            "rawStatus": s.source.rawStatus, "statusBeforeRequest": s.source.lastRequestStatusBefore ?? NSNull(),
            "requestError": s.source.lastRequestError ?? NSNull(),
            "calendars": s.calendars.map { ["id": $0.id, "title": $0.title, "source": $0.source] },
            "selected": Array(s.settings.calendarIDs).sorted(),
            "keywords": s.settings.keywords, "leadMinutes": s.settings.leadMinutes,
            "externalCommandSet": !s.settings.externalCommand.isEmpty,
            "lastRefreshAt": s.lastRefreshAt.map { MeetingReminderScheduler.iso($0) } ?? NSNull(),
            "lastError": s.lastError ?? NSNull(),
            "planned": s.planned.map { ["key": $0.key, "title": $0.event.title,
                                       "start": MeetingReminderScheduler.iso($0.event.start),
                                       "fireAt": MeetingReminderScheduler.iso($0.fireAt)] },
            "firedThisSession": s.firedThisSession,
            "lastFiredAt": s.lastFiredAt.map { MeetingReminderScheduler.iso($0) } ?? NSNull(),
            "logPath": MeetingReminderScheduler.logURL.path,
            "firedStorePath": s.fired.url.path,
        ]
    }

    private static func notifyState(_ n: AppNotifications) -> [String: Any] {
        [
            "ok": true,
            "available": n.available, "installed": n.installed,
            "authorized": n.authorized.map { $0 } ?? NSNull(),
            "rawStatus": n.authorizationRaw ?? NSNull(),
            "posted": n.posted.map { ["id": $0.id, "category": $0.category, "at": MeetingReminderScheduler.iso($0.at)] },
            "lastAction": n.lastAction.map { ["category": $0.category, "action": $0.action, "at": MeetingReminderScheduler.iso($0.at)] } ?? NSNull(),
        ]
    }

    // MARK: - 截圖(DBG-04):ImageRenderer 畫當下的 view,不靠螢幕(鎖定也能產出)

    private static func snapshot(to path: String, scheme: String, target: String,
                                 _ c: RecordingController, _ u: UpdateChecker, _ ui: AppUIState, _ wm: WindowModeManager) {
        let content: AnyView
        switch target {
        case "settings": content = AnyView(SettingsView(controller: c, updates: u, uiState: ui).frame(width: 480, height: 640))
        case "mini": content = AnyView(MiniView(controller: c, windowMode: wm).frame(width: 300, height: 60))
        default:
            // #2438 M4:寬度跟著面板工作區(標準模式＝控制欄＋開著的直欄;其他模式＝只剩控制欄 380)。
            let width = wm.mode == .standard ? WorkspaceView.targetWidth(ui.panes, minutesEnabled: ui.minutesEnabled) : WorkspaceView.leftWidth
            content = AnyView(RootView(controller: c, updates: u, uiState: ui, windowMode: wm).frame(width: width, height: 880))
        }
        let renderer = ImageRenderer(content: content.environment(\.colorScheme, scheme == "dark" ? .dark : .light))
        renderer.scale = 2
        guard let cg = renderer.cgImage,
              let png = NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:]) else {
            write(["ok": false, "error": "render failed"], to: path); return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
            // 結果檔與圖是同一個路徑:圖本身就是結果;另寫一個 .json 說明尺寸。
            write(["ok": true, "png": path, "width": cg.width, "height": cg.height], to: path + ".json")
        } catch {
            write(["ok": false, "error": "\(error)"], to: path + ".json")
        }
    }

    // MARK: - 結果檔

    /// 真視窗截圖:把視窗 contentView 的 CALayer 樹 render 進點陣圖(自家視窗不需要螢幕錄製權限;
    /// macOS 27 SDK 已拿掉 CGWindowListCreateImage)。模糊／材質類 CA filter 不會進來,其餘版面、AppKit
    /// 支援的 TextField、字型都是真的。
    /// 設定頁 sheet(主視窗上掛著的那張)。
    private static func settingsSheet() -> NSWindow? {
        NSApp.windows.first(where: { $0.contentView != nil && !$0.isSheet })?.attachedSheet
    }

    /// 設定頁 Form 的捲動區:sheet 內容樹裡最高的那個 NSScrollView。
    private static func settingsScrollView() -> NSScrollView? {
        guard let root = settingsSheet()?.contentView else { return nil }
        var found: [NSScrollView] = []
        func walk(_ v: NSView) { if let s = v as? NSScrollView { found.append(s) }; v.subviews.forEach(walk) }
        walk(root)
        return found.max(by: { $0.frame.height < $1.frame.height })
    }

    /// AFM 狀態 → JSON。
    /// #2623 TOK-06:這場帳本的 totals JSON。
    @MainActor private static func tokensJSON(_ n: NotesSession) -> [String: Any] {
        let t = TokenLedger.totals(n.tokens)
        func sum(_ s: TokenSum) -> [String: Any] { ["in": s.inputTokens, "out": s.outputTokens, "calls": s.calls, "ms": s.durationMs, "units": s.units, "estimated": s.estimated] }
        return ["ok": true, "stem": n.stem?.lastPathComponent ?? "", "entries": n.tokens.count, "all": sum(t.all),
                "byFeature": t.byFeature.mapValues(sum),
                "byFeatureBackend": t.byFeatureBackend.mapValues { $0.mapValues(sum) },
                "summaryLine": n.tokenSummaryLine ?? "",
                "file": n.stem.map { TokenLedger.url(stem: $0).path } ?? ""]
    }

    /// #2612 TRL-13:翻譯狀態 JSON(`translation status` 與 `state.translation` 共用)。
    @MainActor private static func translationJSON(_ t: TranslationController, session n: NotesSession, _ c: RecordingController) -> [String: Any] {
        ["ok": true, "backend": t.backendID, "enabled": t.isEnabled, "available": t.isAvailable,
         "availability": t.effectiveAvailability.rawValue, "forced": t.forcedAvailability?.rawValue ?? "",
         "target": t.target.rawValue, "cadence": t.cadenceSeconds, "show": t.showTranslations,
         "pending": t.pending.count, "inFlight": t.inFlight.count, "translated": t.translations.count, "failed": t.failed.count,
         "translating": t.isTranslating, "stale": t.stale, "autoPaused": t.autoPaused, "failures": t.consecutiveFailures,
         "batches": t.batchCount, "inputTokens": t.inputTokens, "outputTokens": t.outputTokens,
         "whole": t.wholeProgress.map { ["done": $0.done, "total": $0.total] } ?? [:],
         "file": t.fileURL?.path ?? "", "fileExists": t.fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
         "unavailableReason": t.unavailableReason ?? "", "error": t.lastError ?? ""]
    }

    private static func afmJSON() -> [String: Any] {
        let afm = AppleFMAvailability.shared
        let status: String, reason: String?
        switch afm.status {
        case .available: status = "available"; reason = nil
        case .unsupportedOS: status = "unsupportedOS"; reason = nil
        case .unavailable(let r): status = "unavailable"; reason = r.rawValue
        }
        var forced: String? = nil
        if let f = afm.forced {
            switch f { case .available: forced = "available"; case .unsupportedOS: forced = "unsupported"; case .unavailable(let r): forced = r.rawValue }
        }
        return ["status": status, "reason": reason as Any, "forced": forced as Any, "message": afm.message as Any,
                "checkedAt": afm.checkedAt.map { ISO8601DateFormatter().string(from: $0) } as Any,
                "platformSupported": afm.isPlatformSupported]
    }

    private static func windowShot(to path: String, target: String = "main", scale requested: Double? = nil) {
        let main = NSApp.windows.first(where: { $0.contentView != nil && !$0.isSheet })
        let picked: NSWindow?
        switch target {
        case "sheet": picked = main?.attachedSheet
        case "alert": picked = main?.attachedSheet?.attachedSheet
        default: picked = main
        }
        guard let win = picked, let view = win.contentView, let layer = view.layer else {
            write(["ok": false, "error": "no window/layer for target \(target)"], to: path + ".json"); return
        }
        let scale = requested.map { CGFloat($0) } ?? win.backingScaleFactor
        let size = view.bounds.size
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
              let gctx = NSGraphicsContext(bitmapImageRep: rep) else {
            write(["ok": false, "error": "bitmap failed"], to: path + ".json"); return
        }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = gctx
        let cg = gctx.cgContext
        cg.scaleBy(x: scale, y: scale)
        // #2438 M6:視窗／sheet 的材質底(NSVisualEffectView)不會被 layer.render 畫進來,留下透明像素——深色時
        // 白字落在透明底上、看圖軟體顯示成白底白字(10/19 實測 sheet 標題列 alpha=0)。先鋪該視窗外觀下的
        // windowBackgroundColor 當近似底色(只影響截圖,不動任何畫面)。
        win.effectiveAppearance.performAsCurrentDrawingAppearance {
            (win.backgroundColor ?? .windowBackgroundColor).setFill()
            NSRect(origin: .zero, size: size).fill()
        }
        if layer.isGeometryFlipped {
            // 點陣圖 context 原點在左下;SwiftUI hosting 的 layer 幾何是翻轉的,直接 render 會上下顛倒(10/19 實測),先翻。
            cg.translateBy(x: 0, y: size.height); cg.scaleBy(x: 1, y: -1)
        }
        layer.render(in: cg)
        NSGraphicsContext.restoreGraphicsState()
        guard let png = rep.representation(using: .png, properties: [:]) else {
            write(["ok": false, "error": "png failed"], to: path + ".json"); return
        }
        do {
            try png.write(to: URL(fileURLWithPath: path), options: .atomic)
            write(["ok": true, "png": path, "width": rep.pixelsWide, "height": rep.pixelsHigh,
                   "flipped": layer.isGeometryFlipped, "windowFrame": NSStringFromRect(win.frame)], to: path + ".json")
        } catch {
            write(["ok": false, "error": "\(error)"], to: path + ".json")
        }
    }

    private static func write(_ obj: [String: Any], to path: String) {
        guard DebugCommand.isAllowedResultPath(path),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys]) else { return }
        do {
            try data.write(to: URL(fileURLWithPath: path), options: .atomic)
        } catch {
            // #2646 MAS:沙盒版寫不進 /tmp 或家目錄(只有已選的錄音夾有 scope)⇒ 把結果吐到 unified log,
            // 驗證腳本用 `log show --predicate 'subsystem == "tw.uncle.MyParrot.debugctl"'` 讀。單行 JSON,沙盒事故不會害結果消失。
            let compact = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
            Logger(subsystem: "tw.uncle.MyParrot.debugctl", category: "result")
                .notice("\(path, privacy: .public) \(compact, privacy: .public)")
        }
    }
}
#endif
