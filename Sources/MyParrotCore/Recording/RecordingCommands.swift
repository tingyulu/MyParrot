import Foundation

/// #949 第一段 REC-36:單向指令檔 `~/.config/myparrot/commands/<requestId>.json`。
/// 非 owner 端寫(stop／pause／resume／mark／title),owner 端每 1 秒輪詢、依序執行後改成
/// `<requestId>.done`(成功)或 `.failed`(失敗),內容 `{ok,result,at}`。第二段的 socket 只是更快的通道,真相仍是這裡。
public struct RecordingCommand: Codable, Sendable, Equatable {
    public var cmd: String
    public var requestId: String
    public var issuedAt: String
    public var args: [String: String]

    public init(cmd: String, args: [String: String] = [:], requestId: String = UUID().uuidString,
                issuedAt: String = ISO8601.string()) {
        self.cmd = cmd; self.args = args; self.requestId = requestId; self.issuedAt = issuedAt
    }

    /// 第一段支援的指令。
    public static let supported: Set<String> = ["stop", "pause", "resume", "mark", "title"]

    /// owner 該不該執行這張指令(純函式):指定了別場 sessionId ⇒ 不是給我的;在本場開錄之前就發出 ⇒ 過期
    /// (例如上一場逾時沒人收的 stop,不能把新的一場停掉)。回傳 nil＝可以執行,否則是拒絕原因。
    /// C2 二審補:指令檔住在可能被同步的錄音夾,超過 `maxAge`(預設 120 秒)的指令一律當過期(同步延遲／重放)。
    public static let maxAge: TimeInterval = 120
    public static func rejection(_ cmd: RecordingCommand, sessionId: String, sessionStartedAt: Date,
                                 now: Date = Date(), maxAge: TimeInterval = maxAge) -> String? {
        if let target = cmd.args["sessionId"], !target.isEmpty, target != sessionId { return "不是這一場的指令(\(target))" }
        if let issued = ISO8601.date(cmd.issuedAt), issued < sessionStartedAt.addingTimeInterval(-1) { return "指令早於本場開錄,已過期" }
        if let issued = ISO8601.date(cmd.issuedAt), now.timeIntervalSince(issued) > maxAge { return "指令超過 \(Int(maxAge)) 秒,已過期" }
        if !supported.contains(cmd.cmd) { return "不支援的指令:\(cmd.cmd)" }
        return nil
    }
}

/// `.done`／`.failed` 的內容。
public struct RecordingCommandResult: Codable, Sendable, Equatable {
    public var ok: Bool
    public var result: String
    public var at: String
}

public enum RecordingCommandStore {
    /// `~/.config/myparrot/commands`(`MYPARROT_CONFIG_DIR` 覆寫)。
    /// C2(#2646):`<錄音夾>/.myparrot/commands/`(之前在 ~/.config/myparrot/commands)。
    public static func directory() -> URL {
        MyParrotPaths.protocolDir.appendingPathComponent("commands", isDirectory: true)
    }

    static func url(_ requestId: String, _ ext: String, in dir: URL) -> URL {
        dir.appendingPathComponent("\(requestId).\(ext)")
    }

    /// 寫 `<requestId>.json`(AtomicFile:temp＋rename,owner 不會讀到半截)。
    @discardableResult
    public static func issue(_ cmd: RecordingCommand, in dir: URL = directory()) throws -> URL {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = url(cmd.requestId, "json", in: dir)
        try AtomicFile.write(try JSONEncoder().encode(cmd), to: dest)
        return dest
    }

    /// 只列 `.json`(待處理),依發出時間排序;解不開的檔略過。
    public static func pending(in dir: URL = directory()) -> [RecordingCommand] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.filter { $0.hasSuffix(".json") }.compactMap { name in
            guard let data = FileManager.default.contents(atPath: dir.appendingPathComponent(name).path) else { return nil }
            return try? JSONDecoder().decode(RecordingCommand.self, from: data)
        }.sorted { $0.issuedAt < $1.issuedAt }
    }

    /// 處理完:寫 `<requestId>.done`／`.failed`(內容 `{ok,result,at}`)再刪 `.json`——等同「改名＋寫結果」。
    public static func complete(_ requestId: String, ok: Bool, result: String, in dir: URL = directory()) {
        let res = RecordingCommandResult(ok: ok, result: result, at: ISO8601.string())
        if let data = try? JSONEncoder().encode(res) {
            try? AtomicFile.write(data, to: url(requestId, ok ? "done" : "failed", in: dir))
        }
        try? FileManager.default.removeItem(at: url(requestId, "json", in: dir))
    }

    /// 讀結果(還沒處理＝nil)。
    public static func result(_ requestId: String, in dir: URL = directory()) -> RecordingCommandResult? {
        for ext in ["done", "failed"] {
            if let data = FileManager.default.contents(atPath: url(requestId, ext, in: dir).path),
               let r = try? JSONDecoder().decode(RecordingCommandResult.self, from: data) { return r }
        }
        return nil
    }

    /// 每 0.2 秒看一次:有 `.done`／`.failed`,或租約不再活著(owner 已收尾/死了)⇒ true;逾時 ⇒ false。
    /// `leaseDir` 預設＝`dir` 的上一層(`~/.config/myparrot`)。
    public static func wait(_ requestId: String, timeout: TimeInterval, in dir: URL = directory(),
                            leaseDir: URL? = nil) -> Bool {
        let ld = leaseDir ?? dir.deletingLastPathComponent()
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if result(requestId, in: dir) != nil { return true }
            if case .alive = RecordingLeaseHolder.inspect(in: ld) {} else { return true }
            if Date() >= deadline { return false }
            Thread.sleep(forTimeInterval: 0.2)
        }
    }

    /// 清掉超過 `olderThan` 秒的 `.done`／`.failed`,以及沒人收的過期 `.json`。
    public static func purge(olderThan: TimeInterval = 3600, in dir: URL = directory(), now: Date = Date()) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names where name.hasSuffix(".done") || name.hasSuffix(".failed") || name.hasSuffix(".json") {
            let u = dir.appendingPathComponent(name)
            guard let m = (try? FileManager.default.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date else { continue }
            if now.timeIntervalSince(m) > olderThan { try? FileManager.default.removeItem(at: u) }
        }
    }
}
