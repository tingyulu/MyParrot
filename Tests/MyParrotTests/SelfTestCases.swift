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
    @Test("回音消除(NLMS)合成驗證")    func echoCancel()       { check(SelfTest.echoCancel()) }
}
