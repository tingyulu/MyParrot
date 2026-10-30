import Foundation
import CryptoKit

/// BUG-39／CLT-01(公開倉 issue #1,2026-10-28):Whisper 模型大小檢查的單位。`approxMB` 與 `isValid` 必須同一個單位(十進位 MB),
/// 三個常數釘在 HuggingFace `ggerganov/whisper.cpp` 的 blob 位元數;正控＝舊常數 2,264,000,000 B 的 q5_0 必須被拒。
extension SelfTest {

    /// HF API(`?blobs=true`,2026-10-28 查)的 blob 位元數;改模型檔要連這張表一起改。
    static let whisperUpstreamBytes: [String: Int] = [
        "ggml-large-v3-turbo.bin": 1_624_555_275,
        "ggml-large-v3-q5_0.bin": 1_081_140_203,
        "ggml-large-v3.bin": 3_095_033_483
    ]

    static func whisperModelSize() -> Result {
        var fails: [String] = []
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp_whisper_size_\(UUID().uuidString)", isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            return Result(name: "CLT-01 Whisper 模型大小檢查單位", passed: false, detail: "暫存目錄建不出來:\(error)")
        }
        defer {
            if (try? FileManager.default.removeItem(at: dir)) == nil { print("⚠️ CLT-01 暫存目錄沒清掉:\(dir.path)") }
        }

        /// 稀疏檔:只設邏輯長度,不真的寫 3 GB。
        func sparse(_ name: String, bytes: Int) -> URL? {
            let u = dir.appendingPathComponent(name)
            guard FileManager.default.createFile(atPath: u.path, contents: nil),
                  let h = try? FileHandle(forWritingTo: u) else { return nil }
            defer { try? h.close() }
            do { try h.truncate(atOffset: UInt64(bytes)) } catch { return nil }
            return u
        }

        for m in WhisperModel.knownModels {
            guard let bytes = whisperUpstreamBytes[m.fileName] else { fails.append("\(m.id) 不在上游位元數表"); continue }
            // 1. 常數必須是十進位 MB、跟上游差 < 1 MB
            if abs(m.approxMB - Int((Double(bytes) / 1_000_000).rounded())) > 1 { fails.append("\(m.id) approxMB=\(m.approxMB) 不等於上游 \(bytes) B") }
            // 2. 上游位元數的檔必須通過
            guard let u = sparse(m.fileName, bytes: bytes) else { fails.append("建不出 \(m.fileName) 稀疏檔"); continue }
            if !WhisperModelStore.isValid(u, approxMB: m.approxMB) { fails.append("\(m.id) 上游大小 \(bytes) B 被拒") }
            // 3. 顯示字串的 GB 要跟常數一致(BUG-39 的 2.3GB)
            let gb = String(format: "%.1fGB", Double(m.approxMB) / 1000)
            if !m.display.contains(gb) { fails.append("\(m.id) 顯示「\(m.display)」缺 \(gb)") }
            // 4. ±10% 邊界(整數除法:approxMB*9/10 與 *11/10)
            let lo = m.approxMB * 9 / 10, hi = m.approxMB * 11 / 10
            for (factor, want) in [(0.89, false), (0.91, true), (1.09, true), (1.11, false)] {
                let b = Int(Double(m.approxMB) * factor * 1_000_000)
                guard let v = sparse("edge-\(m.id)-\(factor)", bytes: b) else { fails.append("\(m.id) ×\(factor) 邊界檔建不出,未執行"); continue }
                if WhisperModelStore.isValid(v, approxMB: m.approxMB) != want { fails.append("\(m.id) ×\(factor)(\(b / 1_000_000) MB,窗 \(lo)～\(hi))應\(want ? "收" : "拒")") }
            }
        }
        // 正控:舊常數 2264 MB 的 q5_0 檔必須被拒(若又把單位弄混,這條先紅);前置失敗也算失敗,不准靜默跳過
        if let q = WhisperModel.knownModels.first(where: { $0.id == "large-v3-q5_0" }) {
            if let bogus = sparse("bogus-q5", bytes: 2_264_000_000) {
                if WhisperModelStore.isValid(bogus, approxMB: q.approxMB) { fails.append("正控:2,264,000,000 B 的 q5_0 不該通過") }
            } else { fails.append("正控檔建不出來,正控未執行") }
        } else { fails.append("找不到 large-v3-q5_0,正控未執行") }
        // 邊界精確到位元(二審):1081 MB ⇒ 窗 (972.9, 1189.1) MB,972,900,001 B 收、972,900,000 B 拒
        if let q = WhisperModel.knownModels.first(where: { $0.id == "large-v3-q5_0" }) {
            let lo = Int64(q.approxMB) * 1_000_000 * 9 / 10
            for (b, want) in [(Int(lo) + 1, true), (Int(lo), false)] {
                if let u = sparse("exact-\(b)", bytes: b) {
                    if WhisperModelStore.isValid(u, approxMB: q.approxMB) != want { fails.append("精確邊界 \(b) B 應\(want ? "收" : "拒")") }
                } else { fails.append("精確邊界檔建不出來") }
            }
        }
        if (try? FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent("ggml-large-v3.bin").path)[.size] as? Int) != 3_095_033_483 {
            fails.append("稀疏檔 size 屬性不是邏輯長度,測試本身無效")
        }
        return Result(name: "CLT-01 Whisper 模型大小檢查單位", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "3 個上游位元數通過/顯示 GB 一致/±10% 四個邊界/正控 2264MB 拒" : fails.joined(separator: ";"))
    }
}

/// MAS-12(#2646,併 #2638 G-4):SHA-256 釘模型——hash 函式對已知向量、verify 正反、孤兒 .part 只清舊的、三個常數格式。
extension SelfTest {
    static func whisperChecksumGate() -> Result {
        var fails: [String] = []
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mp_whisper_sha_\(UUID().uuidString.prefix(8))", isDirectory: true)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch {
            return Result(name: "MAS-12 模型 SHA-256 閘", passed: false, detail: "暫存目錄建不出來:\(error)")
        }
        defer { try? FileManager.default.removeItem(at: dir) }
        let S = WhisperModelStore.self
        // 1. 已知向量:SHA-256("abc")
        let abc = dir.appendingPathComponent("abc.bin")
        try? Data("abc".utf8).write(to: abc)
        let want = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        if (try? S.sha256Hex(of: abc)) != want { fails.append("sha256(\"abc\") 應為 \(want.prefix(12))…,得 \((try? S.sha256Hex(of: abc)) ?? "nil")") }
        // 2. 多塊串流(> 1 MiB)跟一次算一樣
        let big = dir.appendingPathComponent("big.bin")
        var blob = Data(count: (1 << 20) + 12345); blob[0] = 7; blob[blob.count - 1] = 9
        try? blob.write(to: big)
        let direct = SHA256.hash(data: blob).map { String(format: "%02x", $0) }.joined()
        if (try? S.sha256Hex(of: big)) != direct { fails.append("串流 hash 與一次算不一致") }
        // 3. verify 正反(正控:錯 hash 必拒;大小寫不敏感)
        if !S.verify(abc, expectedSHA256: want.uppercased()) { fails.append("verify 正確 hash(大寫)應 true") }
        if S.verify(abc, expectedSHA256: String(want.dropLast()) + "e") { fails.append("verify 錯 hash 應 false(正控)") }
        if S.verify(dir.appendingPathComponent("nope.bin"), expectedSHA256: want) { fails.append("檔不存在應 false") }
        // 4. 孤兒 .part:舊的刪、新的留、.bin 不碰
        let now = Date()
        let oldPart = dir.appendingPathComponent("ggml-x.bin.part"), freshPart = dir.appendingPathComponent("ggml-y.bin.part"), oldBin = dir.appendingPathComponent("ggml-z.bin")
        for u in [oldPart, freshPart, oldBin] { try? Data("x".utf8).write(to: u) }
        try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: oldPart.path)
        try? FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3600)], ofItemAtPath: oldBin.path)
        let removed = S.removeOrphanParts(in: dir, olderThan: 600, now: now)
        if removed != ["ggml-x.bin.part"] { fails.append("應只刪舊的 .part,得 \(removed)") }
        if !FileManager.default.fileExists(atPath: freshPart.path) { fails.append("新的 .part(下載中)不該被刪") }
        if !FileManager.default.fileExists(atPath: oldBin.path) { fails.append(".bin 不該被刪") }
        // 5. 三個常數:64 碼小寫 hex、互不相同
        let hexes = WhisperModel.knownModels.map(\.sha256)
        for (m, h) in zip(WhisperModel.knownModels, hexes) where h.count != 64 || h.lowercased() != h || h.contains(where: { !$0.isHexDigit }) {
            fails.append("\(m.id) 的 sha256 常數格式不對")
        }
        if Set(hexes).count != hexes.count { fails.append("三個 sha256 常數有重複") }
        return Result(name: "MAS-12 模型 SHA-256 閘", passed: fails.isEmpty,
                      detail: fails.isEmpty ? "已知向量／串流／verify 正反／孤兒 .part 只清舊／常數格式 全過" : fails.joined(separator: ";"))
    }
}
