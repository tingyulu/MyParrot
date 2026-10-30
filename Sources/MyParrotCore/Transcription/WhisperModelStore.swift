import Foundation
import CryptoKit
import OpenCC

/// Whisper 模型管理(TR-16):App Support 模型目錄 + 下載/驗證。
/// 模型檔不進 repo、不進 iCloud。
public struct WhisperModel: Identifiable, Hashable, Sendable {
    public let id: String
    public let display: String
    public let fileName: String
    public let downloadURL: URL?
    /// 十進位 MB(10^6,跟 HuggingFace 顯示同單位);值釘在上游 blob 位元數(SelfTest `whisperUpstreamBytes`)。
    /// BUG-39:曾是 MB 常數配 MiB 比較,q5_0 常數又抄錯(2264),永遠裝不起來。
    public let approxMB: Int
    /// MAS-12(#2646,併 #2638 G-4):上游 blob 的 SHA-256(HuggingFace LFS pointer `oid sha256:`,2026-10-29 查);
    /// 下載完整檔先算 hash 再搬進位,不符就刪掉不留半檔。改模型檔要連這個一起改(SelfTest `whisperChecksumGate` 查格式)。
    public let sha256: String

    // l10n-keys:begin(BUG-28:display 會顯示在設定頁,括號內說明要跟介面語言)
    public static let knownModels: [WhisperModel] = [
        WhisperModel(id: "large-v3-turbo",
                     display: "large-v3-turbo(建議·1.6GB·快)",
                     fileName: "ggml-large-v3-turbo.bin",
                     downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"),
                     approxMB: 1625,
                     sha256: "1fc70f774d38eb169993ac391eea357ef47c88757ef72ee5943879b7e8e2bc69"),
        WhisperModel(id: "large-v3-q5_0",
                     display: "large-v3-q5_0(高精度·1.1GB)",
                     fileName: "ggml-large-v3-q5_0.bin",
                     downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin"),
                     approxMB: 1081,
                     sha256: "d75795ecff3f83b5faa89d1900604ad8c780abd5739fae406de19f23ecd98ad1"),
        WhisperModel(id: "large-v3",
                     display: "large-v3(最高精度·3.1GB)",
                     fileName: "ggml-large-v3.bin",
                     downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin"),
                     approxMB: 3095,
                     sha256: "64d182b440b98d5203c4f9bd541544d84c605196c4f7b845dfa11fb23594d1e2")
    ]
    // l10n-keys:end
}

public enum WhisperModelStore {

    public static var modelsDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("MyParrot/models", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 已安裝(可用)模型:App Support 內的已知模型。
    public static func installed() -> [(model: WhisperModel, url: URL)] {
        var out: [(WhisperModel, URL)] = []
        for m in WhisperModel.knownModels {
            let u = modelsDir.appendingPathComponent(m.fileName)
            if isValid(u, approxMB: m.approxMB) { out.append((m, u)) }
        }
        return out
    }

    /// 現用模型:設定偏好 → turbo → 其他任一。nil = 未安裝(引導下載,引擎 fallback)。
    public static func activeModelURL() -> URL? {
        let inst = installed()
        if let pref = UserDefaults.standard.string(forKey: "whisperModel"),
           let hit = inst.first(where: { $0.model.id == pref }) { return hit.url }
        if let turbo = inst.first(where: { $0.model.id == "large-v3-turbo" }) { return turbo.url }
        return inst.first?.url
    }

    /// 輕量完整性:存在 + 大小落在期望值 ±10%(TR-16;不做逐位 hash,3GB 檔太慢)。
    /// 單位＝十進位 MB,與 `approxMB` 同單位(BUG-39／CLT-01:之前除 1,048,576 算 MiB,q5_0 必落在窗外);
    /// 用位元數比,不先截成整數 MB(二審:兩邊截斷會讓窗偏掉 1 MB)。只是大小檢查,不是完整性驗證(不驗 hash)。
    static func isValid(_ url: URL, approxMB: Int) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attrs[.size] as? NSNumber)?.int64Value else { return false }
        let expected = Int64(approxMB) * 1_000_000
        return size > expected * 9 / 10 && size < expected * 11 / 10
    }

    // MARK: - MAS-12 SHA-256 釘模型(#2646,併 #2638 G-4)

    /// Core 繁中句(GUI 經 CoreMessageL10n 依介面語言重組)。
    public static let checksumFailedMessage = "模型校驗失敗(SHA-256 不符),已捨棄"

    /// 串流算整檔 SHA-256(1 MiB 一塊,3 GB 檔不會整個進記憶體);小寫 hex。
    public static func sha256Hex(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var hasher = SHA256()
        while true {
            let chunk = try h.read(upToCount: 1 << 20) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 二審:讀檔錯(I/O)與 hash 不符要分開——前者不是供應鏈問題,訊息不能一律寫「校驗失敗」。
    public enum ChecksumResult: Equatable, Sendable {
        case ok
        case mismatch(actual: String)
        case ioError(String)
    }
    public static func checksum(_ url: URL, expectedSHA256: String) -> ChecksumResult {
        do {
            let hex = try sha256Hex(of: url)
            return hex == expectedSHA256.lowercased() ? .ok : .mismatch(actual: hex)
        } catch {
            return .ioError("\(error)")
        }
    }
    /// 檔案 hash 是否等於期望(大小寫不敏感);讀不到檔＝false(只給「已裝清單」這種布林用途;要分錯誤型用 `checksum`)。
    public static func verify(_ url: URL, expectedSHA256: String) -> Bool { checksum(url, expectedSHA256: expectedSHA256) == .ok }

    /// 啟動時掃孤兒 `.part`(上次下載中途崩潰／被殺留下的半檔):只刪 mtime 早於 `olderThan` 的(正在下載的檔每秒都在長,
    /// mtime 是新的,不會被誤刪)。回傳刪掉的檔名。`dir` 可注入給 SelfTest。
    /// 二審補:下載中的 `.part` 由下載端持 `flock`;清理端鎖不到就跳過(別的進程還在寫),鎖得到且太舊才刪。
    @discardableResult
    public static func removeOrphanParts(in dir: URL = modelsDir, olderThan: TimeInterval = 600, now: Date = Date()) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        var removed: [String] = []
        for name in names where name.hasSuffix(".part") {
            let u = dir.appendingPathComponent(name)
            let mtime = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date ?? now
            guard now.timeIntervalSince(mtime) > olderThan else { continue }
            let fd = open(u.path, O_RDONLY | O_NOFOLLOW)
            guard fd >= 0 else { continue }
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); continue }   // 有人持鎖＝還在下載
            if (try? FileManager.default.removeItem(at: u)) != nil { removed.append(name) }
            close(fd)   // close 連帶放鎖
        }
        return removed
    }

    /// 下載模型(進度 0...1)。失敗丟錯;成功回傳落地 URL。
    /// MAS-12:大小窗過了再算 SHA-256(進度停在 0.99 那幾秒就是在算),不符 ⇒ 刪 .part、丟 `checksumFailedMessage`,不留半檔。
    public static func download(_ model: WhisperModel,
                                progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let src = model.downloadURL else { throw "此模型無下載來源" }
        let dst = modelsDir.appendingPathComponent(model.fileName)
        let tmp = modelsDir.appendingPathComponent(model.fileName + ".part")
        // 二審:先開檔(不截斷)、拿 flock,拿到才 ftruncate——同一個 .part 若被另一個進程／實例下載中,這裡會拿不到鎖而退出,
        // 不會把對方寫一半的檔截成 0;鎖跟著 handle,函式結束(成功搬走或失敗)就放。
        let fd = open(tmp.path, O_WRONLY | O_CREAT | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw "無法建立下載暫存檔:\(String(cString: strerror(errno)))" }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw "這個模型正由另一個程序下載中" }
        guard ftruncate(fd, 0) == 0 else { close(fd); throw "無法清空下載暫存檔" }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }

        let (bytes, response) = try await URLSession.shared.bytes(from: src)
        let total = response.expectedContentLength
        var written: Int64 = 0
        var chunk = Data(capacity: 1 << 20)
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count >= 1 << 20 {
                try handle.write(contentsOf: chunk)
                written += Int64(chunk.count)
                chunk.removeAll(keepingCapacity: true)
                if total > 0 { progress(Double(written) / Double(total)) }
            }
        }
        try handle.write(contentsOf: chunk)
        written += Int64(chunk.count)
        try handle.synchronize()   // 鎖要留到搬走;不在這裡 close
        guard isValid(tmp, approxMB: model.approxMB) else {
            try? FileManager.default.removeItem(at: tmp)
            throw "下載檔大小異常,已捨棄"
        }
        progress(0.99)
        switch checksum(tmp, expectedSHA256: model.sha256) {
        case .ok: break
        case .mismatch:
            try? FileManager.default.removeItem(at: tmp)
            throw checksumFailedMessage
        case .ioError(let e):
            try? FileManager.default.removeItem(at: tmp)
            throw "讀取下載檔失敗:\(e)"
        }
        try? FileManager.default.removeItem(at: dst)
        try FileManager.default.moveItem(at: tmp, to: dst)
        progress(1.0)
        return dst
    }

    public static func delete(_ model: WhisperModel) {
        try? FileManager.default.removeItem(at: modelsDir.appendingPathComponent(model.fileName))
    }
}

/// 簡→繁(台灣正體+慣用詞)。whisper 中文輸出常是簡體(TR-17),
/// transcribe.sh 的 opencc s2twp 配方 in-app 化。
enum ZhTW {
    // 一次建立後只讀;ChineseConverter.convert 無共享可變狀態,跨緒唯讀安全。
    nonisolated(unsafe) private static let converter: ChineseConverter? =
        try? ChineseConverter(options: [.traditionalize, .twStandard, .twIdiom])

    /// 僅中文場景呼叫;converter 建立失敗時原樣通過(不擋轉錄)。
    static func convert(_ text: String) -> String {
        converter?.convert(text) ?? text
    }
}
