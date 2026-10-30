import Testing
@testable import MyParrotCore

/// MyParrot 核心自我測試 — Swift Testing 版(Xcode ⌘U 或 `swift test`)。
///
/// 每個 `@Test` 對應一個 `SelfTest` 案例,測試邏輯共用 MyParrotCore 的
/// `SelfTest`,與 `MyParrotSelfTest` 執行檔零重複(改行為只需改一處)。
/// `MyParrotSelfTest` 執行檔保留作為「無完整 Xcode 也能跑」的後備。
@Suite("MyParrot 核心自我測試")
struct SelfTestCases {

    private func check(_ r: SelfTest.Result) {
        #expect(r.passed, "\(r.name) — \(r.detail)")
    }

    @Test("檔名範本 日期+時間+會議名") func fileNameFormat()   { check(SelfTest.fileNameFormat()) }
    @Test("空標題 fallback → 錄音")    func fileNameFallback() { check(SelfTest.fileNameFallback()) }
    @Test("SampleQueue FIFO + 靜音補齊") func sampleQueueFIFO() { check(SelfTest.sampleQueueFIFO()) }
    @Test("AUD-29 補零接縫 ramp + min 抽取") func drainNoClick() { check(SelfTest.drainNoClick()) }
    @Test("24k→48k 重採樣")            func monoResample()     { check(SelfTest.monoResample()) }
    @Test("立體聲分軌(對方左/你右)")   func stereoSeparation() { check(SelfTest.stereoSeparation()) }
    @Test("設定·麥克風裝置列舉")        func deviceEnumeration(){ check(SelfTest.deviceEnumeration()) }
    @Test("設定·靈敏度增益 ×2")        func gainScaling()      { check(SelfTest.gainScaling()) }
    @Test("CAF→m4a 匯出(更小且可讀)")  func m4aExport()        { check(SelfTest.m4aExport()) }
    @Test("SRT 時間碼+講者格式")        func srtFormat()        { check(SelfTest.srtFormat()) }
    @Test("逐字稿「最近 3 分鐘」視窗") func transcriptWindow() { check(SelfTest.transcriptWindow()) }
    @Test("Whisper VAD 切塊 + 簡轉繁") func whisperChunkerAndZhTW() { check(SelfTest.whisperChunkerAndZhTW()) }
    @Test("Whisper 幻覺防呆(連續複讀≥3 次壓下)") func whisperHallucinationGate() { check(SelfTest.whisperHallucinationGate()) }
    @Test("TR-28 會後重轉 VAD 分塊(切點/偏移/強制切/flush)") func whisperFileChunking() { check(SelfTest.whisperFileChunking()) }
    @Test("AUD-37 麥克風格式 guard + ObjC 例外橋") func micInputFormatGuard() { check(SelfTest.micInputFormatGuard()) }
    @Test("AUD-38 震盪鎖與偽通知") func micRebuildPolicy() { check(SelfTest.micRebuildPolicy()) }
    @Test("AUD-38 看門狗計數與重建判定") func micWatchdogPolicy() { check(SelfTest.micWatchdogPolicy()) }
    @Test("AUD-38 藍牙保持器決策") func bluetoothHoldPolicy() { check(SelfTest.bluetoothHoldPolicy()) }
    @Test("AUD-39 預設輸入穩定與已 HFP 判定") func micDevicePolicy() { check(SelfTest.micDevicePolicy()) }
    @Test("UI-58 載入舊稿時間以錄音起點為基準") func transcriptLoadBaseTime() { check(SelfTest.transcriptLoadBaseTime()) }
    @Test("回音消除(NLMS)合成驗證")    func echoCancel()       { check(SelfTest.echoCancel()) }
    @Test("AEC 無回音 gate(戴耳機略過)") func aecNoEchoGate()   { check(SelfTest.aecNoEchoGate()) }
    @Test("BUG-24 對方軌流動但全零看門狗") func sysSilenceWatchdog() { check(SelfTest.sysSilenceWatchdog()) }
    @Test("BUG-25 藍牙漏拍缺口補靜音") func btGapFill() { check(SelfTest.btGapFill()) }
    @Test("UI-36 警示繁中原文釘字") func warningZhTWPinned() { check(SelfTest.warningZhTWPinned()) }
    @Test("UI-41 無聲橫幅自動收起+再跳門檻") func warningAutoDismissRules() { check(SelfTest.warningAutoDismissRules()) }
    @Test("QUIT-12/13 轉稿中退出詢問與未完成標記") func quitTranscriptionGuard() { check(SelfTest.quitTranscriptionGuard()) }
    @Test("CORR-03/04 校正建議驗證/套用/還原") func correctionRules() { check(SelfTest.correctionRules()) }
    @Test("UI-59 校正建議清單高度(min(內容,360)、0→1)") func correctionListHeight() { check(SelfTest.correctionListHeight()) }
    @Test("UI-60 建議列→逐字稿段(lineIndex/highlightRange/需切完整)") func correctionFocus() { check(SelfTest.correctionFocus()) }
    @Test("SRT 來回(make→parse)") func srtRoundTrip() { check(SelfTest.srtRoundTrip()) }
    @Test("CORR-06/13 提示詞範圍+CLI 參數鎖定") func correctionPromptAndArgs() { check(SelfTest.correctionPromptAndArgs()) }
    @Test("CORR-09 CLI 輸出解析") func correctionParseOutput() { check(SelfTest.correctionParseOutput()) }
    @Test("CDX-01 Codex 登錄表(能力/順序/隱私鍵/往返)") func codexRegistry() { check(SelfTest.codexRegistry()) }
    @Test("CDX-04 Codex 參數鎖定+登入判定+提示詞合成") func codexArguments() { check(SelfTest.codexArguments()) }
    @Test("CDX-07 Codex 輸出解析(-o 優先/JSONL 退回/失敗型,訊息不含原文)") func codexParseOutput() { check(SelfTest.codexParseOutput()) }
    @Test("TRL-01 翻譯登錄表與目標語言") func translationRegistry() { check(SelfTest.translationRegistry()) }
    @Test("TRL-04 翻譯批次與節奏") func translationPlan() { check(SelfTest.translationPlan()) }
    @Test("TRL-05 翻譯提示詞與解析(兩家)") func translationPromptAndParse() { check(SelfTest.translationPromptAndParse()) }
    @Test("TRL-08 譯文檔對齊") func translationSRT() { check(SelfTest.translationSRT()) }
    @Test("TOK-01 每場模型用量帳本(append/load/totals/壞檔/format)") func tokenLedger() { check(SelfTest.tokenLedger()) }
    @Test("CLT-01 Whisper 模型大小檢查單位(三個 HF 位元數＋正控＋邊界)") func whisperModelSize() { check(SelfTest.whisperModelSize()) }
    @Test("AUD-35 tap 排除自己的行程(純決策)") func tapExcludesSelf() { check(SelfTest.tapExcludesSelf()) }
    @Test("DBG-01 控制通道指令切分與結果檔路徑") func debugCommandParsing() { check(SelfTest.debugCommandParsing()) }
    @Test("UPD-01 版號解析/比較(v 前綴/補 0/非數字段)") func updateVersionCompare() { check(SelfTest.caseUpdateVersionCompare()) }
    @Test("UPD-02 GitHubRelease decode(容忍未知欄位)") func updateReleaseDecode() { check(SelfTest.caseUpdateReleaseDecode()) }
    @Test("UPD-03 略過此版邏輯") func updateSkipLogic() { check(SelfTest.caseUpdateSkipLogic()) }
    @Test("UI-28b 波形桶分析(分段讀/正規化/downsample)") func waveformBuckets() { check(SelfTest.waveformBuckets()) }
    @Test("UI-28c 波形快取落檔(round-trip/失效/損毀)") func waveformCache() { check(SelfTest.waveformCacheRoundTrip()) }
    @Test("REC-02b 同分鐘同標題防覆蓋(後綴 2/3)") func uniqueFileName() { check(SelfTest.uniqueFileNameProbe()) }
    @Test("UI-29 電平表 dB 刻度(−50…−12 dBFS,三處同刻度)") func meterScale() { check(SelfTest.meterScaleMapping()) }
    @Test("REC-02c 標題去路徑語意") func titleSanitize() { check(SelfTest.titleSanitize()) }
    @Test("TR-27 whisper 閒置釋放策略(逾時解析+釋放閘)") func whisperIdleUnload() { check(SelfTest.whisperIdleUnloadPolicy()) }
    @Test("CAL-01 事件篩選(日曆/關鍵字/全天/取消/已開始/去重/排序)") func meetingReminderSelection() { check(SelfTest.meetingReminderSelection()) }
    @Test("CAL-02 雙時區顯示(同偏移單顯/夏冬令時/城市名)") func dualTimeZoneFormat() { check(SelfTest.dualTimeZoneFormat()) }
    @Test("CAL-05 已發紀錄(寫/查/7 天清理/壞檔視為空)") func firedReminderStore() { check(SelfTest.firedReminderStore()) }
    @Test("CAL-08/09/11 死軌規則+沒人說話量尺+30 分鐘建議停") func speechActivityAndAlarms() { check(SelfTest.speechActivityAndAlarms()) }
    @Test("CAL-07 外部通知指令(環境變數/退出碼/逾時殺組/空指令)") func externalNotifyCommand() { check(SelfTest.externalNotifyCommand()) }
    @Test("CAL-06b CLI 錄音中探測(#949)") func cliRecordingProbe() { check(SelfTest.cliRecordingProbe()) }
    @Test("UI-42 自存視窗 frame 夾回可見區(BUG-31)") func windowFrameClamp() { check(SelfTest.windowFrameClamp()) }
    @Test("MDL-01 模型登錄表解析(預設全關/不認得＝off/debugOnly 只在 DEBUG)") func modelRegistryResolution() { check(SelfTest.modelRegistryResolution()) }
    @Test("MDL-02 偏好遷移(舊 correctionBackend → model.correction,舊鍵保留)") func modelLegacyKeyMigration() { check(SelfTest.modelLegacyKeyMigration()) }
    @Test("MDL-03 隱私確認判定(出機後端只問一次、以後端為單位)") func modelPrivacyConfirmation() { check(SelfTest.modelPrivacyConfirmation()) }
    @Test("MIN-00 會議記錄 Markdown render(四段＋時間軸,純函式)") func minutesMarkdownRender() { check(SelfTest.minutesMarkdownRender()) }
    @Test("MIN-01/02/03 提示詞範圍+參數鎖定+schema(含正控組)") func minutesPromptAndArgs() { check(SelfTest.minutesPromptAndArgs()) }
    @Test("MIN-03/05 會議記錄 CLI 輸出解析(7 案,訊息不含原文)") func minutesParseOutput() { check(SelfTest.minutesParseOutput()) }
    @Test("MIN-04/05/09 滾動決策+舊 .minutes.json 相容") func minutesRollingRules() { check(SelfTest.minutesRollingRules()) }
    @Test("UI-46 面板狀態 toggle/move/dock 窮舉＋JSON 來回") func paneStateMoveDock() { check(SelfTest.paneStateMoveDock()) }
    @Test("UI-47 視窗自動加寬/縮窄 WorkspaceLayout.resolve(A1)") func workspaceLayoutResolve() { check(SelfTest.workspaceLayoutResolve()) }
    @Test("UI-47b 視窗最小寬度＋把手視窗內互換＋變窄壓縮") func workspaceMinWidthAndRedistribute() { check(SelfTest.workspaceMinWidthAndRedistribute()) }
    // #2438 M2:NotesStore 是 @MainActor,這兩案標 @MainActor 直接在主執行緒跑(不必 dispatch 同步)。
    @Test("NOTE-01 筆記 sidecar 命名與草稿流轉(暫存夾真檔)") @MainActor func notesSidecarAndDraft() { check(SelfTest.notesSidecarAndDraft()) }
    @Test("NOTE-02 自動存檔 1 秒 debounce＋原子寫(連打 50 次 ≤3 寫)") @MainActor func notesAtomicAutosave() { check(SelfTest.notesAtomicAutosave()) }
    @Test("NOTE-03 工具列插入規則(包住/前綴/連結/表格/分隔線)") func markdownToolbarInsert() { check(SelfTest.markdownToolbarInsert()) }
    @Test("NOTE-04 編輯行為(Enter 接清單/Tab/勾選/成對/貼網址)") func markdownEditingBehaviors() { check(SelfTest.markdownEditingBehaviors()) }
    @Test("NOTE-05 語法高亮範圍(不越界、不重疊、外層為準)") func markdownHighlightRanges() { check(SelfTest.markdownHighlightRanges()) }
    @Test("NOTE-06 Markdown 區塊解析(GFM 子集＋時間戳列)") func markdownBlocksParse() { check(SelfTest.markdownBlocksParse()) }
    @Test("UI-53 sidecar 改名計畫＋真改名＋回滾") func sidecarRenamePlan() { check(SelfTest.sidecarRenamePlan()) }
    @Test("UI-54 移到垃圾桶＋錄音中/轉稿中鎖") func sidecarTrashAndLock() { check(SelfTest.sidecarTrashAndLock()) }
    @Test("AFM-02 登錄表平台守門") func afmRegistry() { check(SelfTest.afmRegistry()) }
    @Test("AFM-04 token 估算") func afmTokenEstimate() { check(SelfTest.afmTokenEstimate()) }
    @Test("AFM-04 增量切段") func afmChunk() { check(SelfTest.afmChunk()) }
    @Test("AFM-04 上一版壓縮") func afmCompressPrevious() { check(SelfTest.afmCompressPrevious()) }
    @Test("AFM-04 筆記取尾") func afmNotesTail() { check(SelfTest.afmNotesTail()) }
    @Test("AFM-05 退讓計畫") func afmHalvePlan() { check(SelfTest.afmHalvePlan()) }
    @Test("AFM-01 狀態→訊息") func afmMessageMap() { check(SelfTest.afmMessageMap()) }
    @Test("AFM-12 校正子批") func afmCorrectionBatches() { check(SelfTest.afmCorrectionBatches()) }
    @Test("TRX-03 校正重套(窗內優先/全文後備/一行一次)") func transcriptHandoffReapply() { check(SelfTest.transcriptHandoffReapply()) }
    @Test("TRX-03 校正紀錄持久化往返") func transcriptHandoffPersist() { check(SelfTest.transcriptHandoffPersist()) }
    @Test("TRX-05 重轉政策遷移") func transcribePolicyMigration() { check(SelfTest.transcribePolicyMigration()) }
    @Test("TRX-06/08 閒置重轉判定＋卸載閘") func idleTranscribeDecision() { check(SelfTest.idleTranscribeDecision()) }
    // #949 第一段:唯一 writer 仲裁＋收割保護＋GUI／CLI 狀態同步(案例在 SelfTest+Lease.swift;暫存夾自建,不碰 ~/.config/myparrot)
    @Test("REC-34 state.json 新舊相容") func leaseStateCompat() { check(SelfTest.leaseStateCompat()) }
    @Test("REC-30 租約 acquire/release") func leaseAcquireRelease() { check(SelfTest.leaseAcquireRelease()) }
    @Test("REC-30 租約判定表") func leaseClassify() { check(SelfTest.leaseClassify()) }
    @Test("REC-38 心跳無回應") func heartbeatStale() { check(SelfTest.heartbeatStale()) }
    @Test("REC-31 inprogress 路徑＋發布檔名") func inprogressPathAndPublishName() { check(SelfTest.inprogressPathAndPublishName()) }
    @Test("REC-32 收割判定表") func reapDecisionTable() { check(SelfTest.reapDecisionTable()) }
    @Test("REC-33 太短進隔離區不刪") func quarantineInsteadOfDelete() { check(SelfTest.quarantineInsteadOfDelete()) }
    @Test("REC-36 指令檔生命週期") func commandLifecycle() { check(SelfTest.commandLifecycle()) }
    @Test("REC-40 協定檔在 <錄音夾>/.myparrot") func protocolDirRules() { check(SelfTest.protocolDirRules()) }
    @Test("REC-41 舊位置租約相容") func legacyLeaseFallback() { check(SelfTest.legacyLeaseFallback()) }
    // #2646 MAS-08:商店版純函式(案例在 SelfTest+MAS.swift;`MYPARROT_MAS=1 swift test` 也要綠)
    @Test("MAS-01 建置旗標對帳") func masBuildFlavor() { check(SelfTest.masBuildFlavor()) }
    @Test("MAS-07 書籤狀態機") func masBookmarkStateMachine() { check(SelfTest.masBookmarkStateMachine()) }
    @Test("MAS-14 登錄表不列 CLI 後端") func masRegistryWithoutCLI() { check(SelfTest.masRegistryWithoutCLI()) }
    @Test("MAS-14 外部指令在商店版忽略") func masExternalCommandIgnored() { check(SelfTest.masExternalCommandIgnored()) }
    @Test("MAS-12 模型 SHA-256 閘") func whisperChecksumGate() { check(SelfTest.whisperChecksumGate()) }
}
