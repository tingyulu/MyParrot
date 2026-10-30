import Foundation
import MyParrotObjC
import AVFoundation

/// Lightweight self-tests that run under plain Command Line Tools (no Xcode /
/// XCTest required). Exercised by the `MyParrotSelfTest` executable.
public enum SelfTest {

    public struct Result: Sendable {
        public let name: String
        public let passed: Bool
        public let detail: String
    }

    public static func run() -> [Result] {
        [
            fileNameFormat(),
            fileNameFallback(),
            sampleQueueFIFO(),
            drainNoClick(),
            monoResample(),
            stereoSeparation(),
            deviceEnumeration(),
            gainScaling(),
            m4aExport(),
            srtFormat(),
            transcriptWindow(),
            whisperChunkerAndZhTW(),
            whisperHallucinationGate(),
            whisperFileChunking(),
            micInputFormatGuard(),
            micRebuildPolicy(),
            micWatchdogPolicy(),
            bluetoothHoldPolicy(),
            micDevicePolicy(),
            transcriptLoadBaseTime(),
            echoCancel(),
            aecNoEchoGate(),
            sysSilenceWatchdog(),
            btGapFill(),
            warningZhTWPinned(),
            warningAutoDismissRules(),
            quitTranscriptionGuard(),
            correctionRules(),
            correctionListHeight(),   // UI-59
            correctionFocus(),        // UI-60
            srtRoundTrip(),
            correctionPromptAndArgs(),
            correctionParseOutput(),
            // #2418 Codex CLI 後端(案例在 SelfTest+Codex.swift)
            codexRegistry(),
            codexArguments(),
            codexParseOutput(),
            // #2612 逐字稿翻譯(案例在 SelfTest+Translation.swift)
            translationRegistry(),
            translationPlan(),
            translationPromptAndParse(),
            translationSRT(),
            tokenLedger(),   // #2623 TOK-01
            whisperModelSize(),   // BUG-39 CLT-01(案例在 SelfTest+WhisperModel.swift)
            whisperChecksumGate(),   // MAS-12 SHA-256(同檔)
            tapExcludesSelf(),
            debugCommandParsing(),
            caseUpdateVersionCompare(),
            caseUpdateReleaseDecode(),
            caseUpdateSkipLogic(),
            waveformBuckets(),
            waveformCacheRoundTrip(),
            uniqueFileNameProbe(),
            meterScaleMapping(),
            titleSanitize(),
            whisperIdleUnloadPolicy(),
            meetingReminderSelection(),
            dualTimeZoneFormat(),
            firedReminderStore(),
            speechActivityAndAlarms(),
            externalNotifyCommand(),
            cliRecordingProbe(),
            windowFrameClamp(),
            // #2438 UI v2 Phase 1 M1(案例在 SelfTest+UIv2.swift)
            modelRegistryResolution(),
            modelLegacyKeyMigration(),
            modelPrivacyConfirmation(),   // #2438 M6
            minutesMarkdownRender(),
            // #2438 Phase 2(案例在 SelfTest+Minutes.swift)
            minutesPromptAndArgs(),
            minutesParseOutput(),
            minutesRollingRules(),
            paneStateMoveDock(),
            workspaceLayoutResolve(),
            workspaceMinWidthAndRedistribute(),   // UI-47b(2026-10-19 23:4x)
            // #2438 Phase 3a AFM(案例在 SelfTest+AFM.swift)
            afmRegistry(),
            afmTokenEstimate(),
            afmChunk(),
            afmCompressPrevious(),
            afmNotesTail(),
            afmHalvePlan(),
            afmMessageMap(),
            afmCorrectionBatches(),
            // #2483 C 會後重轉接回(案例在 SelfTest+Handoff.swift)
            transcriptHandoffReapply(),
            transcriptHandoffPersist(),
            transcribePolicyMigration(),
            idleTranscribeDecision(),
            // #2438 UI v2 Phase 1 M2(案例在 SelfTest+Notes.swift)
            notesSidecarAndDraft(),
            notesAtomicAutosave(),
            markdownToolbarInsert(),
            markdownEditingBehaviors(),
            markdownHighlightRanges(),
            markdownBlocksParse(),
            sidecarRenamePlan(),
            sidecarTrashAndLock(),
            // #949 第一段(案例在 SelfTest+Lease.swift)
            leaseStateCompat(),
            leaseAcquireRelease(),
            leaseClassify(),
            heartbeatStale(),
            inprogressPathAndPublishName(),
            reapDecisionTable(),
            quarantineInsteadOfDelete(),
            commandLifecycle(),
            // #2646 C2(案例在 SelfTest+Lease.swift)
            protocolDirRules(),
            legacyLeaseFallback(),
            // #2646 MAS-08 商店版純函式(案例在 SelfTest+MAS.swift;兩種建置都要綠)
            masBuildFlavor(),
            masBookmarkStateMachine(),
            masRegistryWithoutCLI(),
            masExternalCommandIgnored()
        ]
    }

    // MARK: - Cases
    // 內部可見(非 private)讓 Swift Testing 套件能逐案例呼叫,避免重複測試邏輯。

    /// TR-27(#976):whisper 閒置釋放的兩個純函式決策——逾時解析與釋放閘。
    /// 覆蓋重點是「什麼時候**不准**釋放」:轉稿中、佇列未空、錄音/暫停中且開著
    /// 即時逐字稿(live 與 file 共用同一份 context)。
    static func whisperIdleUnloadPolicy() -> Result {
        var fails: [String] = []

        // ① 逾時解析:未設定=預設 300;0=停用(nil);正值照用;負值視同未設定。
        if RecordingController.resolveWhisperIdleSec(nil) != 180 { fails.append("未設定應為 180(Eric 10/20 縮到 3 分)") }
        if RecordingController.resolveWhisperIdleSec(0) != nil { fails.append("0 應停用(nil)") }
        if RecordingController.resolveWhisperIdleSec(60) != 60 { fails.append("60 應照用") }
        if RecordingController.resolveWhisperIdleSec(-5) != 180 { fails.append("負值應回預設 180") }

        // ② 釋放閘。
        let can = RecordingController.canUnloadWhisper
        if !can(false, 0, .idle, true) { fails.append("閒置時應可釋放") }
        if !can(false, 0, .finished, true) { fails.append("結束後應可釋放") }
        if can(true, 0, .idle, true) { fails.append("轉稿中不可釋放") }
        if can(false, 2, .idle, true) { fails.append("佇列未空不可釋放") }
        if can(false, 0, .recording, true) { fails.append("錄音中開 live 不可釋放") }
        if can(false, 0, .paused, true) { fails.append("暫停中開 live 不可釋放") }
        // live 關閉時錄音中可以釋放(file 轉稿沒在跑,context 沒人用)。
        if !can(false, 0, .recording, false) { fails.append("錄音中但 live 關閉應可釋放") }

        return Result(name: "TR-27 whisper 閒置釋放策略", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "逾時解析 4 項 + 釋放閘 7 項全過" : fails.joined(separator: ";"))
    }

    static func fileNameFormat() -> Result {
        var c = DateComponents(); c.year = 2026; c.month = 6; c.day = 22; c.hour = 14; c.minute = 30
        let date = Calendar.current.date(from: c)!
        let name = Recording.fileName(date: date, title: "客戶會議-ABC公司")
        let want = "2026-06-22 1430 客戶會議-ABC公司.caf"
        return Result(name: "檔名範本 日期+時間+會議名", passed: name == want,
                      detail: name == want ? name : "得到 \(name)")
    }

    static func fileNameFallback() -> Result {
        let name = Recording.fileName(date: Date(), title: "")
        return Result(name: "空標題 fallback → 錄音", passed: name.hasSuffix("錄音.caf"), detail: name)
    }

    static func sampleQueueFIFO() -> Result {
        let q = SampleQueue()
        q.append([1, 2, 3])
        let a = q.drain(2)           // [1,2]
        let b = q.drain(3)           // [3, 1.5, 0] — pad 從最後真樣本淡出(AUD-29,非硬跳 0)
        let c = q.drain(2)           // [0,0] — 持續飢餓時維持純靜音
        let ok = a == [1, 2] && b.count == 3 && b[0] == 3 && abs(b[1] - 1.5) < 1e-4 && b[2] == 0 && c == [0, 0]
        return Result(name: "SampleQueue FIFO + 靜音補齊(pad 淡出)", passed: ok,
                      detail: ok ? "" : "a=\(a) b=\(b) c=\(c)")
    }

    // AUD-29 / BUG-19:補零接縫 ramp + min 抽取(錄音中不再把零插進連續語音)。
    // ① SampleQueue 進/出 padding 的邊界必須是 ≤rampLength 的線性斜坡(無硬階梯);
    // ② StereoRecorder 兩側都有料時以共同長度抽取 → 檔案中段不得出現全零縫
    //    (舊 max() 行為在 23 分實錄留下 2,171 個微零縫,每個=一次 click)。
    static func drainNoClick() -> Result {
        // ① ramp 邊界:1000 個 0.8 → drain(1240) 尾端 240 pad 淡出;再進料驗淡入。
        let q = SampleQueue()
        q.append([Float](repeating: 0.8, count: 1_000))
        let out = q.drain(1_240)
        var maxStep: Float = 0
        for i in 998..<1_239 { maxStep = max(maxStep, abs(out[i + 1] - out[i])) }
        let fadeOutOK = out[1_239] == 0 && maxStep < 0.02   // 0.8/240≈0.0033;硬跳會是 0.8
        q.append([Float](repeating: 0.8, count: 500))
        let resumed = q.drain(500)
        let fadeInOK = resumed[0] == 0 && abs(resumed[239] - 0.8 * 239 / 240) < 1e-3 && resumed[499] == 0.8
        // ② min 抽取:雙側**等速率**但節奏錯開(mic 0.1s 小塊、system 0.2s 大塊,
        //    模擬三時鐘相位差的抖動)→ 檔案中段不得有任何全零樣本(舊 max() 行為
        //    每 tick 都會把零塞進慢側)。頭(pre-pad+淡入)尾(stop flush pad)排除。
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp_noclick_\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        var interiorZeros = -1
        var window = 0
        do {
            let rec = StereoRecorder()
            try rec.start(url: url)
            for i in 0..<12 {
                rec.feedMic(makeMono(48_000, 4_800, 0.5))                    // 每 0.1s
                if i % 2 == 0 { rec.feedSystem(makeMono(48_000, 9_600, 0.5)) } // 每 0.2s,等速率
                Thread.sleep(forTimeInterval: 0.1)
            }
            Thread.sleep(forTimeInterval: 0.25)
            rec.stop()
            let file = try AVAudioFile(forReading: url)
            let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                       frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buf)
            let n = Int(buf.frameLength)
            let lo = 8_000, hi = n - 12_000    // 排除頭部 pre-pad/淡入與尾部 flush pad
            window = hi - lo
            var zeros = 0
            if let ch = buf.floatChannelData, window > 10_000 {
                for i in lo..<hi where ch[0][i] == 0 || ch[1][i] == 0 { zeros += 1 }
            }
            interiorZeros = window > 10_000 ? zeros : -1   // 檔案太短=測試環境異常,判 fail
        } catch {
            return Result(name: "AUD-29 補零接縫 ramp + min 抽取", passed: false, detail: "\(error)")
        }
        let ok = fadeOutOK && fadeInOK && interiorZeros == 0
        return Result(name: "AUD-29 補零接縫 ramp + min 抽取", passed: ok,
                      detail: String(format: "pad最大階梯=%.4f(<0.02) 淡入首=%.2f 中段全零樣本=%d(要 0,檢查窗 %d)",
                                     maxStep, resumed.first ?? -1, interiorZeros, window))
    }

    static func monoResample() -> Result {
        let conv = MonoDownconverter(sampleRate: 48_000)
        let out = conv.convert(makeMono(48_000 / 2, 2_400, 0.5)) // 0.1s @ 24k
        let ok = out.count > 4_000 && out.count < 5_200          // ~doubles to 48k
        return Result(name: "24k→48k 重採樣", passed: ok, detail: "\(out.count) 取樣")
    }

    static func stereoSeparation() -> Result {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp_selftest_\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let rec = StereoRecorder()
            try rec.start(url: url)
            for _ in 0..<5 {
                rec.feedSystem(makeMono(48_000, 4_800, 0.6))   // 對方 → 左,有訊號
                rec.feedMic(makeMono(48_000, 4_800, 0.0))      // 你 → 右,靜音
                Thread.sleep(forTimeInterval: 0.12)
            }
            Thread.sleep(forTimeInterval: 0.3)
            rec.stop()

            let file = try AVAudioFile(forReading: url)
            guard file.processingFormat.channelCount == 2 else {
                return Result(name: "立體聲分軌(對方左／你右)", passed: false, detail: "非立體聲")
            }
            let buf = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                       frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buf)
            let l = rms(buf, 0), r = rms(buf, 1)
            let ok = l > 0.1 && r < 0.05 && l > r * 5
            return Result(name: "立體聲分軌(對方左／你右)", passed: ok,
                          detail: String(format: "左RMS=%.3f 右RMS=%.3f", l, r))
        } catch {
            return Result(name: "立體聲分軌(對方左／你右)", passed: false, detail: "\(error)")
        }
    }

    // 設定:麥克風裝置列舉(設定面板的裝置下拉資料來源)
    static func deviceEnumeration() -> Result {
        let devices = AudioDevices.inputDevices()
        let names = devices.map { d -> String in
            let tag = d.isBluetooth ? "[藍牙]" : d.isContinuityWireless ? "[Continuity無線]" : d.isContinuityWired ? "[Continuity有線]" : d.isBuiltIn ? "[內建]" : ""
            return d.name + tag
        }.joined(separator: ", ")
        return Result(name: "設定·麥克風裝置列舉(含 transport)", passed: !devices.isEmpty,
                      detail: devices.isEmpty ? "找不到輸入裝置" : "\(devices.count) 個:\(names)")
    }

    // 設定:靈敏度增益(滑桿 0.5–2.0×)+ 軟限幅防破音
    static func gainScaling() -> Result {
        // 線性區:0.25 ×2 = 0.5(未到 0.9 knee,不被壓)
        let lin = makeMono(48_000, 100, 0.25); lin.scale(by: 2.0)
        let l = lin.floatChannelData![0][0]
        // 限幅區:0.9 ×2 = 1.8 必須被壓在 ±1 內(不破音),且仍 > knee
        let loud = makeMono(48_000, 100, 0.9); loud.scale(by: 2.0)
        let c = loud.floatChannelData![0][0]
        let ok = abs(l - 0.5) < 0.0001 && c <= 1.0 && c > 0.9
        return Result(name: "設定·靈敏度增益 ×2 + 軟限幅", passed: ok,
                      detail: String(format: "0.25→%.3f(線性) 0.9×2→%.3f(限幅≤1)", l, c))
    }

    // 停止錄音後 CAF→m4a 自動匯出(app 用的 AVAssetExportSession 路徑)
    static func m4aExport() -> Result {
        let tmp = FileManager.default.temporaryDirectory
        let caf = tmp.appendingPathComponent("mp_exp_\(UUID().uuidString).caf")
        let m4a = caf.deletingPathExtension().appendingPathExtension("m4a")
        defer { try? FileManager.default.removeItem(at: caf); try? FileManager.default.removeItem(at: m4a) }
        do {
            let rec = StereoRecorder()
            try rec.start(url: caf)
            for _ in 0..<5 {
                rec.feedSystem(makeMono(48_000, 4_800, 0.5))
                rec.feedMic(makeMono(48_000, 4_800, 0.3))
                Thread.sleep(forTimeInterval: 0.12)
            }
            Thread.sleep(forTimeInterval: 0.3)
            rec.stop()

            let sem = DispatchSemaphore(value: 0)
            let box = ErrorBox()
            Task { do { try await AudioExport.toM4A(from: caf, to: m4a) } catch { box.error = error }; sem.signal() }
            sem.wait()
            if let e = box.error { return Result(name: "CAF→m4a 匯出", passed: false, detail: "\(e)") }

            let cafSize = (try FileManager.default.attributesOfItem(atPath: caf.path)[.size] as? Int) ?? 0
            let m4aSize = (try FileManager.default.attributesOfItem(atPath: m4a.path)[.size] as? Int) ?? 0
            let valid = (try? AVAudioFile(forReading: m4a)) != nil
            let ok = valid && m4aSize > 0 && m4aSize < cafSize
            return Result(name: "CAF→m4a 匯出(更小且可讀)", passed: ok,
                          detail: "caf=\(cafSize/1024)KB → m4a=\(m4aSize/1024)KB")
        } catch {
            return Result(name: "CAF→m4a 匯出", passed: false, detail: "\(error)")
        }
    }

    // SRT 輸出:時間碼格式、講者前綴、無 duration 時補尾(TR-12/13)
    static func srtFormat() -> Result {
        let lines = [
            TranscriptLine(isYou: false, time: Date(), text: "你好", isFinal: true, start: 0, duration: 1.5),
            TranscriptLine(isYou: true, time: Date(), text: "測試", isFinal: true, start: 2.0, duration: 0)
        ]
        let srt = SRT.make(from: lines)
        let ok = srt.contains("1\n00:00:00,000 --> 00:00:01,500\n對方: 你好")
              && srt.contains("2\n00:00:02,000 --> ")
              && srt.contains("你: 測試")
        return Result(name: "SRT 時間碼+講者格式", passed: ok, detail: ok ? "" : srt)
    }

    // UI-10/BUG-20:「最近 3 分鐘」視窗 — 錨定最後一行、非牆鐘;舊檔均勻時間退化全顯。
    static func transcriptWindow() -> Result {
        let base = Date(timeIntervalSince1970: 1_000_000)
        func line(_ sec: TimeInterval) -> TranscriptLine {
            TranscriptLine(isYou: false, time: base.addingTimeInterval(sec), text: "t\(Int(sec))", isFinal: true, start: sec, duration: 1)
        }
        let spread = [line(0), line(200), line(400), line(500), line(600)]   // 10 分鐘散佈
        let recent = TranscriptWindow.visible(spread, full: false)           // 錨 600 → cutoff 420
        let full = TranscriptWindow.visible(spread, full: true)
        let uniform = [line(300), line(300), line(300)]                      // 舊檔轉稿:同時間
        let uniformRecent = TranscriptWindow.visible(uniform, full: false)
        let empty = TranscriptWindow.visible([], full: false)
        let ok = recent.map(\.text) == ["t500", "t600"] && full.count == 5
              && uniformRecent.count == 3 && empty.isEmpty
        return Result(name: "逐字稿「最近 3 分鐘」視窗(錨最後一行)", passed: ok,
                      detail: ok ? "" : "recent=\(recent.map(\.text)) full=\(full.count) uniform=\(uniformRecent.count)")
    }

    // TR-15/17:Whisper live 的 VAD 切塊(語音+尾靜音→切、短雜訊→丟、6s 強制切)
    // + OpenCC 簡→繁(台灣詞:软件→軟體)。
    static func whisperChunkerAndZhTW() -> Result {
        func block(_ n: Int, _ v: Float) -> [Float] { [Float](repeating: v, count: n) }
        // ① 2s 語音 + 0.8s 靜音 → 切出一塊(含尾靜音、起點 0)
        var ck = VadChunker()
        var chunks = ck.feed(block(32_000, 0.1))
        chunks += ck.feed(block(12_800, 0.0))
        let cutOK = chunks.count == 1 && chunks[0].samples.count == 44_800 && chunks[0].startOffset == 0
        // ② 0.2s 雜訊尖峰 + 靜音 → 丟棄不轉
        var ck2 = VadChunker()
        var c2 = ck2.feed(block(3_200, 0.1))
        c2 += ck2.feed(block(12_800, 0.0))
        let dropOK = c2.isEmpty
        // ③ 連續語音達 6s → 強制切
        var ck3 = VadChunker()
        let c3 = ck3.feed(block(96_000, 0.1))
        let maxOK = c3.count == 1
        // ④ ZhTW s2twp
        let tw = ZhTW.convert("软件质量很好")
        let twOK = tw.contains("軟體") && tw.contains("質")
        let ok = cutOK && dropOK && maxOK && twOK
        return Result(name: "Whisper VAD 切塊 + 簡轉繁", passed: ok,
                      detail: ok ? "切塊/丟雜訊/強制切 OK;软件→\(tw.prefix(2))"
                                 : "cut=\(cutOK) drop=\(dropOK) max=\(maxOK) tw=\(tw)")
    }

    // BUG-21:音樂等非語音音訊有時騙過 no_speech_prob、被 whisper 鎖死複讀同一句
    // (temperature=0 貪婪解碼+每塊音樂內容相似→決定性重複)。同句連續 ≥3 塊才壓下
    // (前兩次仍顯示,不誤殺真實的短句重複,如「對對對」)。
    static func whisperHallucinationGate() -> Result {
        var g = HallucinationGate()
        let r1 = g.check("我會把這張照片放在我的手上。")   // 1st,正常顯示
        let r2 = g.check("我會把這張照片放在我的手上。")   // 2nd,仍顯示(不誤殺短句重複)
        let r3 = g.check("我會把這張照片放在我的手上。")   // 3rd,失控複讀→壓下
        let r4 = g.check("我會把這張照片放在我的手上。")   // 持續壓下
        let r5 = g.check("這是新的一句")                    // 換句 → 恢復顯示
        let ok = r1 && r2 && !r3 && !r4 && r5
        return Result(name: "Whisper 幻覺防呆(連續複讀≥3 次壓下)", passed: ok,
                      detail: ok ? "" : "r1=\(r1) r2=\(r2) r3=\(r3) r4=\(r4) r5=\(r5)")
    }

    // TR-28(#2485):會後重轉改 VAD 分塊——file profile 的切點/起點偏移/25 s 強制切/flush 尾塊,
    // live profile 參數不變;塊內段落起點換算整檔絕對秒數。合成訊號:
    // 10 s 語音｜1 s 靜音｜8 s 語音｜4 s 靜音｜32 s 語音(0.1 s 進料粒度 ⇒ 邊界對齊,數字可精算)。
    static func whisperFileChunking() -> Result {
        func block(_ n: Int, _ v: Float) -> [Float] { [Float](repeating: v, count: n) }
        let r = VadChunker.rate
        var signal: [Float] = []
        signal += block(10 * r, 0.1); signal += block(1 * r, 0); signal += block(8 * r, 0.1)
        signal += block(4 * r, 0); signal += block(32 * r, 0.1)
        var fails: [String] = []
        do {
            let chunks = try WhisperCppFileProvider.chunk(signal)
            // 期望:[0,10.8) 尾靜音切｜[10.8,19.8) 尾靜音切｜19.8～22.8 全靜音丟｜[22.8,47.8) 25 s 強制切｜[47.8,55) flush
            let expect: [(start: Int, count: Int)] = [(0, 172_800), (172_800, 144_000), (364_800, 400_000), (764_800, 115_200)]
            if chunks.count != expect.count {
                fails.append("塊數 \(chunks.count) ≠ \(expect.count)")
            } else {
                for (i, (c, e)) in zip(chunks, expect).enumerated() where c.startOffset != e.start || c.samples.count != e.count {
                    fails.append("塊\(i) 起點 \(c.startOffset)/長 \(c.samples.count) ≠ \(e.start)/\(e.count)")
                }
            }
            if chunks.contains(where: { $0.samples.count > VadChunker.Profile.file.maxChunk }) { fails.append("有塊超過 25 s") }
            if try !WhisperCppFileProvider.chunk(block(8_000, 0.1)).isEmpty { fails.append("<1 s 音訊應略過") }
        } catch { fails.append("chunk 丟錯 \(error)") }
        let live = VadChunker().profile
        if live.silenceCut != 9_600 || live.maxChunk != 96_000 || live.minVoiced != 8_000 || live.idleDrop != 48_000 {
            fails.append("live profile 參數變了")
        }
        let abs = WhisperCppFileProvider.absoluteStart(chunkOffset: 364_800, segStart: 1.25)
        if Swift.abs(abs - 24.05) > 0.001 { fails.append("絕對秒數 \(abs) ≠ 24.05") }
        return Result(name: "TR-28 會後重轉 VAD 分塊(切點/偏移/強制切/flush)", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "4 塊 10.8/9.0/25.0/7.2 s,live 參數不變,絕對時間換算正確" : fails.joined(separator: ";"))
    }

    // UI-58(10/22 截圖抓到):載入舊稿的每句 time 要以錄音起點為基準——起點從檔名範本解析,解不出用 mtime 減時長。
    static func transcriptLoadBaseTime() -> Result {
        var fails: [String] = []
        let cal = Calendar.current
        if let d = Recording.startDate(fromFileName: "2026-10-22 1500 產品週會.m4a") {
            let c = cal.dateComponents([.year, .month, .day, .hour, .minute], from: d)
            if !(c.year == 2026 && c.month == 10 && c.day == 22 && c.hour == 15 && c.minute == 0) { fails.append("檔名解析錯 \(c)") }
        } else { fails.append("檔名範本解析失敗") }
        if Recording.startDate(fromFileName: "錄音.m4a") != nil { fails.append("非範本檔名應回 nil") }
        let end = Date(timeIntervalSince1970: 1_000_000)
        let rec = Recording(id: UUID(), title: "x", url: URL(fileURLWithPath: "/tmp/隨便.m4a"), date: end, duration: 600, hasTranscript: true)
        if abs(rec.startDate.timeIntervalSince1970 - 999_400) > 0.001 { fails.append("fallback 應=mtime−時長") }
        let parsed = SRT.parse("1\n00:00:05,000 --> 00:00:07,000\n你: 測試\n")
        if parsed.first?.start != 5 { fails.append("SRT start 應=5") }
        return Result(name: "UI-58 載入舊稿時間以錄音起點為基準", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "檔名範本→15:00;非範本→nil;fallback=mtime−時長" : fails.joined(separator: ";"))
    }

    // AUD-37(#2523):麥克風輸入格式 guard(取樣率與聲道數都要 >0)+ ObjC 例外橋真的接得到 NSException。
    static func micInputFormatGuard() -> Result {
        var fails: [String] = []
        if !MicCapture.isUsableInputFormat(sampleRate: 48_000, channels: 1) { fails.append("48k/1ch 應可用") }
        if !MicCapture.isUsableInputFormat(sampleRate: 16_000, channels: 2) { fails.append("16k/2ch 應可用") }
        if MicCapture.isUsableInputFormat(sampleRate: 48_000, channels: 0) { fails.append("0 ch 應擋下") }
        if MicCapture.isUsableInputFormat(sampleRate: 0, channels: 1) { fails.append("0 Hz 應擋下") }
        let caught = MPCatchObjCException {
            NSException(name: .invalidArgumentException,
                        reason: "required condition is false: 測試用斷言", userInfo: nil).raise()
        }
        if caught?.reason?.contains("required condition") != true { fails.append("MPCatchObjCException 沒接到 NSException") }
        var ran = false
        if MPCatchObjCException({ ran = true }) != nil || !ran { fails.append("沒例外時應跑完 block 且回 nil") }
        return Result(name: "AUD-37 麥克風格式 guard + ObjC 例外橋", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "0 Hz／0 ch 擋下;NSException 被接住:\(caught?.name.rawValue ?? "")" : fails.joined(separator: ";"))
    }

    // AUD-38(#2529):裝置變更後的偽通知判定、震盪鎖、觀察窗修剪(純函式)。
    static func micRebuildPolicy() -> Result {
        var fails: [String] = []
        if !MicRebuildPolicy.isSpurious(engineRunning: true, currentKey: "24000/1", tapKey: "24000/1") { fails.append("引擎在跑且格式沒變應判偽") }
        if MicRebuildPolicy.isSpurious(engineRunning: false, currentKey: "24000/1", tapKey: "24000/1") { fails.append("引擎停了不可判偽") }
        if MicRebuildPolicy.isSpurious(engineRunning: true, currentKey: "48000/1", tapKey: "24000/1") { fails.append("格式變了不可判偽") }
        let now = Date(timeIntervalSince1970: 1_000_000)
        func ago(_ s: TimeInterval) -> Date { now.addingTimeInterval(-s) }
        let k = "24000/1"
        let recent: [MicRebuildPolicy.Rebuild] = [(at: ago(5), key: k), (at: ago(2), key: k)]
        if !MicRebuildPolicy.shouldLock(history: recent, now: now, key: k, isBluetooth: true) { fails.append("5 秒內同鍵兩次＋藍牙應鎖") }
        let stale: [MicRebuildPolicy.Rebuild] = [(at: ago(25), key: k), (at: ago(25), key: k)]
        if MicRebuildPolicy.shouldLock(history: stale, now: now, key: k, isBluetooth: true) { fails.append("25 秒前的不應算") }
        let mixed: [MicRebuildPolicy.Rebuild] = [(at: ago(5), key: k), (at: ago(2), key: "48000/1")]
        if MicRebuildPolicy.shouldLock(history: mixed, now: now, key: k, isBluetooth: true) { fails.append("不同鍵不應算") }
        if MicRebuildPolicy.shouldLock(history: recent, now: now, key: k, isBluetooth: false) { fails.append("非藍牙不應鎖") }
        if MicRebuildPolicy.shouldLock(history: [(at: ago(2), key: k)], now: now, key: k, isBluetooth: true) { fails.append("只有一筆不應鎖") }
        let pruned = MicRebuildPolicy.prune([(at: ago(25), key: k), (at: ago(21), key: k), (at: ago(20), key: k), (at: ago(1), key: k)], now: now)
        // F2:讀不到或 0 Hz／0 ch 的格式鍵不進紀錄。
        if !MicRebuildPolicy.isRecordable(key: "24000/1") { fails.append("24000/1 應記") }
        for bad in ["", "0/0", "48000/0", "0/1", "abc"] where MicRebuildPolicy.isRecordable(key: bad) { fails.append("「\(bad)」不應記") }
        if pruned.map({ now.timeIntervalSince($0.at) }) != [20, 1] { fails.append("prune 應只留 ≤20 秒的(得 \(pruned.map { now.timeIntervalSince($0.at) }))") }
        return Result(name: "AUD-38 震盪鎖與偽通知", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "偽通知 3 案、震盪鎖 5 案、可記格式鍵 6 案、prune 邊界(20 秒留／21 秒丟)全對" : fails.joined(separator: ";"))
    }

    // AUD-38(#2529):你軌看門狗——計數歸零(連續流動 ≥10 秒)與重建判定(切換中／被鎖不重建)。
    static func micWatchdogPolicy() -> Result {
        var fails: [String] = []
        let now = Date(timeIntervalSince1970: 1_000_000)
        if MicWatchdogPolicy.shouldResetCount(flowSince: now.addingTimeInterval(-3), now: now) { fails.append("流 3 秒不應歸零") }
        if !MicWatchdogPolicy.shouldResetCount(flowSince: now.addingTimeInterval(-11), now: now) { fails.append("流 11 秒應歸零") }
        if MicWatchdogPolicy.shouldResetCount(flowSince: nil, now: now) { fails.append("沒在流不應歸零") }
        func rebuild(_ lastBuf: TimeInterval = 3.5, count: Int = 0, lastRebuild: TimeInterval = 5,
                     switching: Bool = false, locked: Bool = false) -> Bool {
            MicWatchdogPolicy.shouldRebuild(sinceLastBuffer: lastBuf, count: count, sinceLastRebuild: lastRebuild,
                                            switching: switching, locked: locked)
        }
        if !rebuild() { fails.append("3.5 秒無 buffer、count 0、冷卻已過應重建") }
        if rebuild(switching: true) { fails.append("切換中不應重建") }
        if rebuild(locked: true) { fails.append("被鎖不應重建") }
        if rebuild(count: 3) { fails.append("連續 3 次後不應再重建") }
        if rebuild(lastRebuild: 1) { fails.append("冷卻 1 秒不應重建") }
        if rebuild(2.5) { fails.append("2.5 秒無 buffer 不應重建") }
        // F4:切換逾時 20 秒。
        if MicWatchdogPolicy.switchTimedOut(startedAt: now.addingTimeInterval(-19), now: now) { fails.append("切換 19 秒不應逾時") }
        if !MicWatchdogPolicy.switchTimedOut(startedAt: now.addingTimeInterval(-21), now: now) { fails.append("切換 21 秒應逾時") }
        return Result(name: "AUD-38 看門狗計數與重建判定", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "歸零 3 案、重建 6 案、切換逾時 2 案全對" : fails.joined(separator: ";"))
    }

    // AUD-38(#2529):藍牙 HFP 保持器決策——只對藍牙起、格式任一欄變＝HFP 接上;常數釘住。
    static func bluetoothHoldPolicy() -> Result {
        var fails: [String] = []
        if BluetoothHoldPolicy.shouldHold(isBluetooth: false) { fails.append("非藍牙不應起保持器") }
        if !BluetoothHoldPolicy.shouldHold(isBluetooth: true) { fails.append("藍牙應起保持器") }
        let base = BluetoothInputHolder.FormatSnapshot(inRate: 48_000, inCh: 1, outRate: 48_000)
        var inRate = base; inRate.inRate = 24_000
        var inCh = base; inCh.inCh = 2
        var outRate = base; outRate.outRate = 24_000
        if !BluetoothHoldPolicy.settled(baseline: base, now: inRate) { fails.append("輸入取樣率變了應算接上") }
        if !BluetoothHoldPolicy.settled(baseline: base, now: inCh) { fails.append("輸入聲道數變了應算接上") }
        if !BluetoothHoldPolicy.settled(baseline: base, now: outRate) { fails.append("輸出取樣率變了應算接上") }
        if BluetoothHoldPolicy.settled(baseline: base, now: base) { fails.append("全同不應算接上") }
        if BluetoothHoldPolicy.settleTimeout != 1.5 { fails.append("settleTimeout 應為 1.5(得 \(BluetoothHoldPolicy.settleTimeout))") }
        if BluetoothHoldPolicy.pollInterval != 0.1 { fails.append("pollInterval 應為 0.1(得 \(BluetoothHoldPolicy.pollInterval))") }
        return Result(name: "AUD-38 藍牙保持器決策", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "shouldHold 2 案、settled 4 案、常數 2 案全對" : fails.joined(separator: ";"))
    }

    // AUD-39(#2529／BUG-35):建引擎前「系統預設輸入是否已穩定」與「保持器 baseline 已是 HFP」的純決策。
    static func micDevicePolicy() -> Result {
        var fails: [String] = []
        let ids: [AudioDeviceID] = [41, 77, 93]
        if !MicDevicePolicy.defaultInputSettled(defaultID: 41, deviceIDs: ids, removedID: 93) { fails.append("預設在清單且≠移除應穩定") }
        if MicDevicePolicy.defaultInputSettled(defaultID: 93, deviceIDs: ids, removedID: 93) { fails.append("預設＝移除那顆不應穩定") }
        if MicDevicePolicy.defaultInputSettled(defaultID: 55, deviceIDs: ids, removedID: nil) { fails.append("預設不在清單不應穩定") }
        if MicDevicePolicy.defaultInputSettled(defaultID: 41, deviceIDs: [], removedID: nil) { fails.append("清單空不應穩定") }
        typealias Snap = BluetoothInputHolder.FormatSnapshot
        if !BluetoothHoldPolicy.alreadyHFP(Snap(inRate: 24_000, inCh: 1, outRate: 24_000)) { fails.append("24000/1/24000 應是已 HFP") }
        if BluetoothHoldPolicy.alreadyHFP(Snap(inRate: 48_000, inCh: 1, outRate: 48_000)) { fails.append("48000/1/48000 不是 HFP") }
        if BluetoothHoldPolicy.alreadyHFP(Snap(inRate: 24_000, inCh: 1, outRate: 48_000)) { fails.append("輸入 24000、輸出 48000 不算已 HFP") }
        if BluetoothHoldPolicy.settleTimeout != 1.5 { fails.append("保持器 settleTimeout 應為 1.5(得 \(BluetoothHoldPolicy.settleTimeout))") }
        return Result(name: "AUD-39 預設輸入穩定與已 HFP 判定", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "defaultInputSettled 4 案、alreadyHFP 3 案、settleTimeout 1.5 全對" : fails.joined(separator: ";"))
    }

    private final class ErrorBox: @unchecked Sendable { var error: Error? }

    // AUD-16/23 合成驗證 Path A「先對齊再消」:echo = 0.35·ref[i-D],D=100ms(遠超
    // 濾波器,須先估延遲對齊才消得掉;舊版用 64 樣本/1.3ms 太短=假過關)。
    // 流程:DelayEstimator 估 D → 平移對齊 → EchoCanceller 消 → 驗回音衰減+人聲保留。
    static func echoCancel() -> Result {
        let n = 48_000, d = 4_800           // 1s @48k,回音延遲 100ms
        var seed: UInt32 = 12_345
        func rnd() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 24) * 2 - 1 }
        var ref = [Float](repeating: 0, count: n), echo = [Float](repeating: 0, count: n)
        var voice = [Float](repeating: 0, count: n), near = [Float](repeating: 0, count: n)
        for i in 0..<n { ref[i] = rnd() * 0.5 }
        for i in d..<n { echo[i] = 0.35 * ref[i - d] }           // speaker→mic echo @100ms
        // 你 silent first half (對方 alone → filter converges), then double-talk.
        for i in (n / 2)..<n { voice[i] = 0.25 * sinf(2 * Float.pi * 1000 * Float(i) / 48_000) }
        for i in 0..<n { near[i] = echo[i] + voice[i] }

        // 1) 估 bulk delay
        let (estD, peak) = DelayEstimator.estimate(near: near, ref: ref, maxLag: 12_000)
        let delayOK = abs(estD - d) <= 64 && peak > 0.2
        // 2) 平移對齊(留 5ms guard)再消
        let shift = max(0, estD - 240)
        var aligned = [Float](repeating: 0, count: n)
        for i in 0..<n { let j = i - shift; if j >= 0 { aligned[i] = ref[j] } }
        let out = EchoCanceller(taps: 2_048, mu: 0.3, doubleTalkThreshold: 0.5, holdSamples: 2_400).process(near: near, ref: aligned)

        func atten(_ lo: Int, _ hi: Int) -> Float {
            var resid: Float = 0, orig: Float = 0
            for i in lo..<hi { let r = out[i] - voice[i]; resid += r * r; orig += echo[i] * echo[i] }
            return 10 * log10f(max(orig, 1e-12) / max(resid, 1e-12))
        }
        let a2 = atten(n / 2, n)                  // double-talk region
        var vpow: Float = 0, opow: Float = 0
        for i in (n / 2)..<n { vpow += voice[i] * voice[i]; opow += out[i] * out[i] }
        let voiceKept = opow / max(vpow, 1e-12)
        let ok = delayOK && a2 >= 12 && voiceKept > 0.5 && voiceKept < 2.0
        return Result(name: "回音消除:大延遲對齊+NLMS(合成)", passed: ok,
                      detail: String(format: "估延遲 %d(真 %d)相關%.2f / 雙講衰減 %.1f dB,人聲保留 %.2f×", estD, d, peak, a2, voiceKept))
    }

    // AUD-25 無回音 gate:near = 純人聲(與 ref 不相關、無喇叭回音)→ 左右軌相關度
    // 低於門檻 → 離線 AEC 會略過、不傷人聲(戴耳機情境)。
    static func aecNoEchoGate() -> Result {
        let n = 48_000
        var seed: UInt32 = 777
        func rnd() -> Float { seed = seed &* 1_664_525 &+ 1_013_904_223; return Float(seed >> 8) / Float(1 << 24) * 2 - 1 }
        var ref = [Float](repeating: 0, count: n), near = [Float](repeating: 0, count: n)
        for i in 0..<n { ref[i] = rnd() * 0.5 }                                          // 對方(系統音)
        for i in 0..<n { near[i] = 0.3 * sinf(2 * Float.pi * 700 * Float(i) / 48_000) }  // 你:純人聲,無回音
        let (_, peak) = DelayEstimator.estimate(near: near, ref: ref, maxLag: 12_000)
        let ok = peak < 0.10                                                             // 低於門檻 → gate 略過
        return Result(name: "AEC 無回音 gate(戴耳機略過)", passed: ok,
                      detail: String(format: "左右軌相關 %.3f < 0.10 → 略過 AEC", peak))
    }

    /// BUG-24:對方軌看門狗改「訊號式」後,要能偵測「開頭有聲、中途才死」(BUG-24 實例的
    /// 藍牙 HFP 情境:tap 一直送 buffer 但全零)。這裡驗純決策邏輯 `SysTrackWatchdog`:
    /// ① 中途死(距訊號 12s)→ 跳警告;② 自然短停頓(2s)→ 不跳;③ 舊單調 peak 邏輯
    /// 會漏掉的「開頭有聲後全零」→ 新邏輯抓得到;④ 重建上限(3 次)對「流動但全零」
    /// 也真的成立(距 buffer 仍新鮮、但持續真靜音超過門檻仍會嘗試,達上限即停)。
    static func sysSilenceWatchdog() -> Result {
        let warnAfter: TimeInterval = 12, silentRebuild: TimeInterval = 20
        // ① 中途死:錄了 200s、距最後訊號 13s、還沒警告 → 該警告
        let midDeath = SysTrackWatchdog.shouldWarnSilent(elapsed: 200, silentFor: 13, alreadyWarned: false, warnAfter: warnAfter)
        // ② 自然短停頓 2s → 不該警告
        let shortPause = SysTrackWatchdog.shouldWarnSilent(elapsed: 200, silentFor: 2, alreadyWarned: false, warnAfter: warnAfter)
        // ③ 已警告過就不重複洗版
        let noRepeat = SysTrackWatchdog.shouldWarnSilent(elapsed: 200, silentFor: 60, alreadyWarned: true, warnAfter: warnAfter)
        // ④ 重建:buffer 仍新鮮(1s,沒停流)但持續真靜音 25s → 仍應嘗試重建(BUG-24 關鍵:
        //    舊邏輯只看 buffer 新鮮度會判「活著」而完全不重建)
        let rebuildOnSilent = SysTrackWatchdog.shouldRebuild(bufferStaleFor: 1, silentFor: 25, rebuildCount: 0, sinceLastRebuild: 5, deadAfter: 5, silentAfter: silentRebuild, cooldown: 2, maxRebuilds: 3, rebuilding: false)
        // ⑤ 達上限即停(rebuildCount=3)
        let capHolds = !SysTrackWatchdog.shouldRebuild(bufferStaleFor: 1, silentFor: 25, rebuildCount: 3, sinceLastRebuild: 5, deadAfter: 5, silentAfter: silentRebuild, cooldown: 2, maxRebuilds: 3, rebuilding: false)
        // ⑥ 冷卻中不重建(距上次重建僅 1s < 2s)
        let cooldownHolds = !SysTrackWatchdog.shouldRebuild(bufferStaleFor: 1, silentFor: 25, rebuildCount: 0, sinceLastRebuild: 1, deadAfter: 5, silentAfter: silentRebuild, cooldown: 2, maxRebuilds: 3, rebuilding: false)
        // ⑦⑧ AUD-39:重建進行中(tap 正在佇列上拆建)不再觸發——不論是 buffer 停流還是持續靜音。
        let rebuildingHoldsStale = !SysTrackWatchdog.shouldRebuild(bufferStaleFor: 10, silentFor: 0, rebuildCount: 0, sinceLastRebuild: 5, deadAfter: 5, silentAfter: silentRebuild, cooldown: 2, maxRebuilds: 3, rebuilding: true)
        let rebuildingHoldsSilent = !SysTrackWatchdog.shouldRebuild(bufferStaleFor: 1, silentFor: 25, rebuildCount: 0, sinceLastRebuild: 5, deadAfter: 5, silentAfter: silentRebuild, cooldown: 2, maxRebuilds: 3, rebuilding: true)
        let timeoutPinned = SysTrackWatchdog.rebuildTimeout == 20   // AUD-39 D(G4)
        // ⑨ AUD-40:buffer 停流時——輸出裝置閒置 ⇒ 略過;在跑或讀不到 ⇒ 重建。
        let idleSkips = SysTrackWatchdog.staleAction(outputRunning: false) == .skipIdle
        let runningRebuilds = SysTrackWatchdog.staleAction(outputRunning: true) == .rebuild
        let unknownRebuilds = SysTrackWatchdog.staleAction(outputRunning: nil) == .rebuild
        let ok = midDeath && !shortPause && !noRepeat && rebuildOnSilent && capHolds && cooldownHolds
            && rebuildingHoldsStale && rebuildingHoldsSilent && timeoutPinned
            && idleSkips && runningRebuilds && unknownRebuilds
        return Result(name: "BUG-24 對方軌流動但全零看門狗", passed: ok,
                      detail: "中途死警告=\(midDeath) 短停頓靜音=\(shortPause) 已警告不重複=\(noRepeat) 靜音重建=\(rebuildOnSilent) 上限=\(capHolds) 冷卻=\(cooldownHolds) 重建中停流不觸發=\(rebuildingHoldsStale) 重建中靜音不觸發=\(rebuildingHoldsSilent) 重建逾時 20 秒=\(timeoutPinned) 閒置略過=\(idleSkips) 在跑重建=\(runningRebuilds) 讀不到重建=\(unknownRebuilds)")
    }

    /// BUG-25:藍牙輸出時鐘抖動讓 IOProc 漏拍,漏掉的樣本使左軌波形跳接=滿軌破音
    /// (BUG-25 實例:對方軌爆點率 4.95% vs 你軌 0.93%)。驗缺口偵測純函式
    /// `SystemAudioCapture.gapFrames`:①連續無縫→0 ②時間戳 rounding 級抖動(≤32)→0
    /// ③真缺口→精確幀數 ④>2s 巨跳(裝置切換/重建,時間軸不連續)→0 不灌靜音
    /// ⑤首拍未播種→0 ⑥時鐘倒退(重啟)→0;並驗 silenceBuffer 產出正確幀數的全零 buffer。
    static func btGapFill() -> Result {
        let contig  = SystemAudioCapture.gapFrames(expected: 48_000, now: 48_000) == 0
        let jitter  = SystemAudioCapture.gapFrames(expected: 48_000, now: 48_020) == 0
        let real    = SystemAudioCapture.gapFrames(expected: 48_000, now: 52_800) == 4_800
        let huge    = SystemAudioCapture.gapFrames(expected: 48_000, now: 300_000) == 0
        let unseed  = SystemAudioCapture.gapFrames(expected: -1, now: 48_000) == 0
        let rewind  = SystemAudioCapture.gapFrames(expected: 48_000, now: 10_000) == 0
        var silence = false
        if let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2),
           let buf = SystemAudioCapture.silenceBuffer(format: fmt, frames: 4_800),
           let ch = buf.floatChannelData {
            silence = buf.frameLength == 4_800
                && (0..<4_800).allSatisfy { ch[0][$0] == 0 && ch[1][$0] == 0 }
        }
        let ok = contig && jitter && real && huge && unseed && rewind && silence
        return Result(name: "BUG-25 藍牙漏拍缺口補靜音", passed: ok,
                      detail: "無縫=\(contig) 抖動=\(jitter) 真缺口=\(real) 巨跳=\(huge) 未播種=\(unseed) 倒退=\(rewind) 靜音buffer=\(silence)")
    }

    // UPD-01:版號解析/比較純函式 `isNewer(remoteTag:localVersion:)`——表驅動涵蓋
    // v 前綴、雙位數段(字串比較會錯的雷:"0.10" < "0.9")、補 0 等值("0.3"=="0.3.0")、
    // 非數字段(如 "-beta")→ nil(dev build/怪異 tag 一律不判斷,不誤報)。
    static func caseUpdateVersionCompare() -> Result {
        let cases: [(remote: String, local: String, want: Bool?)] = [
            ("v0.3.0", "0.2.0", true),
            ("0.2.0", "0.2.0", false),
            ("v0.2.1", "0.2.0", true),
            ("0.10.0", "0.9.9", true),
            ("0.3", "0.3.0", false),
            ("0.2.0", "0.3.0", false),
            ("abc", "0.2.0", nil),
            ("v1.0.0-beta", "1.0.0", nil)
        ]
        var failures: [String] = []
        for c in cases {
            let got = isNewer(remoteTag: c.remote, localVersion: c.local)
            if got != c.want { failures.append("(\(c.remote),\(c.local))→\(String(describing: got)),want \(String(describing: c.want))") }
        }
        return Result(name: "UPD-01 版號解析/比較(v 前綴/補 0/非數字段)", passed: failures.isEmpty,
                      detail: failures.isEmpty ? "" : failures.joined(separator: "; "))
    }

    // UPD-02:releases/latest JSON decode——fixture 用真實 v0.2.0 回應子集+多餘欄位,
    // 驗證 GitHubRelease 容忍未知欄位(Decodable 預設行為,但明確驗證鎖住)。
    static func caseUpdateReleaseDecode() -> Result {
        let json = """
        {
          "tag_name": "v0.2.0",
          "html_url": "https://github.com/tingyulu/MyParrot/releases/tag/v0.2.0",
          "name": "v0.2.0",
          "prerelease": false,
          "draft": false,
          "published_at": "2026-07-11T12:00:00Z",
          "assets": [{"browser_download_url": "https://example.com/x.zip"}]
        }
        """
        do {
            let release = try JSONDecoder().decode(GitHubRelease.self, from: Data(json.utf8))
            let ok = release.tagName == "v0.2.0"
                && release.htmlURL.absoluteString == "https://github.com/tingyulu/MyParrot/releases/tag/v0.2.0"
            return Result(name: "UPD-02 GitHubRelease decode(容忍未知欄位)", passed: ok,
                          detail: ok ? "" : "tagName=\(release.tagName) htmlURL=\(release.htmlURL)")
        } catch {
            return Result(name: "UPD-02 GitHubRelease decode(容忍未知欄位)", passed: false, detail: "\(error)")
        }
    }

    // UPD-03:略過此版邏輯 `shouldPresentBanner`——skip 後同版(用 AppVersion 等值比,
    // 非字串)不提示,更新的下一版照常提示,無 skip 記錄照常提示。
    static func caseUpdateSkipLogic() -> Result {
        let a = shouldPresentBanner(remoteTag: "v0.3.0", skipped: "0.3.0")   // 同版→不提示
        let b = shouldPresentBanner(remoteTag: "v0.4.0", skipped: "0.3.0")  // 更新版→提示
        let c = shouldPresentBanner(remoteTag: "v0.3.0", skipped: nil)      // 無 skip→提示
        let ok = !a && b && c
        return Result(name: "UPD-03 略過此版邏輯", passed: ok,
                      detail: ok ? "" : "同版=\(a)(要 false) 新版=\(b)(要 true) 無skip=\(c)(要 true)")
    }

    // MARK: - Helpers

    // UI-28b:波形分析——前半只有左聲道有音、後半只有右聲道;驗桶的分佈、正規化、
    // 分段讀檔不讀過檔尾、downsample 取最大值。
    static func waveformBuckets() -> Result {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp_wave_\(UUID().uuidString).caf")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let fmt = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
            let frames = 48_000 * 2 + 12_345          // 2.26 秒,故意不是 chunk 的整數倍
            // 寫檔收在閉包裡:AVAudioFile 寫入端要 deinit 才會把尾端 flush 進檔頭,
            // 否則同 scope 立刻讀回會少最後一段(實測少 1,785 frames)。
            try {
                let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
                let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
                buf.frameLength = AVAudioFrameCount(frames)
                let l = buf.floatChannelData![0], r = buf.floatChannelData![1]
                for i in 0..<frames {
                    let t = Float(i) / 48_000
                    let tone = sinf(2 * .pi * 440 * t)
                    l[i] = i < frames / 2 ? tone * 0.5 : 0
                    r[i] = i < frames / 2 ? 0 : tone * 0.25
                }
                try file.write(from: buf)
            }()
            let w = try WaveformAnalyzer.analyze(url: url, buckets: 40, chunkFrames: 8_192)
            let lFront = w.left[0..<18].min() ?? 0, lBack = w.left[22..<40].max() ?? 1
            let rFront = w.right[0..<18].max() ?? 1, rBack = w.right[22..<40].min() ?? 0
            let peakIsOne = abs((w.left.max() ?? 0) - 1) < 0.01
            let halfRight = abs((w.right.max() ?? 0) - 0.5) < 0.05   // 右=左的一半,共用最大值正規化
            let ds = w.downsampled(to: 10)
            let dsOK = ds.bucketCount == 10 && abs((ds.left.max() ?? 0) - 1) < 0.01
            let ok = lFront > 0.9 && lBack < 0.01 && rFront < 0.01 && rBack > 0.45
                && peakIsOne && halfRight && dsOK && abs(w.duration - Double(frames) / 48_000) < 0.01
            return Result(name: "波形桶(左前半/右後半/正規化/downsample)", passed: ok,
                          detail: String(format: "L前=%.2f L後=%.3f R前=%.3f R後=%.2f dur=%.2f ds=%d",
                                         lFront, lBack, rFront, rBack, w.duration, ds.bucketCount))
        } catch {
            return Result(name: "波形桶(左前半/右後半/正規化/downsample)", passed: false, detail: "\(error)")
        }
    }

    // UI-28c:波形快取落檔——round-trip、key 隨 mtime 變、損毀檔回 nil。
    static func waveformCacheRoundTrip() -> Result {
        let tmp = FileManager.default.temporaryDirectory
        let dir = tmp.appendingPathComponent("mp_wcache_\(UUID().uuidString)", isDirectory: true)
        let audio = tmp.appendingPathComponent("mp_wcache_\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: dir); try? FileManager.default.removeItem(at: audio) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data(repeating: 7, count: 1024).write(to: audio)
            let w = Waveform(left: [0, 0.5, 1], right: [1, 0.25, 0], duration: 3.5)
            guard WaveformCache.save(w, for: audio, in: dir) else {
                return Result(name: "波形快取落檔(round-trip/失效/損毀)", passed: false, detail: "save 失敗")
            }
            let back = WaveformCache.load(for: audio, in: dir)
            let roundTrip = back == w
            let key1 = WaveformCache.key(for: audio)
            // 改 mtime(往前 100 秒)→ key 變 → 舊快取讀不到
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -100)], ofItemAtPath: audio.path)
            let key2 = WaveformCache.key(for: audio)
            let invalidated = key1 != key2 && WaveformCache.load(for: audio, in: dir) == nil
            // 損毀 json → nil
            try Data("{not json".utf8).write(to: WaveformCache.fileURL(for: key2!, in: dir))
            let corruptNil = WaveformCache.load(for: audio, in: dir) == nil
            let missingNil = WaveformCache.key(for: dir.appendingPathComponent("nope.m4a")) == nil
            let ok = roundTrip && invalidated && corruptNil && missingNil
            return Result(name: "波形快取落檔(round-trip/失效/損毀)", passed: ok,
                          detail: "roundTrip=\(roundTrip) invalidated=\(invalidated) corruptNil=\(corruptNil) missingNil=\(missingNil)")
        } catch {
            return Result(name: "波形快取落檔(round-trip/失效/損毀)", passed: false, detail: "\(error)")
        }
    }

    // #892:同分鐘同標題防覆蓋——空目錄照範本;有 X.caf → X 2;有 X.m4a + X 2.txt → X 3。
    static func uniqueFileNameProbe() -> Result {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp_uniq_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            var c = DateComponents(); c.year = 2026; c.month = 8; c.day = 23; c.hour = 16; c.minute = 55
            let date = Calendar.current.date(from: c)!
            let a = Recording.uniqueFileName(date: date, title: "", in: dir)
            let emptyOK = a == "2026-08-23 1655 錄音.caf"
            try Data().write(to: dir.appendingPathComponent("2026-08-23 1655 錄音.caf"))
            let b = Recording.uniqueFileName(date: date, title: "", in: dir)
            let secondOK = b == "2026-08-23 1655 錄音 2.caf"
            try FileManager.default.removeItem(at: dir.appendingPathComponent("2026-08-23 1655 錄音.caf"))
            try Data().write(to: dir.appendingPathComponent("2026-08-23 1655 錄音.m4a"))   // 已轉檔的舊錄音
            try Data().write(to: dir.appendingPathComponent("2026-08-23 1655 錄音 2.txt"))  // 只剩逐字稿也算佔用
            let cName = Recording.uniqueFileName(date: date, title: "", in: dir)
            let thirdOK = cName == "2026-08-23 1655 錄音 3.caf"
            let ok = emptyOK && secondOK && thirdOK
            return Result(name: "同分鐘同標題防覆蓋(後綴 2/3)", passed: ok, detail: "\(a) | \(b) | \(cName)")
        } catch {
            return Result(name: "同分鐘同標題防覆蓋(後綴 2/3)", passed: false, detail: "\(error)")
        }
    }

    // 電平表 dB 刻度:−60 dBFS→0、−12 dBFS(value 1)→1、一般語音 −28 dBFS(0.16)→~0.67、
    // 靜音門檻以下 0、有訊號至少 1 段、單調遞增。
    static func meterScaleMapping() -> Result {
        func v(_ dbfs: Float) -> Float { powf(10, dbfs / 20) * 4 }
        let zero = MeterScale.fraction(0) == 0 && MeterScale.fraction(v(-70)) == 0
        let floor = abs(MeterScale.fraction(v(-50))) < 0.01
        let top = abs(MeterScale.fraction(1.0) - 1) < 0.01
        let speech = MeterScale.fraction(0.16)
        let speechOK = speech > 0.55 && speech < 0.62
        let seg20 = MeterScale.segments(0.16, of: 20), seg8 = MeterScale.segments(0.16, of: 8)
        let segOK = seg20 == 12 && seg8 == 5
        let noise = MeterScale.segments(v(-53), of: 20) == 1   // Yeti 底噪(Eric 22:28 實測 3/20)→ 只亮 1 段
        let minOne = noise && MeterScale.segments(0.006, of: 20) == 1 && MeterScale.segments(0.004, of: 20) == 0
        let mono = (1...100).map { MeterScale.fraction(Float($0) / 100) }
        let monotone = zip(mono, mono.dropFirst()).allSatisfy { $0 <= $1 }
        let ok = zero && floor && top && speechOK && segOK && minOne && monotone
        return Result(name: "電平表 dB 刻度(−50…−12 dBFS)", passed: ok,
                      detail: String(format: "speech=%.2f seg20=%d seg8=%d floor=%@ top=%@ mono=%@", speech, seg20, seg8,
                                     floor ? "ok" : "x", top ? "ok" : "x", monotone ? "ok" : "x"))
    }

    // v0.3.1:標題去路徑語意——`/` `:` → `-`、控制字元去掉、前後空白與點去掉、空 → 錄音、
    // 長標題截在 120 bytes 且不切壞 UTF-8。
    static func titleSanitize() -> Result {
        let a = Recording.sanitizeTitle("會議/客戶: A") == "會議-客戶- A"
        let b = Recording.sanitizeTitle("../../etc") == "..-..-etc".trimmingCharacters(in: CharacterSet(charactersIn: ".")) // → "-..-etc"
        let c = Recording.sanitizeTitle("  ..  ") == "錄音"
        let d = Recording.sanitizeTitle("a\u{0}b\tc") == "abc"
        let long = Recording.sanitizeTitle(String(repeating: "繁", count: 60))   // 180 bytes → 截到 ≤120
        let e = long.utf8.count <= 120 && long.utf8.count >= 118 && long.allSatisfy { $0 == "繁" }
        let f = Recording.fileName(date: Date(), title: "x/y").hasSuffix(" x-y.caf")
        let ok = a && b && c && d && e && f
        return Result(name: "標題去路徑語意(/ : .. 控制字元/長度)", passed: ok,
                      detail: "a=\(a) b=\(b) c=\(c) d=\(d) e=\(e) f=\(f)")
    }

    private static func makeMono(_ sampleRate: Double, _ frames: Int, _ value: Float) -> AVAudioPCMBuffer {
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                channels: 1, interleaved: false)!
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames))!
        buf.frameLength = AVAudioFrameCount(frames)
        let ch = buf.floatChannelData![0]
        for i in 0..<frames { ch[i] = value }
        return buf
    }

    /// UI-36(BUG-28/#1680):結構化警示的繁中整句必須跟改版前寫死的字串**逐字相同**
    /// ——CLI、state.json、終端電平表都還在讀這個(`deviceChangeWarning`),繁中 GUI
    /// 也是查表查不到而回傳同一份模板。期望值是從 commit 8a84306 的原始碼抄進來的。
    static func warningZhTWPinned() -> Result {
        let expected: [(RecordingWarning, String)] = [
            (.engineChangeDeferred, "逐字稿引擎將於本次錄音結束後生效"),
            (.whisperModelMissing, "Whisper 模型未安裝 — 到設定下載後生效,暫用 macOS 原生引擎"),
            (.cloudNotConfigured, "雲端引擎尚未設定,暫用 macOS 原生引擎"),
            (.micSwitched(device: "Yeti Stereo Microphone"),
             "已切換麥克風為「Yeti Stereo Microphone」,你軌(右)會有短暫空白"),
            (.micSwitchFailed(device: "Yeti Stereo Microphone"),
             "⚠️ 切換到「Yeti Stereo Microphone」失敗、原麥克風也起不來,你軌(右)現在收不到音 — 請停止錄音、重選裝置再錄"),
            (.micReconnected(reason: .signalLost, device: "Yeti Stereo Microphone"),
             "偵測到你的麥克風中斷(你軌訊號中斷),已自動重接「Yeti Stereo Microphone」"),
            (.micReconnected(reason: .deviceRemoved, device: nil),
             "偵測到你的麥克風中斷(選用的麥克風已移除),已自動重接「系統預設」"),
            (.sysRebuildMaybeStillSilent,
             "已嘗試自動重建對方軌,但可能仍收不到 — 若用藍牙耳機當輸出會走 HFP/電話模式而擷取不到,請改用內建喇叭或有線輸出"),
            (.sysRestarted(reason: .signalLost), "偵測到系統音訊擷取中斷(對方軌訊號中斷),已自動重新啟動"),
            (.sysRestarted(reason: .persistentSilence), "偵測到系統音訊擷取中斷(對方軌持續無聲),已自動重新啟動"),
            (.sysRestarted(reason: .outputDeviceChanged), "偵測到系統音訊擷取中斷(系統輸出裝置變更),已自動重新啟動"),
            (.micSilentBluetooth,
             "⚠️ 你選的是藍牙麥克風,整場可能收不到聲音(常被會議 app 佔住或掉窄頻)— 請到設定改用內建或 USB 麥克風"),
            // AUD-38(#2529)新增,期望值＝工單 §7 的模板(不在 8a84306 裡)。
            (.micBluetoothUnstable(device: "AirPods Pro"),
             "⚠️ 藍牙麥克風「AirPods Pro」在此系統無法穩定擷取（HFP 格式反覆切換），你軌（右）已停止自動重建 — 請切回內建或有線麥克風"),
            (.micSilent, "你的麥克風似乎沒收到聲音 — 請到設定確認「你的麥克風」選對裝置"),
            (.sysSilent,
             "⚠️ 對方(系統音訊)沒收到聲音 — 若用藍牙耳機當輸出,通話會走 HFP/電話模式而擷取不到對方,請改用內建喇叭或有線輸出;並確認會議音訊在這台 Mac 上播放"),
            (.deviceChanged, "偵測到音訊裝置變更,錄音續行中,請確認狀態")
        ]
        var fails: [String] = []
        for (w, want) in expected where w.zhTW != want {
            fails.append("\(want.prefix(12))… → \(w.zhTW.prefix(12))…")
        }
        // 模板的佔位符數量要跟參數個數一致,否則 UI 會顯示殘缺字串。
        for (w, _) in expected where L10nFormat.placeholderCount(w.template) != w.arguments.count {
            fails.append("佔位符數不符:\(w.template.prefix(12))…")
        }
        // 參數少給時不可當機,多餘的佔位符原樣留著(UI 端會因此退回繁中模板)。
        let short = L10nFormat.fill("偵測到你的麥克風中斷(%@),已自動重接「%@」", ["你軌訊號中斷"])
        if short != "偵測到你的麥克風中斷(你軌訊號中斷),已自動重接「%@」" { fails.append("少給參數:\(short)") }
        return Result(name: "UI-36 警示繁中原文釘字(BUG-28)", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "\(expected.count) 句逐字相同 + 佔位符數一致"
                                            : fails.joined(separator: ";"))
    }

    /// UI-41(BUG-28/B2+題 C):自動收起與再跳門檻的純決策。
    static func warningAutoDismissRules() -> Result {
        var fails: [String] = []
        // ① 只有對方軌無聲那兩種會被聲音收掉。
        let clears: [RecordingWarning] = [.sysSilent, .sysRebuildMaybeStillSilent]
        let keeps: [RecordingWarning] = [
            .engineChangeDeferred, .whisperModelMissing, .cloudNotConfigured,
            .micSwitched(device: "X"), .micSwitchFailed(device: "X"),
            .micReconnected(reason: .signalLost, device: "X"),
            .sysRestarted(reason: .persistentSilence),
            .micSilentBluetooth, .micBluetoothUnstable(device: "X"), .micSilent, .deviceChanged
        ]
        for w in clears where !w.clearsWhenSysSignalReturns { fails.append("該收沒收:\(w.template.prefix(8))") }
        for w in keeps where w.clearsWhenSysSignalReturns { fails.append("不該收卻收:\(w.template.prefix(8))") }
        if clears.count + keeps.count != 13 { fails.append("警示種類數變了,案例要補") }

        // ② 再跳門檻:沒自動收起過照舊 12 秒且看 silentFor;收起過改看真訊號與 60 秒。
        let before = SysTrackWatchdog.silentWarnInputs(autoDismissed: false, silentFor: 13,
                                                       realSilentFor: 99, warnAfter: 12, rewarnAfter: 60)
        if before.silentFor != 13 || before.warnAfter != 12 { fails.append("收起前門檻不對") }
        let after = SysTrackWatchdog.silentWarnInputs(autoDismissed: true, silentFor: 25,
                                                      realSilentFor: 40, warnAfter: 12, rewarnAfter: 60)
        if after.silentFor != 40 || after.warnAfter != 60 { fails.append("收起後門檻不對") }
        // 收起後安靜 40 秒(但重建把 silentFor 洗成 25)不該跳;滿 60 秒才跳。
        if SysTrackWatchdog.shouldWarnSilent(elapsed: 300, silentFor: after.silentFor,
                                             alreadyWarned: false, warnAfter: after.warnAfter) {
            fails.append("收起後 40 秒就跳了")
        }
        let due = SysTrackWatchdog.silentWarnInputs(autoDismissed: true, silentFor: 5,
                                                    realSilentFor: 61, warnAfter: 12, rewarnAfter: 60)
        if !SysTrackWatchdog.shouldWarnSilent(elapsed: 300, silentFor: due.silentFor,
                                              alreadyWarned: false, warnAfter: due.warnAfter) {
            fails.append("收起後滿 60 秒沒跳")
        }

        // ③ 重建橫幅:已武裝→合併訊息;觀察期內的持續無聲重建→不跳;其餘照舊。
        for reason in SysRebuildReason.allCases {
            for grace in [true, false] {
                let warned = SysTrackWatchdog.rebuildBanner(silentWarned: true, reason: reason, inRewarnGrace: grace)
                if warned != .sysRebuildMaybeStillSilent { fails.append("已武裝該給合併訊息") }
                let notWarned = SysTrackWatchdog.rebuildBanner(silentWarned: false, reason: reason, inRewarnGrace: grace)
                let want: RecordingWarning? = (grace && reason == .persistentSilence) ? nil : .sysRestarted(reason: reason)
                if notWarned != want { fails.append("重建橫幅不對:\(reason) grace=\(grace)") }
            }
        }
        return Result(name: "UI-41 無聲橫幅自動收起+再跳門檻(BUG-28)", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "12 種收起判定 + 門檻切換 + 重建橫幅 12 組合全對"
                                            : fails.joined(separator: ";"))
    }

    /// QUIT-12/13(BUG-27 殘留/#1697):退出前要不要問、以及「上次未完成」標記的修剪。
    static func quitTranscriptionGuard() -> Result {
        var fails: [String] = []
        // ① 要不要先問:轉稿中或有排隊都要問;都沒有才直接走。
        let ask = RecordingController.shouldConfirmQuitDuringTranscription
        if !ask(true, 0)  { fails.append("轉稿中沒問") }
        if !ask(false, 1) { fails.append("有排隊沒問") }
        if !ask(true, 2)  { fails.append("轉稿中+排隊沒問") }
        if ask(false, 0)  { fails.append("沒事卻問") }

        // ② 標記修剪:檔案還在且還沒逐字稿才留;重複要去重。
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mp_int_\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let pending = dir.appendingPathComponent("a.m4a")       // 還沒轉 → 留
            let done = dir.appendingPathComponent("b.m4a")          // 已有逐字稿 → 清
            let gone = dir.appendingPathComponent("c.m4a")          // 檔案不在 → 清
            try Data().write(to: pending); try Data().write(to: done)
            try Data().write(to: dir.appendingPathComponent("b.txt"))
            let kept = RecordingController.pruneInterrupted(
                saved: [pending.path, done.path, gone.path, pending.path]) { path in
                let url = URL(fileURLWithPath: path)
                guard FileManager.default.fileExists(atPath: path) else { return false }
                let txt = url.deletingPathExtension().appendingPathExtension("txt")
                return !FileManager.default.fileExists(atPath: txt.path)
            }
            if kept != [pending.path] { fails.append("修剪結果=\(kept.map { ($0 as NSString).lastPathComponent })") }
        } catch {
            fails.append("\(error)")
        }
        return Result(name: "QUIT-12/13 轉稿中退出的詢問與未完成標記", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "詢問 4 種組合 + 標記修剪(留 1 清 2 去重)全對"
                                            : fails.joined(separator: ";"))
    }

    /// CORR-03/04(#2417):建議驗證、套用、還原、分批的純決策。
    static func correctionRules() -> Result {
        var fails: [String] = []
        let segs = ["我們今天要討論竹子稿的格式", "請把錄音檔寄給我", "他目前在台積店做製程整合"]
        let raw = [
            CorrectionSuggestion(segment: 0, original: " 竹子稿 ", suggestion: "逐字稿", reason: "同音"),   // trim 後有效
            CorrectionSuggestion(segment: 0, original: "竹子稿", suggestion: "逐字稿", reason: "重複"),     // 去重
            CorrectionSuggestion(segment: 0, original: "竹子稿格", suggestion: "逐字稿", reason: "多一字"), // 正對照:不在原文
            CorrectionSuggestion(segment: 1, original: "錄音檔", suggestion: "錄音檔", reason: "沒改"),     // 等於沒改
            CorrectionSuggestion(segment: 2, original: "台積店", suggestion: "台積電", reason: "範圍外"),   // 段號不在批次
            CorrectionSuggestion(segment: 9, original: "x", suggestion: "y", reason: "越界"),
            CorrectionSuggestion(segment: 1, original: "", suggestion: "y", reason: "空"),
        ]
        let kept = CorrectionRules.validate(raw, segments: segs, range: 0..<2)
        if kept.count != 1 || kept.first?.original != "竹子稿" || kept.first?.segment != 0 {
            fails.append("validate 留下 \(kept.map { "\($0.segment):\($0.original)" })(要只留 0:竹子稿)")
        }
        // 正對照:同一則若 original 多一個字,必須被丟
        let bad = CorrectionRules.validate([CorrectionSuggestion(segment: 0, original: "竹子稿的格式x", suggestion: "逐字稿", reason: "")], segments: segs, range: 0..<1)
        if !bad.isEmpty { fails.append("多一字的建議沒被丟") }
        // 套用/還原
        let s = kept[0]
        guard let applied = CorrectionRules.apply(s, to: segs[0]) else { fails.append("apply 回 nil"); return Result(name: "CORR-03/04 校正建議驗證/套用/還原", passed: false, detail: fails.joined(separator: ";")) }
        if applied != "我們今天要討論逐字稿的格式" { fails.append("apply 結果 \(applied)") }
        if CorrectionRules.revert(s, in: applied) != segs[0] { fails.append("revert 沒還原") }
        if CorrectionRules.apply(s, to: "這段已經被人改掉了") != nil { fails.append("段落已改仍套用") }
        // 只換第一個
        let twice = CorrectionRules.apply(CorrectionSuggestion(segment: 0, original: "稿", suggestion: "稿稿", reason: ""), to: "稿A稿")
        if twice != "稿稿A稿" { fails.append("不是只換第一個:\(twice ?? "nil")") }
        // 分批
        let b = CorrectionRules.batches(count: 250, size: 100)
        if b != [0..<100, 100..<200, 200..<250] { fails.append("batches \(b)") }
        if !CorrectionRules.batches(count: 0, size: 100).isEmpty { fails.append("0 段應無批次") }
        return Result(name: "CORR-03/04 校正建議驗證/套用/還原", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "驗證 7 案(留 1)+正對照+套用/還原/只換第一個+分批" : fails.joined(separator: ";"))
    }

    /// SRT 來回(#2417):make → parse 要還原講者、文字、時間。
    static func srtRoundTrip() -> Result {
        let lines = [
            TranscriptLine(isYou: false, time: Date(), text: "你好,今天要討論逐字稿", isFinal: true, start: 0.5, duration: 1.5),
            TranscriptLine(isYou: true, time: Date(), text: "好的: 沒問題", isFinal: true, start: 2.0, duration: 0.8),
        ]
        let back = SRT.parse(SRT.make(from: lines))
        let ok = back.count == 2 && back[0].isYou == false && back[0].text == lines[0].text
            && back[1].isYou == true && back[1].text == lines[1].text
            && abs(back[0].start - 0.5) < 0.002 && abs(back[1].duration - 0.8) < 0.002
        return Result(name: "SRT 來回(make→parse)", passed: ok,
                      detail: ok ? "2 行講者/文字/時間一致" : "\(back.map { "\($0.isYou) \($0.text) \($0.start)" })")
    }

    /// CORR-06/13 靜態部分:提示詞只含段號＋文字;CLI 參數有該有的、沒有禁用的。
    static func correctionPromptAndArgs() -> Result {
        var fails: [String] = []
        let segs = ["第一段", "第二段", "第三段"]
        let user = CorrectionPrompt.user(segments: segs, range: 1..<3, language: .zhTW)
        if !user.contains("1: 第二段") || !user.contains("2: 第三段") { fails.append("提示詞缺段落") }
        if user.contains("第一段") { fails.append("批次外的段落被送出") }
        if user.contains("/Users") || user.contains(".m4a") { fails.append("提示詞含路徑/檔名") }
        let args = ClaudeCLIProvider.arguments(userPrompt: user, systemPrompt: "S", model: nil)
        let joined = args.joined(separator: " ")
        for need in ["-p", "--output-format json", "--json-schema", "--setting-sources ", "--system-prompt S", "--tools StructuredOutput", "--max-turns 1", "--no-session-persistence", "--strict-mcp-config"] where !joined.contains(need) {
            fails.append("缺 \(need)")
        }
        if let i = args.firstIndex(of: "--setting-sources"), args[i + 1] != "" { fails.append("setting-sources 不是空字串") }
        for bad in ClaudeCLIProvider.forbiddenFlags where joined.contains(bad) { fails.append("出現禁用旗標 \(bad)") }
        if let i = args.firstIndex(of: "--tools"), args[i + 1] == "" { fails.append("--tools 空字串(會灌 140k)") }
        let withModel = ClaudeCLIProvider.arguments(userPrompt: "u", systemPrompt: "s", model: "x")
        if !withModel.contains("--model") { fails.append("有指定 model 卻沒帶") }
        return Result(name: "CORR-06/13 提示詞範圍+CLI 參數鎖定", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "提示詞只含批次內段落;9 個必要旗標齊、禁用旗標無" : fails.joined(separator: ";"))
    }

    /// CORR-09:CLI 輸出解析——正常/未登入/非 JSON/缺欄位,訊息不含原始輸出。
    /// UI-59(BUG-38):建議清單高度政策純函式。
    static func correctionListHeight() -> Result {
        var fails: [String] = []
        let H = CorrectionListLayout.self
        if H.height(content: 0) != 1 { fails.append("量到之前應給 1pt,得 \(H.height(content: 0))") }
        if H.height(content: 200) != 200 { fails.append("少於上限應貼內容,得 \(H.height(content: 200))") }
        if H.height(content: 9000) != 360 { fails.append("超過上限應封 360,得 \(H.height(content: 9000))") }
        if H.height(content: 500, cap: 100) != 100 { fails.append("cap 可注入") }
        if H.maxHeight != 360 { fails.append("上限應 360") }
        return Result(name: "UI-59 校正建議清單高度", passed: fails.isEmpty, detail: fails.isEmpty ? "0→1、200→200、9000→360、cap 注入" : fails.joined(separator: ";"))
    }

    /// UI-60:建議列→逐字稿段的純決策。
    static func correctionFocus() -> Result {
        var fails: [String] = []
        let F = CorrectionFocus.self
        if F.lineIndex(segment: 0, count: 3) != 0 || F.lineIndex(segment: 2, count: 3) != 2 { fails.append("合法段號應回自己") }
        if F.lineIndex(segment: 3, count: 3) != nil || F.lineIndex(segment: -1, count: 3) != nil || F.lineIndex(segment: 0, count: 0) != nil { fails.append("越界應回 nil") }
        let t = "我們今天要討論竹子稿的格式,竹子稿很重要"
        if let r = F.highlightRange(original: "竹子稿", in: t) {
            let off = t.distance(from: t.startIndex, to: r.lowerBound)
            if String(t[r]) != "竹子稿" || off != 7 { fails.append("應取第一個命中(偏移 7),得 \(off)") }
        } else { fails.append("命中應回範圍") }
        if F.highlightRange(original: "不在", in: t) != nil { fails.append("沒命中應 nil") }
        if F.highlightRange(original: " 竹子稿 ", in: t) == nil { fails.append("前後空白應 trim") }
        if F.highlightRange(original: "", in: t) != nil { fails.append("空字串應 nil") }
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let lines = (0..<5).map { TranscriptLine(isYou: false, time: base.addingTimeInterval(Double($0) * 100), text: "l\($0)", isFinal: true) }
        let vis = TranscriptWindow.visible(lines, full: false)   // 3 分鐘視窗:只剩最後 2 行(300/400 s)
        if !F.needsFullTranscript(lineID: lines[0].id, visible: vis) { fails.append("早段不在視窗應需切完整") }
        if F.needsFullTranscript(lineID: lines[4].id, visible: vis) { fails.append("末段在視窗不需切") }
        if F.needsFullTranscript(lineID: lines[0].id, visible: TranscriptWindow.visible(lines, full: true)) { fails.append("完整模式下不需切") }
        return Result(name: "UI-60 建議列→逐字稿段純決策", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "lineIndex 越界 nil、highlightRange 第一個命中/trim/空/沒命中、需切完整 3 案" : fails.joined(separator: ";"))
    }

    static func correctionParseOutput() -> Result {
        var fails: [String] = []
        let good = """
        {"type":"result","structured_output":{"corrections":[{"segment":0,"original":"竹子稿","suggestion":"逐字稿","reason":"同音"}]},"usage":{"input_tokens":2,"cache_creation_input_tokens":1500,"cache_read_input_tokens":0,"output_tokens":120},"duration_ms":2300}
        """
        do {
            let r = try ClaudeCLIProvider.parseOutput(good, exitCode: 0)
            if r.suggestions.count != 1 || r.suggestions[0].suggestion != "逐字稿" { fails.append("正常輸出解析錯") }
            if r.inputTokens != 1502 || r.outputTokens != 120 || r.durationMs != 2300 { fails.append("usage 錯 \(r.inputTokens)/\(r.outputTokens)/\(r.durationMs)") }
        } catch { fails.append("正常輸出丟錯 \(error)") }
        do { _ = try ClaudeCLIProvider.parseOutput("Not logged in · Please run /login", exitCode: 1); fails.append("未登入沒丟") }
        catch CorrectionError.notLoggedIn {} catch { fails.append("未登入丟錯型別 \(error)") }
        do { _ = try ClaudeCLIProvider.parseOutput("garbage garbage SECRET-LINE", exitCode: 0); fails.append("非 JSON 沒丟") }
        catch CorrectionError.badOutput(let m) { if m.contains("SECRET-LINE") { fails.append("訊息含原始輸出") } }
        catch { fails.append("非 JSON 丟錯型別 \(error)") }
        do { _ = try ClaudeCLIProvider.parseOutput("{\"type\":\"result\",\"result\":\"x\"}", exitCode: 0); fails.append("缺欄位沒丟") }
        catch CorrectionError.badOutput {} catch { fails.append("缺欄位丟錯型別 \(error)") }
        return Result(name: "CORR-09 CLI 輸出解析", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "正常/未登入/非 JSON/缺欄位 4 案,訊息不含原文" : fails.joined(separator: ";"))
    }

    /// AUD-35(BUG-29/#2411):tap 排除清單的純決策＋自己的 process object 查得到。
    static func tapExcludesSelf() -> Result {
        var fails: [String] = []
        let a = AudioObjectID(100), b = AudioObjectID(200)
        if SystemAudioCapture.exclusionList(own: a, extra: [b, a, .unknown]) != [a, b] { fails.append("去重/過濾 unknown 錯") }
        if SystemAudioCapture.exclusionList(own: nil, extra: [b]) != [b] { fails.append("own 為 nil 時應只剩 extra") }
        if !SystemAudioCapture.exclusionList(own: nil, extra: []).isEmpty { fails.append("空清單應為空") }
        // 自己的 process object:測試行程未必有音訊物件,查得到就要是合法 id;查不到只記不算錯。
        let own = SystemAudioCapture.processObject(forPID: ProcessInfo.processInfo.processIdentifier)
        if let own, own.isUnknown { fails.append("翻譯回 unknown 卻沒過濾") }
        return Result(name: "AUD-35 tap 排除自己的行程(純決策)", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "排除清單 3 案全對;本行程 process object=\(own.map { "\($0)" } ?? "無(測試行程未用音訊)")" : fails.joined(separator: ";"))
    }

    /// DBG-01(#2412):指令切分與結果檔路徑政策(純函式)。
    static func debugCommandParsing() -> Result {
        var fails: [String] = []
        let sep = String(DebugCommand.separator)
        if DebugCommand.parse("state" + sep + "/tmp/s.json") != ["state", "/tmp/s.json"] { fails.append("基本切分") }
        if DebugCommand.parse("a" + sep + sep + "b") != ["a", "", "b"] { fails.append("空參數要保留") }
        if !DebugCommand.parse("").isEmpty { fails.append("空字串應為 []") }
        let home = "/Users/x", tmp = "/var/folders/ab/T/"
        for ok in ["/tmp/a.json", "/private/tmp/a.json", "/var/folders/ab/T/x.json", "/Users/x/Desktop/r.json"]
            where !DebugCommand.isAllowedResultPath(ok, home: home, tmp: tmp) { fails.append("應允許 \(ok)") }
        for bad in ["relative.json", "/etc/passwd", "/Users/x/../y/r.json", "/Users/other/r.json", "/tmp/../etc/x", "/Library/x.json", ""]
            where DebugCommand.isAllowedResultPath(bad, home: home, tmp: tmp) { fails.append("應拒絕 \(bad)") }
        return Result(name: "DBG-01 控制通道指令切分與結果檔路徑", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "切分 3 案、路徑允許 4 案/拒絕 7 案" : fails.joined(separator: ";"))
    }

    private static func rms(_ buf: AVAudioPCMBuffer, _ channel: Int) -> Float {
        guard let data = buf.floatChannelData, Int(buf.format.channelCount) > channel else { return 0 }
        let n = Int(buf.frameLength); guard n > 0 else { return 0 }
        var sum: Float = 0; let ch = data[channel]
        for i in 0..<n { sum += ch[i] * ch[i] }
        return sqrt(sum / Float(n))
    }

    // MARK: - CAL(#2407 行事曆觸發錄音第一階段)

    /// CAL-01:事件篩選純函式——勾選日曆、關鍵字(不分大小寫)、排除全天/取消/已開始、去重、排序、關鍵字解析。
    static func meetingReminderSelection() -> Result {
        var fails: [String] = []
        let now = Date(timeIntervalSince1970: 1_800_000_000)   // 固定基準
        func ev(_ id: String, _ cal: String, _ title: String, startIn: TimeInterval, allDay: Bool = false, cancelled: Bool = false) -> CalendarEventInfo {
            CalendarEventInfo(id: id, calendarID: cal, title: title, start: now.addingTimeInterval(startIn),
                              end: now.addingTimeInterval(startIn + 3600), isAllDay: allDay, isCancelled: cancelled)
        }
        var s = ReminderSettings()
        s.enabled = true
        s.calendarIDs = ["primary"]
        s.keywords = ["面談", "Interview", "相談室"]
        let events = [
            ev("a", "primary", "大叔的人生相談室 (某人)", startIn: 3600),          // 命中
            ev("b", "primary", "Panel INTERVIEW with X", startIn: 1800),          // 命中(大小寫)
            ev("c", "family", "面談 Y", startIn: 900),                            // 日曆沒勾
            ev("d", "primary", "午餐", startIn: 600),                             // 關鍵字不中
            ev("e", "primary", "面談 全天", startIn: 7200, allDay: true),          // 全天
            ev("f", "primary", "面談 取消", startIn: 7200, cancelled: true),       // 取消
            ev("g", "primary", "面談 已開始", startIn: -60),                       // 已開始
            ev("b", "primary", "Panel INTERVIEW with X", startIn: 1800),          // 重複
            ev("h", "primary", "面談 太遠", startIn: 25 * 3600),                   // 超出 24h
        ]
        let planned = MeetingReminderRules.select(events: events, settings: s, now: now)
        if planned.map(\.event.id) != ["b", "a"] { fails.append("應只留 b、a 且依提醒時刻排序,得 \(planned.map(\.event.id))") }
        if let b = planned.first, b.fireAt != now.addingTimeInterval(1800 - 120) { fails.append("提醒時刻應=開始−2 分") }
        if let b = planned.first, b.key != "b@2027-01-15T08:30:00Z" { fails.append("鍵格式 id@UTC-ISO,得 \(b.key)") }
        var off = s; off.enabled = false
        if !MeetingReminderRules.select(events: events, settings: off, now: now).isEmpty { fails.append("關閉時應回空") }
        // 睡醒才算到:提醒時刻已過但未開始 → 仍回傳(排程器立刻發)
        var late = s; late.leadMinutes = 30
        let soon = MeetingReminderRules.select(events: [ev("z", "primary", "面談 快到", startIn: 300)], settings: late, now: now)
        if soon.count != 1 || soon[0].fireAt >= now { fails.append("已過提醒時刻但未開始應仍回傳且 fireAt<now") }
        // 關鍵字解析
        let parsed = ReminderSettings.parseKeywords(" 會議, 面談，interview;Interview\n\n call ,")
        if parsed != ["會議", "面談", "interview", "call"] { fails.append("關鍵字解析/去重錯:\(parsed)") }
        if ReminderSettings.defaultKeywords.contains(where: { ["同意書", "人選", "HH"].contains($0) }) { fails.append("預設關鍵字不得帶業務詞") }
        if MeetingReminderRules.matches(title: "x", keywords: []) { fails.append("空關鍵字清單不應命中") }
        return Result(name: "CAL-01 事件篩選(日曆/關鍵字/全天/取消/已開始/去重/排序)", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "9 事件→2 命中;關閉回空;睡醒補發;關鍵字解析 4 項" : fails.joined(separator: ";"))
    }

    /// CAL-02:絕對時間 → 雙時區顯示;Berlin 偏移字串與 Taipei 牆鐘是同一瞬間。
    static func dualTimeZoneFormat() -> Result {
        var fails: [String] = []
        let iso = ISO8601DateFormatter()
        guard let summer = iso.date(from: "2026-10-20T08:30:00+02:00"),      // 相談室事件 API 回的樣子
              let winter = iso.date(from: "2026-12-01T07:30:00+01:00"),
              let berlin = TimeZone(identifier: "Europe/Berlin"),
              let shanghai = TimeZone(identifier: "Asia/Shanghai"),
              let la = TimeZone(identifier: "America/Los_Angeles") else {
            return Result(name: "CAL-02 雙時區顯示", passed: false, detail: "測資建不起來")
        }
        let p1 = DualTimeZoneFormat.parts(summer, local: DualTimeZoneFormat.taipei)
        if !p1.isSame || DualTimeZoneFormat.zhTW(p1) != "14:30" { fails.append("本機台北應只顯示 14:30,得 \(DualTimeZoneFormat.zhTW(p1))") }
        let p2 = DualTimeZoneFormat.parts(summer, local: berlin)
        if p2.isSame || DualTimeZoneFormat.zhTW(p2) != "14:30 台北 ／ 08:30 Berlin (UTC+2)" { fails.append("夏令時應為 14:30 台北 ／ 08:30 Berlin (UTC+2),得 \(DualTimeZoneFormat.zhTW(p2))") }
        let p3 = DualTimeZoneFormat.parts(winter, local: berlin)
        if DualTimeZoneFormat.zhTW(p3) != "14:30 台北 ／ 07:30 Berlin (UTC+1)" { fails.append("冬令時應為 07:30 Berlin (UTC+1),得 \(DualTimeZoneFormat.zhTW(p3))") }
        let p4 = DualTimeZoneFormat.parts(summer, local: shanghai)
        if !p4.isSame { fails.append("同偏移(上海)應視為同一時鐘") }
        let p5 = DualTimeZoneFormat.parts(summer, local: la)
        if !DualTimeZoneFormat.zhTW(p5).hasSuffix("Los Angeles (UTC-7)") { fails.append("底線城市名應換空白並帶 UTC 偏移,得 \(p5.localZone)") }
        // 反過來:事件 Berlin 本機 Taipei(同一瞬間,只是顯示)
        let p6 = DualTimeZoneFormat.parts(winter, local: DualTimeZoneFormat.taipei, includeDate: true)
        if p6.reference != "12/01 14:30" { fails.append("含日期格式應為 12/01 14:30,得 \(p6.reference)") }
        return Result(name: "CAL-02 雙時區顯示(同偏移單顯/夏冬令時/城市名)", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "6 組:台北單顯、Berlin 夏/冬、上海同偏移、LA 城市名、含日期" : fails.joined(separator: ";"))
    }

    /// CAL-05:已發紀錄落檔——空/寫/查/過期清理/壞檔視為空。
    static func firedReminderStore() -> Result {
        var fails: [String] = []
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("myparrot-cal05-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FiredReminderStore(url: dir.appendingPathComponent("reminders-fired.json"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        if !store.load(now: now).isEmpty { fails.append("檔不存在應為空") }
        if store.contains("k1", now: now) { fails.append("空檔不應含 k1") }
        do {
            try store.markFired("k1", at: now)
            if !store.contains("k1", now: now) { fails.append("寫入後應含 k1") }
            try store.markFired("k2", at: now.addingTimeInterval(60))
            let all = store.load(now: now.addingTimeInterval(60))
            if all.count != 2 { fails.append("應有 2 鍵,得 \(all.count)") }
            // 8 天後 k1、k2 都過期;新鍵進來時順手清掉
            let later = now.addingTimeInterval(8 * 86400)
            let afterPrune = try store.markFired("k3", at: later)
            if afterPrune.keys.sorted() != ["k3"] { fails.append("過期鍵應被清,得 \(afterPrune.keys.sorted())") }
            // 檔內容是 launchd 腳本看得懂的形狀
            let raw = try String(contentsOf: store.url, encoding: .utf8)
            if !raw.contains("\"fired\"") || !raw.contains("\"k3\"") || !raw.contains("\"version\"") { fails.append("JSON 形狀不對:\(raw.prefix(120))") }
        } catch { fails.append("寫檔失敗:\(error)") }
        // 壞檔
        try? Data("not json".utf8).write(to: store.url)
        if !store.load(now: now).isEmpty || !store.isCorrupt { fails.append("壞檔應視為空且 isCorrupt") }
        if FiredReminderStore.prune(["a": now, "b": now.addingTimeInterval(-8 * 86400)], now: now, retention: 7 * 86400).keys.sorted() != ["a"] { fails.append("prune 純函式錯") }
        if !FiredReminderStore.defaultURL.path.hasSuffix(".config/myparrot/reminders-fired.json") && getenv("MYPARROT_CONFIG_DIR") == nil { fails.append("預設路徑應在 ~/.config/myparrot") }
        return Result(name: "CAL-05 已發紀錄(寫/查/7 天清理/壞檔視為空)", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "空→寫 2→8 天後清成 1;壞檔視為空;JSON 形狀含 version/fired" : fails.joined(separator: ";"))
    }

    /// CAL-08/09/11:死軌規則、沒人說話量尺(自適應底噪 +12 dB)、30 分鐘靜音建議停(只發一次、再武裝)。
    static func speechActivityAndAlarms() -> Result {
        var fails: [String] = []
        // ① 死軌規則
        if DeadTrackRule.shouldAlarm(elapsed: 179, everHadSignal: false, alreadyAlarmed: false) { fails.append("179 秒不該告警") }
        if !DeadTrackRule.shouldAlarm(elapsed: 180, everHadSignal: false, alreadyAlarmed: false) { fails.append("180 秒從頭無訊號該告警") }
        if DeadTrackRule.shouldAlarm(elapsed: 300, everHadSignal: true, alreadyAlarmed: false) { fails.append("有過訊號不該告警") }
        if DeadTrackRule.shouldAlarm(elapsed: 300, everHadSignal: false, alreadyAlarmed: true) { fails.append("只發一次") }

        // ② 量尺:每秒 12 筆
        let dt: TimeInterval = 1.0 / 12
        func feed(_ est: inout SpeechActivityEstimator, _ levels: [Float], from t0: TimeInterval) -> (speech: Int, t: TimeInterval) {
            var t = t0, n = 0
            for v in levels { if est.observe(level: v, at: t) { n += 1 }; t += dt }
            return (n, t)
        }
        // (a) 純底噪 0.008(≈實測 -54 dBFS 乘 4 倍增益)60 秒 → 0 筆說話;底噪估到 ≈0.008
        var est = SpeechActivityEstimator()
        var r = feed(&est, Array(repeating: 0.008, count: 720), from: 0)
        if r.speech > 1 { fails.append("純底噪不該算說話(前 1 筆用下限門檻可容忍),得 \(r.speech)") }
        if abs(est.noiseFloor - 0.008) > 0.0001 { fails.append("底噪應≈0.008,得 \(est.noiseFloor)") }
        // (b) 底噪上疊說話 0.1(+22 dB)24 筆 → 全算說話
        r = feed(&est, Array(repeating: 0.1, count: 24), from: r.t)
        if r.speech != 24 { fails.append("說話 24 筆應全命中,得 \(r.speech)") }
        // (c) 底噪慢漂到 0.012(+3.5 dB)不算說話
        r = feed(&est, (0..<720).map { 0.008 + 0.004 * Float($0) / 720 }, from: r.t)
        if r.speech != 0 { fails.append("底噪慢漂不該算說話,得 \(r.speech)") }
        // (d) 全零軌:底噪＝下限,門檻 0.002;0 不算說話、0.01 算
        var zero = SpeechActivityEstimator()
        r = feed(&zero, Array(repeating: 0, count: 120), from: 0)
        if r.speech != 0 || zero.noiseFloor != zero.floorMin { fails.append("全零軌底噪應=下限且不算說話") }
        if !zero.observe(level: 0.01, at: r.t) { fails.append("全零軌上 0.01 應算說話") }
        // (d2) 底噪 0.008 中夾一個全零 buffer(tap 重建瞬間):底噪不該掉到下限,之後的底噪也不該被當成說話
        var glitch = SpeechActivityEstimator()
        _ = feed(&glitch, Array(repeating: 0.008, count: 120), from: 0)
        _ = glitch.observe(level: 0, at: 10)
        if glitch.noiseFloor < 0.007 { fails.append("零 buffer 不該參與底噪估計,得 \(glitch.noiseFloor)") }
        r = feed(&glitch, Array(repeating: 0.011, count: 120), from: 10.1)
        if r.speech != 0 { fails.append("零 buffer 後的房間底噪(+2.8 dB)不該算說話,得 \(r.speech)") }
        // (e) 連講 70 秒不喘氣:5 分鐘視窗的底噪不該被講話頂高(60 秒視窗會)
        var talk = SpeechActivityEstimator()
        _ = feed(&talk, Array(repeating: 0.008, count: 120), from: 0)           // 10 秒底噪
        r = feed(&talk, Array(repeating: 0.1, count: 840), from: 10)              // 70 秒連講
        if r.speech != 840 { fails.append("70 秒連講應全算說話,得 \(r.speech)") }
        var short = SpeechActivityEstimator(windowSeconds: 60)
        _ = feed(&short, Array(repeating: 0.008, count: 120), from: 0)
        let rs = feed(&short, Array(repeating: 0.1, count: 840), from: 10)
        if rs.speech >= 840 { fails.append("對照組:60 秒視窗應該會漏(證明 5 分鐘視窗有差)") }

        // ③ 30 分鐘靜音建議停:只發一次,恢復說話再武裝;t 是錄音經過秒數(暫停不計由呼叫端保證)
        var rule = SilenceStopRule(after: 1800)
        var fired: [TimeInterval] = []
        var t: TimeInterval = 0
        while t <= 1900 { if rule.observe(anySpeech: false, at: t) { fired.append(t) }; t += 1 }
        if fired != [1800] { fails.append("應在 1800 秒發一次,得 \(fired)") }
        _ = rule.observe(anySpeech: true, at: 2000)
        fired = []
        t = 2001
        while t <= 3900 { if rule.observe(anySpeech: false, at: t) { fired.append(t) }; t += 1 }
        if fired != [3800] { fails.append("再武裝後應在 3800 秒再發一次,得 \(fired)") }
        return Result(name: "CAL-08/09/11 死軌規則+沒人說話量尺+30 分鐘建議停", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "死軌 4 案;量尺 底噪/說話/慢漂/全零/零 buffer 不拉底噪/連講 70 秒(5 分視窗 vs 60 秒對照);建議停 1800→再武裝→3800" : fails.joined(separator: ";"))
    }

    /// CAL-07:外部通知指令——環境變數、退出碼、逾時殺整組、空指令不跑。
    static func externalNotifyCommand() -> Result {
        var fails: [String] = []
        let iso = ISO8601DateFormatter()
        guard let start = iso.date(from: "2026-10-20T08:30:00+02:00"), let berlin = TimeZone(identifier: "Europe/Berlin") else {
            return Result(name: "CAL-07 外部通知指令", passed: false, detail: "測資建不起來")
        }
        let env = ExternalNotifyCommand.environment(title: "面談 X", start: start, local: berlin, base: ["PATH": "/usr/bin:/bin"])
        if env["MYPARROT_EVENT_TITLE"] != "面談 X" { fails.append("標題變數") }
        if env["MYPARROT_START_ISO"] != "2026-10-20T06:30:00Z" { fails.append("ISO 應為 UTC,得 \(env["MYPARROT_START_ISO"] ?? "nil")") }
        if env["MYPARROT_START_LOCAL"] != "10/20 08:30" { fails.append("本機時間變數,得 \(env["MYPARROT_START_LOCAL"] ?? "nil")") }
        if env["MYPARROT_START_TAIPEI"] != "10/20 14:30" { fails.append("台北時間變數,得 \(env["MYPARROT_START_TAIPEI"] ?? "nil")") }
        if env["PATH"] != "/usr/bin:/bin" { fails.append("base 環境應保留") }
        let okOut = ExternalNotifyCommand.run("test \"$MYPARROT_EVENT_TITLE\" = '面談 X'", environment: env)
        if !okOut.ok { fails.append("子行程應讀到變數且 exit 0,得 \(okOut)") }
        let bad = ExternalNotifyCommand.run("exit 3", environment: env)
        if bad.exitCode != 3 || bad.timedOut { fails.append("exit 3 應回 3,得 \(bad)") }
        let t0 = Date()
        let slow = ExternalNotifyCommand.run("sleep 5; sleep 5", environment: env, timeout: 0.4)
        let took = Date().timeIntervalSince(t0)
        if !slow.timedOut || took > 3 { fails.append("逾時應在 0.4 秒殺掉,得 \(slow) 耗時 \(took)") }
        if !ExternalNotifyCommand.run("   ", environment: env).ok { fails.append("空指令應視為 ok 不跑") }
        return Result(name: "CAL-07 外部通知指令(環境變數/退出碼/逾時殺組/空指令)", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "4 變數正確;exit 3;sleep 逾時 \(String(format: "%.2f", took))s 殺掉;空指令不跑" : fails.joined(separator: ";"))
    }

    /// #949 配套:CLI 正在錄的探測(pid 檔活著才算)。
    static func cliRecordingProbe() -> Result {
        var fails: [String] = []
        if CLIRecordingProbe.parsePID("123\n") != 123 { fails.append("parsePID 容忍換行") }
        if CLIRecordingProbe.parsePID("abc") != nil { fails.append("非數字應 nil") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("myparrot-949-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pidURL = dir.appendingPathComponent("record.pid")
        if CLIRecordingProbe.isCLIRecording(pidURL: pidURL) { fails.append("沒檔應為 false") }
        try? Data(String(ProcessInfo.processInfo.processIdentifier).utf8).write(to: pidURL)
        if !CLIRecordingProbe.isCLIRecording(pidURL: pidURL) { fails.append("自己的 pid 應為活著") }
        try? Data("999999".utf8).write(to: pidURL)
        if CLIRecordingProbe.isCLIRecording(pidURL: pidURL) { fails.append("不存在的 pid 應為 false") }
        return Result(name: "CAL-06b CLI 錄音中探測(#949)", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "無檔/活 pid/死 pid 三案" : fails.joined(separator: ";"))
    }


    /// BUG-31/UI-42:自存視窗 frame 來自別的螢幕配置時夾回可見區。
    static func windowFrameClamp() -> Result {
        var fails: [String] = []
        let mac = CGRect(x: 0, y: 0, width: 1512, height: 949)        // MacBook 可見區(扣掉選單列)
        let ext = CGRect(x: 1512, y: -98, width: 1920, height: 1050)   // 外接螢幕
        let saved = CGRect(x: 1685, y: 566, width: 393, height: 652)   // Eric 偏好裡的壞值
        let r1 = WindowFrameClamp.clamp(saved, screens: [mac], primary: mac)
        if r1 != CGRect(x: 1512 - 393, y: 949 - 652, width: 393, height: 652) { fails.append("外接螢幕拔掉後應貼回主螢幕右上,得 \(r1)") }
        let r2 = WindowFrameClamp.clamp(saved, screens: [mac, ext], primary: mac)
        if r2 != saved { fails.append("外接螢幕還在時應原樣,得 \(r2)") }
        let inside = CGRect(x: 100, y: 100, width: 393, height: 652)
        if WindowFrameClamp.clamp(inside, screens: [mac], primary: mac) != inside { fails.append("本來就在螢幕內應原樣") }
        let mostly = CGRect(x: 1512 - 250, y: 100, width: 393, height: 652)   // 64% 在螢幕內
        if WindowFrameClamp.clamp(mostly, screens: [mac], primary: mac) != mostly { fails.append("過半可見應原樣") }
        let sliver = CGRect(x: 1472, y: 100, width: 393, height: 652)          // 只露 40 pt(Eric 看到的)
        let r5 = WindowFrameClamp.clamp(sliver, screens: [mac], primary: mac)
        if r5.maxX != 1512 || r5.minY != 100 { fails.append("只露一小條應整個推回螢幕內,得 \(r5)") }
        let huge = CGRect(x: -50, y: -50, width: 2000, height: 1500)
        let r6 = WindowFrameClamp.clamp(huge, screens: [mac], primary: mac)
        if r6 != mac { fails.append("比螢幕大應縮成可見區,得 \(r6)") }
        if WindowFrameClamp.clamp(.zero, screens: [mac], primary: mac) != .zero { fails.append("零 frame 原樣回傳") }
        return Result(name: "UI-42 自存視窗 frame 夾回可見區(BUG-31)", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "壞值 1685→1119;外接在時原樣;螢幕內/過半/一小條/過大/零 共 7 案" : fails.joined(separator: ";"))
    }

}
