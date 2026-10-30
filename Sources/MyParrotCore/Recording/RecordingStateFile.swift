import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// #949 第一段:`~/.config/myparrot/` 共用目錄的位置(GUI 與 CLI 同一條規則)。
/// `MYPARROT_CONFIG_DIR` 覆寫(測試/示範夾/多執行個體用;CLI v1 已有,本段起 Core 也讀);
/// 未設＝`~/.config/myparrot`。直接 `getenv`(不經 `ProcessInfo.environment` 快取),
/// SelfTest 用 `setenv` 切換時才讀得到當下的值。`CLIConfigStore.configDir`、
/// `FiredReminderStore.configDir` 都轉呼叫這裡,三處不再各寫一份。
public enum MyParrotPaths {
    /// #2646 C2(Eric 2026-10-29 16:36;8/23 9.8):GUI×CLI×商店版的錄音**協定檔**(recording.lease／state.json／commands/)
    /// 從 `~/.config/myparrot` 搬到 **`<錄音夾>/.myparrot/`**——三方只要共用同一個錄音夾就互相看得到(商店版沙盒容器裡的
    /// ~/.config 外面看不到;inprogress 本來就在這裡)。「目前錄音夾」由 RecordingController(init／setRecordingsDir／
    /// revalidate)與 CLI(`resolvedRecordingsDir`)設定;沒設＝GUI 預設 `~/Documents/MyParrot`。
    /// `configDir`(`MYPARROT_CONFIG_DIR`)只剩舊版 CLI 的 `record.pid`(相容)與行事曆提醒的 fired 記錄。
    nonisolated(unsafe) private static var _currentRecordingsDir: URL?
    private static let recordingsLock = NSLock()
    public static var currentRecordingsDir: URL {
        get { recordingsLock.withLock { _currentRecordingsDir } ?? defaultRecordingsDir }
        set { recordingsLock.withLock { _currentRecordingsDir = newValue } }
    }
    public static var defaultRecordingsDir: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("MyParrot", isDirectory: true)
    }
    /// 純函式:錄音夾 ⇒ 協定目錄 `<錄音夾>/.myparrot`。
    public static func protocolDir(for recordingsDir: URL) -> URL {
        recordingsDir.appendingPathComponent(".myparrot", isDirectory: true)
    }
    public static var protocolDir: URL { protocolDir(for: currentRecordingsDir) }

    public static var configDir: URL {
        if let raw = getenv("MYPARROT_CONFIG_DIR") {
            let s = String(cString: raw)
            if !s.isEmpty {
                return URL(fileURLWithPath: (s as NSString).expandingTildeInPath, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/myparrot", isDirectory: true)
    }
}

/// `state.json` 的內容(§2.3 of CLI v1 ＋ #949 第一段擴欄位)。由**錄音的 owner** 寫(GUI 或 CLI),
/// 非 owner 只讀。舊欄位一個不少、意義不變 ⇒ 2026-08-10 的舊 CLI 讀新檔照樣解得開(多的欄位 Codable 忽略);
/// 新欄位在舊檔裡不存在時給預設值(owner 預設 "cli":新版之前只有 CLI 會寫這個檔)。
public struct RecordingStateFile: Codable, Equatable, Sendable {
    public var pid: Int32
    public var startedAt: String
    public var audioPath: String
    public var name: String
    /// "recording" | "paused" | "stopping" | "postprocessing"
    public var state: String
    public var levels: Levels
    public var warning: String?
    public var updatedAt: String
    // #949 第一段新增
    /// "gui" | "cli"
    public var owner: String
    public var sessionId: String
    public var elapsed: Double
    public var paused: Bool
    public var markers: Int
    /// 舊檔沒有這欄 ⇒ 0;新版寫 1。
    public var protocolVersion: Int

    public struct Levels: Codable, Equatable, Sendable {
        public var other: Double
        public var you: Double
        public var otherSignal: Bool
        public var youSignal: Bool

        public init(other: Double = 0, you: Double = 0, otherSignal: Bool = false, youSignal: Bool = false) {
            self.other = other; self.you = you; self.otherSignal = otherSignal; self.youSignal = youSignal
        }
    }

    public init(pid: Int32, startedAt: String, audioPath: String, name: String, state: String,
                levels: Levels, warning: String?, updatedAt: String,
                owner: String = "cli", sessionId: String = "", elapsed: Double = 0, paused: Bool? = nil,
                markers: Int = 0, protocolVersion: Int = RecordingStateFile.currentProtocolVersion) {
        self.pid = pid; self.startedAt = startedAt; self.audioPath = audioPath; self.name = name
        self.state = state; self.levels = levels; self.warning = warning; self.updatedAt = updatedAt
        self.owner = owner; self.sessionId = sessionId; self.elapsed = elapsed
        self.paused = paused ?? (state == "paused")
        self.markers = markers; self.protocolVersion = protocolVersion
    }

    public static let currentProtocolVersion = 1

    private enum CodingKeys: String, CodingKey {
        case pid, startedAt, audioPath, name, state, levels, warning, updatedAt
        case owner, sessionId, elapsed, paused, markers, protocolVersion
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        pid = try c.decode(Int32.self, forKey: .pid)
        startedAt = try c.decode(String.self, forKey: .startedAt)
        audioPath = try c.decode(String.self, forKey: .audioPath)
        name = try c.decode(String.self, forKey: .name)
        state = try c.decode(String.self, forKey: .state)
        levels = try c.decode(Levels.self, forKey: .levels)
        warning = try c.decodeIfPresent(String.self, forKey: .warning)
        updatedAt = try c.decode(String.self, forKey: .updatedAt)
        owner = try c.decodeIfPresent(String.self, forKey: .owner) ?? "cli"
        sessionId = try c.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
        elapsed = try c.decodeIfPresent(Double.self, forKey: .elapsed) ?? 0
        paused = try c.decodeIfPresent(Bool.self, forKey: .paused) ?? (state == "paused")
        markers = try c.decodeIfPresent(Int.self, forKey: .markers) ?? 0
        protocolVersion = try c.decodeIfPresent(Int.self, forKey: .protocolVersion) ?? 0
    }
}

/// 原子寫檔(temp 檔 + rename,同磁區 rename 是原子操作)——config/state/commands 共用。
public enum AtomicFile {
    public static func write(_ data: Data, to url: URL) throws {
        let tmp = url.appendingPathExtension("tmp-\(UUID().uuidString.prefix(8))")
        try data.write(to: tmp, options: .atomic)
        if FileManager.default.fileExists(atPath: url.path) {
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } else {
            try FileManager.default.moveItem(at: tmp, to: url)
        }
    }
}

/// `record.pid` ＋ `state.json`(CLI v1 §2.2/§2.3,#949 起搬進 Core,GUI 當 owner 時也寫 state.json)。
/// 每個函式都可傳 `dir`(SelfTest 用暫存夾,不碰真的 `~/.config/myparrot`);不傳＝`MyParrotPaths.configDir`。
/// 舊名(`writeState`/`readState`)保留給 CLI 既有呼叫點;規格名 `write`/`read`/`cleanup` 同義。
public enum RecordingStateStore {
    /// 舊版 `record.pid` 的家(`MYPARROT_CONFIG_DIR`);C2 後只剩它留在這裡。
    public static var configDir: URL { MyParrotPaths.configDir }
    /// C2:`state.json` 跟租約一起住 `<錄音夾>/.myparrot/`。
    public static var protocolDir: URL { MyParrotPaths.protocolDir }
    public static var pidfilePath: URL { pidfilePath(in: configDir) }
    public static var statePath: URL { statePath(in: protocolDir) }
    public static func pidfilePath(in dir: URL) -> URL { dir.appendingPathComponent("record.pid") }
    public static func statePath(in dir: URL) -> URL { dir.appendingPathComponent("state.json") }

    /// stale 判定:`kill(pid, 0)` 失敗(ESRCH 等)→ 該 pid 已不存在(CLI-02)。
    public static func isStalePID(_ pid: Int32) -> Bool {
        kill(pid_t(pid), 0) != 0
    }

    public static func readPID(in dir: URL = configDir) -> Int32? {
        guard let s = try? String(contentsOf: pidfilePath(in: dir), encoding: .utf8) else { return nil }
        return Int32(s.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 目前錄音中的 CLI pid;stale pidfile 會被當場清掉(CLI v1 §2.2)。nil = 沒有 CLI 在錄。
    public static func activePID(in dir: URL = configDir) -> Int32? {
        guard let pid = readPID(in: dir) else { return nil }
        if isStalePID(pid) {
            // #949:state.json 現在也可能是 GUI owner 的 ⇒ 只在它是這個死掉 pid 寫的時候才一起清。
            try? FileManager.default.removeItem(at: pidfilePath(in: dir))
            if let s = read(in: dir), s.pid == pid { try? FileManager.default.removeItem(at: statePath(in: dir)) }
            return nil
        }
        return pid
    }

    public static func writePID(_ pid: Int32, in dir: URL = configDir) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try AtomicFile.write(Data(String(pid).utf8), to: pidfilePath(in: dir))
    }

    public static func write(_ state: RecordingStateFile, in dir: URL = protocolDir) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(state)
        try AtomicFile.write(data, to: statePath(in: dir))
    }

    public static func read(in dir: URL = protocolDir) -> RecordingStateFile? {
        guard let data = try? Data(contentsOf: statePath(in: dir)) else { return nil }
        return try? JSONDecoder().decode(RecordingStateFile.self, from: data)
    }

    public static func writeState(_ state: RecordingStateFile) throws { try write(state) }
    public static func readState() -> RecordingStateFile? { read() }

    /// CLI 錄音進程正常退出時清兩檔(§2.3)。
    /// 不給 dir ＝ 各回各家:record.pid 在 configDir、state.json 在 protocolDir(C2);給 dir ＝ 兩檔都在那(SelfTest 暫存夾)。
    public static func cleanup(in dir: URL? = nil) {
        try? FileManager.default.removeItem(at: pidfilePath(in: dir ?? configDir))
        try? FileManager.default.removeItem(at: statePath(in: dir ?? protocolDir))
    }

    /// GUI owner 收尾:只清 state.json,而且只在檔裡的 sessionId 是自己那場時才清——
    /// 不碰 `record.pid`(那是 CLI 的;同時有舊 CLI 在錄時刪掉它會讓 `myparrot stop` 找不到人)。
    public static func cleanupState(ifSession sessionId: String, in dir: URL = protocolDir) {
        guard let s = read(in: dir), s.sessionId == sessionId else { return }
        try? FileManager.default.removeItem(at: statePath(in: dir))
    }

    /// #949:CLI 開錄失敗時只清**自己寫的** record.pid(檔裡是自己的 pid 才刪);state.json 不動(可能是 GUI owner 的)。
    public static func removePIDFile(ifPID pid: Int32, in dir: URL = configDir) {
        guard readPID(in: dir) == pid else { return }
        try? FileManager.default.removeItem(at: pidfilePath(in: dir))
    }
}

/// ISO8601 字串工具——state.json/租約/JSON 事件的時間欄位統一格式(含小數秒,固定長度)。
/// `ISO8601DateFormatter` 不是 Sendable,不快取成 static let;呼叫頻率(1Hz 級)重建成本可忽略。
public enum ISO8601 {
    public static func string(_ date: Date = Date()) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    /// 反解(含/不含小數秒都收);解不開 ⇒ nil。
    public static func date(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}
