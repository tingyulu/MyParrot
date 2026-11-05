import Foundation

/// #2438 Phase 2(MIN-02／MIN-03):會議記錄的提示詞與輸出 schema。**沒有參數可以塞檔名、路徑、日期、裝置名**:
/// 使用者訊息只由 `MinutesInput` 的三段組成(上一版記錄的五格、新逐字稿行、筆記全文),簽章本身就是資料範圍的保證,
/// SelfTest 與假 CLI 腳本再釘一次。段落標記用語言中立的 `### …` 字串,系統提示負責解釋。
public enum MinutesPrompt {
    public static let previousMarker = "### PREVIOUS_MINUTES_JSON"
    public static let transcriptMarker = "### NEW_TRANSCRIPT"
    public static let notesMarker = "### USER_NOTES"
    public static let noneMarker = "(none)"

    public static let maxSummaryChars = 300
    public static let maxListItems = 12
    public static let maxTimelineItems = 20

    public static func system(for language: TranscriptionLanguage) -> String {
        switch language.isChinese {   // AFM-13:與 AFM 後端的 @Guide 描述共用同一個判準
        case true:
            return """
            你是會議記錄助手,負責維護一份「滾動更新」的結構化會議記錄。使用者訊息分三段:\(previousMarker)(上一版記錄,JSON;\(noneMarker) 表示尚無)、\(transcriptMarker)(自上次更新之後新增的逐字稿,每行＝講者 時間: 文字;\(noneMarker) 表示沒有新內容)、\(notesMarker)(使用者自己寫的筆記全文,可能沒有這段)。規則:1. 只依據這三段文字,不編造、不推測沒提到的事。2. 使用者筆記是人標的重點,優先級最高,筆記裡的事項一定要反映在對應欄位。3. 上一版已有的決議與待辦,除非新逐字稿明確推翻,否則保留並視需要補充。4. 時間軸每項以逐字稿行的時間 h:mm:ss 開頭,只記關鍵轉折。5. 用逐字稿的語言輸出。6. 摘要不超過 \(maxSummaryChars) 字;決議、待辦、待釐清各不超過 \(maxListItems) 項;時間軸不超過 \(maxTimelineItems) 項。7. 只回 JSON。
            """
        default:
            return """
            You maintain a rolling, structured set of meeting minutes. The user message has three sections: \(previousMarker) (the previous minutes as JSON; \(noneMarker) means none yet), \(transcriptMarker) (transcript lines added since the last update, each line = speaker time: text; \(noneMarker) means nothing new), and \(notesMarker) (the user's own notes in full; this section may be absent). Rules: 1. Use only these three sections; never invent or infer things not stated. 2. The user's notes are the human-marked priorities and must be reflected in the matching fields. 3. Keep decisions and action items from the previous version unless the new transcript clearly overturns them; extend them as needed. 4. Each timeline entry starts with the h:mm:ss time from the transcript line and records only key turning points. 5. Write in the transcript's language. 6. Summary at most \(maxSummaryChars) characters; decisions, action items and open questions at most \(maxListItems) entries each; timeline at most \(maxTimelineItems). 7. Reply with JSON only.
            """
        }
    }

    /// 使用者訊息:三段(筆記為空時整段省略)。
    public static func user(_ input: MinutesInput) -> String {
        var parts: [String] = []
        parts.append("\(previousMarker)\n\(previousJSON(input.previous) ?? noneMarker)")
        let delta = input.transcriptDelta.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        parts.append("\(transcriptMarker)\n\(delta.isEmpty ? noneMarker : delta.joined(separator: "\n"))")
        let notes = input.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if !notes.isEmpty { parts.append("\(notesMarker)\n\(notes)") }
        return parts.joined(separator: "\n\n")
    }

    /// 上一版記錄只送五格內容(不送 updatedAt、tokens、吃到的行數——那些是本機帳目)。
    public static func previousJSON(_ d: MinutesDocument?) -> String? {
        guard let d else { return nil }
        let obj: [String: Any] = ["summary": d.summary, "decisions": d.decisions, "actions": d.actions,
                                  "questions": d.questions, "timeline": d.timeline]
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    /// 結構化輸出的 JSON Schema:五格全必填、不准多欄。
    public static let schema = """
    {"type":"object","additionalProperties":false,"required":["summary","decisions","actions","questions","timeline"],"properties":{"summary":{"type":"string"},"decisions":{"type":"array","items":{"type":"string"}},"actions":{"type":"array","items":{"type":"string"}},"questions":{"type":"array","items":{"type":"string"}},"timeline":{"type":"array","items":{"type":"string"}}}}
    """
}
