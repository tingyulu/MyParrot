import Foundation
import CryptoKit
import ArgumentParser
import MyParrotCore
#if canImport(Darwin)
import Darwin
#endif

/// SHA256 hex digest——用 Apple 官方 CryptoKit(macOS SDK 內建,零新依賴),
/// 不需要另拉 swift-crypto 套件。
enum SHA256Hex {
    static func hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// `~/.config/myparrot/config.json` schema(§2.1)+ 讀寫 + keypath get/set + hooks
/// trust-on-first-use(§8)。全欄位皆 optional;未知欄位 Codable 預設就忽略不報錯。
///
/// **技術選型偏離**:plan 沒定義 config 目錄可覆蓋的 env,測試需要不動到 Eric
/// 真正的 `~/.config/myparrot`(GUI-verify-discipline 教訓:改機上狀態的測試要
/// 能還原)——故自行加入 `MYPARROT_CONFIG_DIR`(未設時=原生預設路徑,行為不變)。
struct HookSpec: Codable, Equatable {
    var command: String
    var cwd: String?
    var timeout: HookTimeout
    var auto: Bool
    var strict: Bool

    init(command: String, cwd: String? = nil, timeout: HookTimeout = .auto,
         auto: Bool = false, strict: Bool = false) {
        self.command = command
        self.cwd = cwd
        self.timeout = timeout
        self.auto = auto
        self.strict = strict
    }
}

/// `"auto"`(=max(600s,音長×4))｜`0`(不限時,以 `.seconds(0)` 表示)｜`<秒數>`。
enum HookTimeout: Equatable {
    case auto
    case seconds(Double)
}

extension HookTimeout: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            guard s == "auto" else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "timeout 字串只接受 \"auto\"")
            }
            self = .auto
            return
        }
        let n = try c.decode(Double.self)
        self = .seconds(n)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .auto: try c.encode("auto")
        case .seconds(let n): try c.encode(n)
        }
    }

    /// 純函式,CLI-01 SelfTest 覆蓋:`.auto` → max(600, 音長秒×4);`.seconds(0)` →
    /// nil(不限時);其他 → 原秒數。
    func resolvedSeconds(audioDurationSec: Double) -> Double? {
        switch self {
        case .auto: return max(600, audioDurationSec * 4)
        case .seconds(let n): return n == 0 ? nil : n
        }
    }
}

struct CLIConfigSchema: Codable, Equatable {
    var recordingsDir: String?
    var mic: String?
    var engine: String?          // "apple" | "whisper"
    var language: String?        // TranscriptionLanguage.rawValue 或常見別名(見 parseLanguage)
    var autoTranscribe: Bool?
    var hooks: [String: HookSpec]?

    init(recordingsDir: String? = nil, mic: String? = nil, engine: String? = nil,
         language: String? = nil, autoTranscribe: Bool? = nil, hooks: [String: HookSpec]? = nil) {
        self.recordingsDir = recordingsDir
        self.mic = mic
        self.engine = engine
        self.language = language
        self.autoTranscribe = autoTranscribe
        self.hooks = hooks
    }
}

enum ConfigError: Error, CustomStringConvertible {
    case invalidPath(String)
    case invalidValue(String, String)

    var description: String {
        switch self {
        case .invalidPath(let p): return "未知設定路徑:\(p)"
        case .invalidValue(let p, let v): return "\(p) 的值不合法:\(v)"
        }
    }
}

/// `~` 展開(純函式,SelfTest 覆蓋)。
func expandTilde(_ path: String) -> String {
    (path as NSString).expandingTildeInPath
}

/// config 的 `engine` 字串 → Core `TranscriptionEngine`。未知字串(含 nil)一律
/// 回退 `.appleNative`(與 Core 引擎建構的 fallback 語意一致)。
func resolveEngine(_ raw: String?) -> TranscriptionEngine {
    switch raw {
    case "whisper": return .whisperKit
    case "apple", nil: return .appleNative
    default: return .appleNative
    }
}

/// config/旗標的語言字串 → `TranscriptionLanguage`。優先比對 rawValue(system/en/
/// zhTW/ja/ko/zhCN),同時接受常見連字號別名(zh-TW/zh-CN/en-US 等,plan §2.1
/// 範例文字本身就用連字號寫法,兩種都收比較不會讓使用者猜錯)。
func parseLanguage(_ raw: String) -> TranscriptionLanguage? {
    if let exact = TranscriptionLanguage(rawValue: raw) { return exact }
    switch raw.lowercased() {
    case "zh-tw", "zh_tw": return .zhTW
    case "zh-cn", "zh_cn": return .zhCN
    case "en-us", "en_us": return .en
    case "ja-jp", "ja_jp": return .ja
    case "ko-kr", "ko_kr": return .ko
    case "es-es", "es_es": return .es          // MAS-28 D2:四語別名
    case "de-de", "de_de": return .de
    case "fr-fr", "fr_fr": return .fr
    case "pt-br", "pt_br", "pt": return .ptBR
    default: return nil
    }
}

/// config 檔的位置與 IO。
enum CLIConfigStore {
    /// `MYPARROT_CONFIG_DIR` 覆蓋(測試/多執行個體用);未設時＝原生預設
    /// `~/.config/myparrot`。直接 `getenv`(而非 `ProcessInfo.environment`)——
    /// 前者保證每次呼叫都讀到當下的環境變數,SelfTest 用 `setenv` 切換測試目錄
    /// 時才不會撞到任何潛在的快取行為。
    /// #949 第一段:規則本體搬到 Core `MyParrotPaths.configDir`(GUI 的租約/state/commands 也讀同一個),這裡轉呼叫。
    static var configDir: URL { MyParrotPaths.configDir }

    static var configPath: URL { configDir.appendingPathComponent("config.json") }
    static var hooksApprovedPath: URL { configDir.appendingPathComponent(".hooks-approved") }

    /// 檔不存在＝全預設(空 schema)。
    static func load() -> CLIConfigSchema {
        guard let data = try? Data(contentsOf: configPath),
              let cfg = try? JSONDecoder().decode(CLIConfigSchema.self, from: data)
        else { return CLIConfigSchema() }
        return cfg
    }

    static func save(_ config: CLIConfigSchema) throws {
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try enc.encode(config)
        try AtomicFile.write(data, to: configPath)
    }
}

/// 生效的錄音目錄:config.recordingsDir(展開 `~`)→ 預設同 GUI(`~/Documents/
/// MyParrot`)。純函式,SelfTest 覆蓋。
func resolvedRecordingsDir(_ config: CLIConfigSchema) -> URL {
    let url: URL
    if let dir = config.recordingsDir, !dir.isEmpty {
        url = URL(fileURLWithPath: expandTilde(dir), isDirectory: true)
    } else {
        url = MyParrotPaths.defaultRecordingsDir
    }
    MyParrotPaths.currentRecordingsDir = url   // C2:租約/state/commands 跟著錄音夾走(status/stop/record 都先經這裡)
    return url
}

/// `config get/set <keypath>`——有限已知 schema 的 keypath(不是任意 JSON path)。
enum ConfigKeyPath {
    static func get(_ config: CLIConfigSchema, path: String) -> String? {
        let parts = path.split(separator: ".").map(String.init)
        guard let head = parts.first else { return nil }
        switch head {
        case "recordingsDir": return config.recordingsDir.map(JSONLine.escapeString) ?? "null"
        case "mic": return config.mic.map(JSONLine.escapeString) ?? "null"
        case "engine": return config.engine.map(JSONLine.escapeString) ?? "null"
        case "language": return config.language.map(JSONLine.escapeString) ?? "null"
        case "autoTranscribe": return config.autoTranscribe.map { $0 ? "true" : "false" } ?? "null"
        case "hooks":
            guard parts.count >= 2, let spec = config.hooks?[parts[1]] else { return "null" }
            guard parts.count >= 3 else { return encodeHookSpec(spec) }
            switch parts[2] {
            case "command": return JSONLine.escapeString(spec.command)
            case "cwd": return spec.cwd.map(JSONLine.escapeString) ?? "null"
            case "timeout":
                switch spec.timeout {
                case .auto: return JSONLine.escapeString("auto")
                case .seconds(let n): return n == n.rounded() ? String(Int64(n)) : String(n)
                }
            case "auto": return spec.auto ? "true" : "false"
            case "strict": return spec.strict ? "true" : "false"
            default: return nil
            }
        default: return nil
        }
    }

    private static func encodeHookSpec(_ spec: HookSpec) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(spec)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    static func set(_ config: inout CLIConfigSchema, path: String, value: String) throws {
        let parts = path.split(separator: ".").map(String.init)
        guard let head = parts.first else { throw ConfigError.invalidPath(path) }
        switch head {
        case "recordingsDir": config.recordingsDir = value
        case "mic": config.mic = value
        case "engine": config.engine = value
        case "language": config.language = value
        case "autoTranscribe":
            guard let b = Bool(value) else { throw ConfigError.invalidValue(path, value) }
            config.autoTranscribe = b
        case "hooks":
            guard parts.count == 3 else { throw ConfigError.invalidPath(path) }
            let stage = parts[1]
            var spec = config.hooks?[stage] ?? HookSpec(command: "")
            switch parts[2] {
            case "command": spec.command = value
            case "cwd": spec.cwd = value
            case "timeout":
                if value == "auto" { spec.timeout = .auto }
                else if let n = Double(value), n.isFinite, n >= 0 { spec.timeout = .seconds(n) }   // 二審:拒負數/NaN/Inf
                else { throw ConfigError.invalidValue(path, value) }
            case "auto":
                guard let b = Bool(value) else { throw ConfigError.invalidValue(path, value) }
                spec.auto = b
            case "strict":
                guard let b = Bool(value) else { throw ConfigError.invalidValue(path, value) }
                spec.strict = b
            default: throw ConfigError.invalidPath(path)
            }
            var hooks = config.hooks ?? [:]
            hooks[stage] = spec
            config.hooks = hooks
        default: throw ConfigError.invalidPath(path)
        }
    }
}

/// trust-on-first-use(仿 direnv allow,§8)。對 `hooks` 段正規化 JSON 算
/// SHA256,存 `.hooks-approved`;執行前比對,不符→不跑。
enum HookTrust {
    static func normalizedDigestHex(_ hooks: [String: HookSpec]?) -> String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = (try? enc.encode(hooks ?? [:])) ?? Data()
        return SHA256Hex.hex(data)
    }

    static func isApproved(_ hooks: [String: HookSpec]?) -> Bool {
        guard let stored = try? String(contentsOf: CLIConfigStore.hooksApprovedPath, encoding: .utf8) else {
            return false
        }
        return stored.trimmingCharacters(in: .whitespacesAndNewlines) == normalizedDigestHex(hooks)
    }

    static func approve(_ hooks: [String: HookSpec]?) throws {
        try FileManager.default.createDirectory(at: CLIConfigStore.configDir, withIntermediateDirectories: true)
        try AtomicFile.write(Data(normalizedDigestHex(hooks).utf8), to: CLIConfigStore.hooksApprovedPath)
    }
}
