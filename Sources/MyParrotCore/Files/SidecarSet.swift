import Foundation

/// 改名／移到垃圾桶失敗的原因(#2438 UI-53／UI-54)。App 層依 case 出在地化文案,Core 不放 UI 字串。
public enum SidecarError: Error, Equatable, Sendable {
    /// 標題空白或清理後是空的。
    case invalidTitle
    /// 新 stem 跟舊的一模一樣(含大小寫)——不用動。
    case unchanged
    /// 新 stem 的衍生檔已存在(檔名清單)。
    case conflict([String])
    /// 這個 stem 底下一個檔都沒有。
    case notFound
    /// 錄音中／轉檔中／轉稿中／排隊中,不能動。
    case locked
    /// 檔案系統操作失敗(已盡力回滾;訊息含原始錯誤與回滾結果)。
    case ioFailed(String)
}

/// 同一場錄音的檔案集合(同 stem 的錄音檔與所有 sidecar)。
///
/// **stem**＝錄音檔去掉副檔名的 URL,例如 `…/MyParrot/2026-10-19 1930 週會`;
/// 衍生檔＝`<stem>.<ext>`,ext 見 `extensions`(可含點,如 `notes.md`、`zh-Hant.srt`)。
/// 這裡全是 nonisolated 靜態函式,測試不必實例化 `RecordingController`(那會建 `~/Documents/MyParrot`)。
public enum SidecarSet {
    /// 單一真相(取代 `Recording.derivedExtensions`,後者改成轉呼叫):
    /// 錄音(caf/m4a)、逐字稿(txt/srt/json)、筆記(notes.md,L1 人寫)、會議記錄(minutes.md/minutes.json,L1 模型產)、
    /// 翻譯字幕(zh-Hant.srt,Phase 3)。
    public static let extensions = ["caf", "m4a", "txt", "srt", "json",
                                    "notes.md", "minutes.md", "minutes.json", "zh-Hant.srt",
                                    "corrections.json", "live.srt",   // #2483 C:校正紀錄、重轉前的即時稿
                                    "en.srt", "ja.srt", "ko.srt", "zh-Hans.srt", "es.srt", "de.srt", "fr.srt", "pt-BR.srt",   // #2612 TRL-08:其他目標語言的譯文檔
                                    "tokens.json"]   // #2623 TOK-01:每場模型用量帳本

    public typealias Move = (from: URL, to: URL)

    // MARK: 命名

    /// `<stem>.<ext>`。不用 `appendingPathExtension`,ext 含點也照字面接。
    public static func url(stem: URL, ext: String) -> URL {
        stem.deletingLastPathComponent().appendingPathComponent(stem.lastPathComponent + "." + ext)
    }

    /// 錄音檔 URL → stem。
    public static func stem(of recordingURL: URL) -> URL { recordingURL.deletingPathExtension() }

    /// 檔名開頭的「日期 時間 」前綴(`Recording.fileName` 的 `yyyy-MM-dd HHmm `)。
    private static let prefixRegex = try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2} \d{4} "#)

    /// 把 stem 名拆成(日期時間前綴, 標題部分)。沒有前綴(舊檔、使用者在 Finder 改過)⇒ prefix 為 nil、整串當標題。
    /// App 層改名對話框預填用 `title`,改名時前綴不動。
    public static func splitName(_ name: String) -> (prefix: String?, title: String) {
        let ns = name as NSString
        guard let m = prefixRegex.firstMatch(in: name, range: NSRange(location: 0, length: ns.length)) else {
            return (nil, name)
        }
        return (ns.substring(with: m.range), ns.substring(from: m.range.upperBound))
    }

    // MARK: 查詢

    /// 這個 stem 實際存在的衍生檔(依 `extensions` 順序)。
    public static func existing(stem: URL, fm: FileManager = .default) -> [URL] {
        extensions.map { url(stem: stem, ext: $0) }.filter { fm.fileExists(atPath: $0.path) }
    }

    /// 改名計畫:同 stem 的每個衍生檔 → 新 stem 的同 ext。
    /// - 標題過 `Recording.sanitizeTitle` 的清理;清理前後是空的 ⇒ `.invalidTitle`(不默默改成「錄音」)。
    /// - 日期時間前綴不動;stem 沒有前綴 ⇒ 新 stem＝清理後標題。
    /// - 新 stem 與舊的完全相同 ⇒ `.unchanged`;只差大小寫照常改(APFS 預設不分大小寫,同一檔不算衝突)。
    /// - 新 stem 的**任一**衍生檔(不只本場有的那幾種)已存在、且不是本場自己的檔 ⇒ `.conflict`(與 `uniqueFileName` 同口徑)。
    /// - 本場一個檔都沒有 ⇒ `.notFound`。
    public static func renamePlan(stem: URL, newTitle: String,
                                  fm: FileManager = .default) -> Result<[Move], SidecarError> {
        let cleaned = Recording.cleanedTitle(newTitle)
        guard !cleaned.isEmpty else { return .failure(.invalidTitle) }
        let (prefix, _) = splitName(stem.lastPathComponent)
        let newName = (prefix ?? "") + cleaned
        guard newName != stem.lastPathComponent else { return .failure(.unchanged) }
        let newStem = stem.deletingLastPathComponent().appendingPathComponent(newName)
        let sources = existing(stem: stem, fm: fm)
        guard !sources.isEmpty else { return .failure(.notFound) }
        var conflicts: [String] = []
        for ext in extensions {
            let target = url(stem: newStem, ext: ext)
            guard fm.fileExists(atPath: target.path) else { continue }
            // 只差大小寫/正規化時,目標「存在」其實就是來源自己 ⇒ 不算衝突。
            if sources.contains(where: { sameFile($0, target, fm: fm) }) { continue }
            conflicts.append(target.lastPathComponent)
        }
        guard conflicts.isEmpty else { return .failure(.conflict(conflicts)) }
        let moves: [Move] = extensions.compactMap { ext in
            let src = url(stem: stem, ext: ext)
            return fm.fileExists(atPath: src.path) ? (from: src, to: url(stem: newStem, ext: ext)) : nil
        }
        return .success(moves)
    }

    /// 移到垃圾桶的清單＝這個 stem 現有的所有衍生檔(App 層確認框列這份)。
    public static func trashPlan(stem: URL, fm: FileManager = .default) -> [URL] {
        existing(stem: stem, fm: fm)
    }

    /// 這筆能不能改名／丟垃圾桶。純函式:呼叫端把 `RecordingController` 的狀態換算成 stem 傳進來。
    /// - recordingStem:錄音中／暫停中那場(結束後傳 nil)。
    /// - transcribingStem:正在轉逐字稿那筆。
    /// - queuedStems:排隊等轉稿的。
    /// - convertingStems:caf→m4a 轉檔中(計畫沒列,保守加上;轉檔會在原 stem 寫 m4a 再刪 caf)。
    public static func isLocked(stem: URL, recordingStem: URL?, transcribingStem: URL?,
                                queuedStems: Set<URL>, convertingStems: Set<URL> = []) -> Bool {
        let key = normalized(stem)
        if let r = recordingStem, normalized(r) == key { return true }
        if let t = transcribingStem, normalized(t) == key { return true }
        if queuedStems.contains(where: { normalized($0) == key }) { return true }
        if convertingStems.contains(where: { normalized($0) == key }) { return true }
        return false
    }

    // MARK: 動作(真檔)

    /// 逐檔 `moveItem`(本身不覆蓋既有檔);中途失敗 ⇒ 已移的倒序移回,再丟 `.ioFailed`。
    public static func performRename(_ plan: [Move], fm: FileManager = .default) throws {
        var done: [Move] = []
        for m in plan {
            do {
                try fm.moveItem(at: m.from, to: m.to)
                done.append(m)
            } catch {
                let rollbackFailures = rollBack(done, fm: fm)
                throw SidecarError.ioFailed(describe(error, failedAt: m.from, rollbackFailures: rollbackFailures))
            }
        }
    }

    /// 逐檔 `trashItem`(可從垃圾桶救回;🚫 `removeItem`)。回傳每個檔在垃圾桶裡的 URL(與輸入同序)。
    /// 中途失敗 ⇒ 已丟的從垃圾桶移回原位,再丟 `.ioFailed`(不留「錄音進垃圾桶、逐字稿還在」的半套)。
    @discardableResult
    public static func performTrash(_ urls: [URL], fm: FileManager = .default) throws -> [URL] {
        var trashed: [Move] = []   // from＝原位、to＝垃圾桶裡
        for u in urls {
            do {
                var result: NSURL?
                try fm.trashItem(at: u, resultingItemURL: &result)
                guard let r = result as URL? else {
                    throw CocoaError(.fileWriteUnknown)
                }
                trashed.append((from: u, to: r))
            } catch {
                let rollbackFailures = rollBack(trashed, fm: fm)
                throw SidecarError.ioFailed(describe(error, failedAt: u, rollbackFailures: rollbackFailures))
            }
        }
        return trashed.map(\.to)
    }

    // MARK: 內部

    /// 把已完成的 move 倒序移回;回傳移不回去的檔名(空＝全部回滾成功)。
    private static func rollBack(_ done: [Move], fm: FileManager) -> [String] {
        var failures: [String] = []
        for m in done.reversed() {
            do { try fm.moveItem(at: m.to, to: m.from) } catch { failures.append(m.from.lastPathComponent) }
        }
        return failures
    }

    private static func describe(_ error: Error, failedAt url: URL, rollbackFailures: [String]) -> String {
        let rb = rollbackFailures.isEmpty ? "rollback ok" : "rollback failed: \(rollbackFailures.joined(separator: ", "))"
        return "\(url.lastPathComponent): \(error.localizedDescription) (\(rb))"
    }

    private static func normalized(_ u: URL) -> String { u.standardizedFileURL.path }

    /// 同一個檔(同 volume 同 inode)。檔不存在 ⇒ false。
    static func sameFile(_ a: URL, _ b: URL, fm: FileManager) -> Bool {
        guard let x = try? fm.attributesOfItem(atPath: a.path),
              let y = try? fm.attributesOfItem(atPath: b.path),
              let xi = x[.systemFileNumber] as? NSNumber, let yi = y[.systemFileNumber] as? NSNumber,
              let xv = x[.systemNumber] as? NSNumber, let yv = y[.systemNumber] as? NSNumber
        else { return false }
        return xi == yi && xv == yv
    }
}
