import Foundation
import os

/// TR-31(#2676):停止後晚到的定稿要不要補寫回那一段的 `.txt`／`.srt`——純決策,不碰磁碟。
/// 控制器把「停止時寫了什麼、現在磁碟上是什麼、錄音還在不在列表」讀好再問它,理由字串直接進 log。
/// 真路徑上 Apple 引擎收尾只要 0.1 秒,「檔案已被動過」的分支在真機搶不到時間窗,靠這裡的 SelfTest 覆蓋。
enum LateLiveFlush {
    /// 磁碟上一份 sidecar 的現況。二審:「不存在」與「存在但讀不到／不是 UTF-8」不能混——後者一律不寫(寫了就是覆蓋別人的稿)。
    enum SidecarRead: Equatable, Sendable {
        case missing
        case content(String)
        case readFailure(String)
    }

    enum Decision: Equatable, Sendable {
        case write
        case skip(String)
    }

    /// - finalsAfter: 收尾後這一段的定稿行數;finalsAtStop: 停止當下已落檔的定稿行數。
    /// - writtenAtStop: 停止當下**成功**寫出的兩份內容;nil ＝ 當時沒寫(⇒ 現在兩個檔都必須不存在)。
    /// - txtOnDisk／srtOnDisk: 現在磁碟上的現況。
    static func decide(finalsAfter: Int, finalsAtStop: Int,
                       writtenAtStop: (txt: String, srt: String)?,
                       txtOnDisk: SidecarRead, srtOnDisk: SidecarRead,
                       recordingListed: Bool) -> Decision {
        guard finalsAfter > finalsAtStop else {
            return .skip("沒有多出定稿行(停止時 \(finalsAtStop)、收尾 \(finalsAfter))")
        }
        guard recordingListed else { return .skip("錄音已不在列表") }
        if case .readFailure(let why) = txtOnDisk { return .skip("現有 .txt 讀不到,不覆蓋:\(why)") }
        if case .readFailure(let why) = srtOnDisk { return .skip("現有 .srt 讀不到,不覆蓋:\(why)") }
        let expectTxt: SidecarRead = writtenAtStop.map { .content($0.txt) } ?? .missing
        let expectSrt: SidecarRead = writtenAtStop.map { .content($0.srt) } ?? .missing
        guard txtOnDisk == expectTxt, srtOnDisk == expectSrt else {
            return .skip(writtenAtStop == nil ? "停止時沒落檔,但現在已有逐字稿檔(重轉／校正／改過)"
                                             : "逐字稿檔已不是停止當下那份(重轉／校正／改過)")
        }
        return .write
    }

    /// 讀一份 sidecar 的現況:先問存在,存在才讀;讀失敗照實回 `.readFailure`(理由只帶 domain＋code,不帶路徑——會進 log)。
    static func read(_ url: URL) -> SidecarRead {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do { return .content(try String(contentsOf: url, encoding: .utf8)) }
        catch { let e = error as NSError; return .readFailure("\(e.domain) \(e.code)") }
    }
}

/// 逐字稿 `.txt`／`.srt` 成對寫入(TRX-01／TR-31 補寫／重轉三個呼叫端共用)。
/// 二審(TR-31 兩輪):兩份要嘛都換成新的、要嘛都維持原樣——第二份寫失敗就把第一份還原(原本有 ⇒ 寫回舊內容;原本沒有 ⇒ 移掉),
/// 還原也失敗再留一行 error log。單檔本身用 `atomically: true`。
enum TranscriptSidecarWriter {
    static func render(_ lines: [TranscriptLine]) -> (txt: String, srt: String) {
        (lines.map { "\($0.isYou ? "你" : "對方"): \($0.text)" }.joined(separator: "\n"), SRT.make(from: lines))
    }

    /// 回寫出的兩份內容;任一份失敗 ⇒ nil(已盡力還原、已 log)。
    static func write(_ lines: [TranscriptLine], stem: URL) -> (txt: String, srt: String)? {
        let txtURL = SidecarSet.url(stem: stem, ext: "txt"), srtURL = SidecarSet.url(stem: stem, ext: "srt")
        let out = render(lines)
        let fm = FileManager.default
        // 寫任何東西之前先確定還原得回去:既有 .txt 讀不出來(權限／I/O)⇒ 一份都不寫(二審第三輪)。
        let hadTxt = fm.fileExists(atPath: txtURL.path)
        let oldTxt: Data?
        do { oldTxt = hadTxt ? try Data(contentsOf: txtURL) : nil }
        catch {
            os_log(.error, "MyParrot: 既有逐字稿 .txt 備份不了(%{private}@),取消成對寫入、兩份都沒動", "\(error)")
            return nil
        }
        do {
            try out.txt.write(to: txtURL, atomically: true, encoding: .utf8)
        } catch {
            os_log(.error, "MyParrot: 逐字稿 .txt 寫入失敗(%{private}@),兩份都沒動", "\(error)")
            return nil
        }
        do {
            try out.srt.write(to: srtURL, atomically: true, encoding: .utf8)
        } catch {
            os_log(.error, "MyParrot: 逐字稿 .srt 寫入失敗(%{private}@),把 .txt 還原成寫入前", "\(error)")
            do {
                if let oldTxt { try oldTxt.write(to: txtURL, options: .atomic) } else { try fm.removeItem(at: txtURL) }
            } catch {
                os_log(.error, "MyParrot: 逐字稿 .txt 還原也失敗(%{private}@)——現在 .txt 是新內容、.srt 是舊的,請重轉這一筆", "\(error)")
            }
            return nil
        }
        return out
    }
}
