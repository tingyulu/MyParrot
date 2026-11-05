#if DEBUG
import Foundation

/// #2737:停錄瞬間主執行緒各步驟耗時(DEBUG 限定;release 連這個檔都不編)。`RecordingController.stop()` 每一步 `lap` 一次,
/// 結束留在 `lastStopPhases` 給 DebugControl `perf stop-phases`,並 os_log 一行。只量不改任何行為。
public struct StopPhaseProfile: Sendable {
    public struct Lap: Sendable {
        public let name: String
        public let ms: Double
    }
    public private(set) var laps: [Lap] = []
    private let start: UInt64
    private var last: UInt64

    public init() {
        start = DispatchTime.now().uptimeNanoseconds
        last = start
    }

    public mutating func lap(_ name: String) {
        let n = DispatchTime.now().uptimeNanoseconds
        laps.append(Lap(name: name, ms: Double(n - last) / 1e6))
        last = n
    }

    public var totalMs: Double { Double(last - start) / 1e6 }

    public var summary: String {
        laps.map { "\($0.name)=\(String(format: "%.1f", $0.ms))" }.joined(separator: " ") + " total=\(String(format: "%.1f", totalMs))"
    }
}
#endif
