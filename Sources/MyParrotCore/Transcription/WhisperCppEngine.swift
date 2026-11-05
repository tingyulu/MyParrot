import Foundation
import whisper

/// whisper.cpp 推理引擎(Metal)。actor = 天然序列化:whisper context 非
/// thread-safe,live 兩聲道與 file 轉錄共用同一個 context 時逐一排隊。
/// 模型載入 lazy(turbo ~2-4s),第一次 transcribe 才付。
public actor WhisperCppEngine {

    public struct Segment: Sendable {
        public let text: String
        public let start: TimeInterval     // 秒(相對餵入音訊起點)
        public let duration: TimeInterval
    }

    /// context 裝箱:actor 的 deinit 是 nonisolated、碰不到 actor 屬性;
    /// 箱子自己的 deinit 負責 whisper_free(actor 釋放 → 箱子釋放 → context 釋放)。
    private final class CtxBox: @unchecked Sendable {
        var ptr: OpaquePointer?
        deinit { if let ptr { whisper_free(ptr) } }
    }

    /// BUG-27 殘留(#1697):退出時要能把跑到一半的 `whisper_full` 叫停。旗標由
    /// MainActor 設、由 whisper 的 abort_callback 在推理執行緒讀 ⇒ 不能是 actor
    /// 隔離狀態(actor 正被 whisper_full 佔著,誰也進不來),用自帶鎖的小箱子。
    final class AbortFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ v: Bool) { lock.lock(); value = v; lock.unlock() }
    }

    private let modelURL: URL
    private let box = CtxBox()
    private let abortFlag = AbortFlag()
    private var ctx: OpaquePointer? { box.ptr }

    public init(modelURL: URL) {
        self.modelURL = modelURL
    }

    /// 要求中斷目前這次推理(退出流程用)。nonisolated:呼叫端不必等 actor 空出來。
    public nonisolated func requestAbort() { abortFlag.set(true) }
    /// 解除中斷旗標(下一次轉稿前要清,否則會一直早退)。
    public nonisolated func clearAbort() { abortFlag.set(false) }
    public nonisolated var isAbortRequested: Bool { abortFlag.isSet }

    private func ensureLoaded() throws {
        guard box.ptr == nil else { return }
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true                       // Metal
        cparams.flash_attn = true
        guard let c = whisper_init_from_file_with_params(modelURL.path, cparams) else {
            throw "whisper 模型載入失敗:\(modelURL.lastPathComponent)"
        }
        box.ptr = c
    }

    /// 轉寫 16kHz mono Float 樣本。languageCode = whisper 語碼("zh"/"en"/…),
    /// nil = 自動偵測。prompt 用於中文引導繁體與語境(transcribe.sh 同款)。
    /// PERF-10(Z 節,Eric B1)11/04 真路徑試過 `audio_ctx` 依塊長縮窗＋`single_segment`:large-v3＋Metal＋flash_attn 下
    /// `single_segment` 吐亂碼且每塊 15 s,只縮 `audio_ctx` 每塊 1.35 s 對 1.18 s 沒有變快 ⇒ 不採,維持全窗(證據 TEST_REPORT「11/04 PERF」)。
    public func transcribe(samples16k: [Float],
                           languageCode: String?,
                           prompt: String?) throws -> [Segment] {
        try ensureLoaded()
        guard let ctx, samples16k.count > 1600 else { return [] }   // <0.1s 不轉

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_realtime = false
        params.print_progress = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.no_context = true          // 每塊獨立,防跨塊幻覺(live chunk 模式)
        params.suppress_blank = true
        params.temperature = 0
        params.no_speech_thold = 0.6      // 非語音(音樂/雜訊)信心門檻,見下方過濾
        params.n_threads = Int32(max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2)))

        // C 字串生命週期:strdup 持有到呼叫結束。
        let langC: UnsafeMutablePointer<CChar>? = languageCode.map { strdup($0) } ?? nil
        let promptC: UnsafeMutablePointer<CChar>? = prompt.map { strdup($0) } ?? nil
        defer { free(langC); free(promptC) }
        if let langC { params.language = UnsafePointer(langC) }
        if let promptC { params.initial_prompt = UnsafePointer(promptC) }

        // #1697:掛中斷 callback——whisper 每算完一層/一步會問一次「要不要停」,
        // 回 true 就讓 whisper_full 早退(rc≠0)。退出流程靠這個把 context 釋放掉,
        // 否則 exit() 會走到 ggml 的 Metal 全域解構 abort(BUG-27 殘留)。
        let flagRef = Unmanaged.passUnretained(abortFlag).toOpaque()
        params.abort_callback = { ud in
            guard let ud else { return false }
            return Unmanaged<AbortFlag>.fromOpaque(ud).takeUnretainedValue().isSet
        }
        params.abort_callback_user_data = flagRef

        let rc = samples16k.withUnsafeBufferPointer { buf in
            whisper_full(ctx, params, buf.baseAddress, Int32(buf.count))
        }
        if abortFlag.isSet { throw "whisper 轉稿已中斷(退出中)" }
        guard rc == 0 else { throw "whisper_full 失敗(rc=\(rc))" }

        let n = whisper_full_n_segments(ctx)
        var out: [Segment] = []
        out.reserveCapacity(Int(n))
        for i in 0..<n {
            // 幻覺防呆①:非語音音訊(音樂/雜訊)常被模型高信心誤判成語音——
            // 用 whisper 自帶的「這段其實不是語音」信心值濾掉,不上屏。
            guard whisper_full_get_segment_no_speech_prob(ctx, i) < params.no_speech_thold else { continue }
            guard let cText = whisper_full_get_segment_text(ctx, i) else { continue }
            let text = String(cString: cText).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let t0 = TimeInterval(whisper_full_get_segment_t0(ctx, i)) * 0.01   // 10ms 單位
            let t1 = TimeInterval(whisper_full_get_segment_t1(ctx, i)) * 0.01
            out.append(Segment(text: text, start: t0, duration: max(0.1, t1 - t0)))
        }
        return out
    }

    public func unload() {
        if let p = box.ptr { whisper_free(p) }
        box.ptr = nil
    }
}

/// Locale → whisper 語碼。
enum WhisperLang {
    static func code(for locale: Locale) -> String? {
        guard let lang = locale.language.languageCode?.identifier else { return nil }
        switch lang {
        case "zh": return "zh"
        case "en": return "en"
        case "ja": return "ja"
        case "ko": return "ko"
        default:   return nil          // 交給 whisper 自動偵測
        }
    }

    /// 中文引導 prompt(transcribe.sh 同款):偏繁體+容許英文夾雜。
    /// TR-26(2026-08-24):加會議場景領域詞——initial_prompt 是軟性先驗,詞真的出現
    /// 時大幅降低同音錯字(實測「逐字稿」不加必輸成「竹子稿」),沒出現時不會亂插。
    static func prompt(for code: String?) -> String? {
        // 注意:不可用「常見詞:A、B」清單格式——實測 whisper 會模仿冒號體,把
        // 「錄音:」當前綴插進輸出;要寫成自然敘述句。
        code == "zh" ? "以下是繁體中文的會議對話,可能會有英文夾雜,內容常提到錄音、逐字稿、會議記錄與摘要。" : nil
    }
}
