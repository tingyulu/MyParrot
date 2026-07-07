import Foundation
import OpenCC

/// Whisper 模型管理(TR-16):App Support 模型目錄 + 下載/驗證。
/// 模型檔不進 repo、不進 iCloud。
public struct WhisperModel: Identifiable, Hashable, Sendable {
    public let id: String
    public let display: String
    public let fileName: String
    public let downloadURL: URL?
    public let approxMB: Int

    public static let knownModels: [WhisperModel] = [
        WhisperModel(id: "large-v3-turbo",
                     display: "large-v3-turbo(建議·1.6GB·快)",
                     fileName: "ggml-large-v3-turbo.bin",
                     downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-turbo.bin"),
                     approxMB: 1624),
        WhisperModel(id: "large-v3-q5_0",
                     display: "large-v3-q5_0(高精度·2.3GB)",
                     fileName: "ggml-large-v3-q5_0.bin",
                     downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3-q5_0.bin"),
                     approxMB: 2264),
        WhisperModel(id: "large-v3",
                     display: "large-v3(最高精度·3.1GB)",
                     fileName: "ggml-large-v3.bin",
                     downloadURL: URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin"),
                     approxMB: 3095)
    ]
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
    static func isValid(_ url: URL, approxMB: Int) -> Bool {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int else { return false }
        let mb = size / 1_048_576
        return mb > approxMB * 9 / 10 && mb < approxMB * 11 / 10
    }

    /// 下載模型(進度 0...1)。失敗丟錯;成功回傳落地 URL。
    public static func download(_ model: WhisperModel,
                                progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        guard let src = model.downloadURL else { throw "此模型無下載來源" }
        let dst = modelsDir.appendingPathComponent(model.fileName)
        let tmp = modelsDir.appendingPathComponent(model.fileName + ".part")
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
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
        try handle.close()
        guard isValid(tmp, approxMB: model.approxMB) else {
            try? FileManager.default.removeItem(at: tmp)
            throw "下載檔大小異常,已捨棄"
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
