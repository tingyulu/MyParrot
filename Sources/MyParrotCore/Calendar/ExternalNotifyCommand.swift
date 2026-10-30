import Foundation

/// CAL-07(B3 的第二腿):外部通知指令。使用者在設定頁自填一行 shell(例如自己的 Telegram 腳本),
/// T−2 時以 `/bin/sh -c` 執行,事件資料走環境變數。App 內**不寫死任何服務**(開源邊界)。
/// 失敗只回傳結果讓呼叫端記 log,不彈窗;逾時殺整個 process group(指令可能自己再起子行程)。
public enum ExternalNotifyCommand {
    public struct Outcome: Sendable, Equatable {
        public let exitCode: Int32
        public let timedOut: Bool
        public var ok: Bool { exitCode == 0 && !timedOut }
    }

    public static let titleKey = "MYPARROT_EVENT_TITLE"
    public static let startISOKey = "MYPARROT_START_ISO"
    public static let startLocalKey = "MYPARROT_START_LOCAL"
    public static let startTaipeiKey = "MYPARROT_START_TAIPEI"

    /// 純函式:組子行程環境變數。`base` 預設是自己的環境(PATH 等照常繼承)。
    public static func environment(title: String, start: Date, local: TimeZone,
                                   base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        env[titleKey] = title
        env[startISOKey] = iso.string(from: start)
        env[startLocalKey] = DualTimeZoneFormat.clock(start, local, includeDate: true)
        env[startTaipeiKey] = DualTimeZoneFormat.clock(start, DualTimeZoneFormat.taipei, includeDate: true)
        return env
    }

    /// MAS-14 純函式:設定裡的那一行 ⇒ 真的要跑的指令。`allowed == false`(商店版,`BuildFlavor.allowsExternalCommand`)
    /// 或整行空白 ⇒ nil(不跑);否則回去頭尾空白的指令。
    public static func effective(_ raw: String, allowed: Bool) -> String? {
        guard allowed else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 同步執行(呼叫端自己丟到背景);stdin/stdout/stderr 都接 /dev/null。
    public static func run(_ command: String, environment: [String: String], timeout: TimeInterval = 10) -> Outcome {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return Outcome(exitCode: 0, timedOut: false) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", trimmed]
        p.environment = environment
        p.standardInput = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return Outcome(exitCode: -1, timedOut: false) }
        let pid = p.processIdentifier
        setpgid(pid, pid)   // 新行程組:逾時 killpg 整組(比照 ClaudeCLIProvider)
        let deadline = Date().addingTimeInterval(timeout)
        var timedOut = false
        while p.isRunning {
            if Date() >= deadline { timedOut = true; killpg(pid, SIGKILL); break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        p.waitUntilExit()
        return Outcome(exitCode: timedOut ? -1 : p.terminationStatus, timedOut: timedOut)
    }
}
