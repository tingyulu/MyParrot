// #949 第一段 brief §7:合成活檔 writer——不碰麥克風／系統音訊(零 TCC),用 AVAudioFile 每 0.5 秒寫一塊,
// 模擬「正在錄音的那一方」,讓收割端(真二進位)在四向矩陣裡面對一個真的活檔。
//
// 編譯(把 Core 的租約／state／inprogress／commands 原始檔一起編進來,驗的就是正式邏輯):
//   swiftc -parse-as-library -O scripts/dev/fake-writer.swift \
//     Sources/MyParrotCore/Recording/RecordingLease.swift Sources/MyParrotCore/Recording/RecordingStateFile.swift \
//     Sources/MyParrotCore/Recording/InprogressFiles.swift Sources/MyParrotCore/Recording/RecordingCommands.swift \
//     -o <scratch>/fake-writer
//
// 用法(錄音資料夾一律指 scratch;設定目錄用 MYPARROT_CONFIG_DIR=<scratch>/cfg):
//   fake-writer --dir <recordingsDir> [--mode new|old] [--owner cli|gui] [--name 標題] [--seconds N]
//   --mode new(預設):照新版協定——取全域租約(owner)、寫 inprogress、每 0.5 秒寫 state.json、2 秒心跳、
//                    每 1 秒輪詢 commands/(stop/pause/resume/mark/title),停止時發布到頂層並釋放租約。
//                    owner=cli 時另寫 record.pid(舊 `myparrot stop` 相容)。
//   --mode old:照 8/10 舊版——直接寫頂層 `<日期 時間> <標題>.caf`、寫 record.pid,沒有租約。
//   SIGINT/SIGTERM 或 --seconds 到點 ⇒ 正常收尾(finalize＋發布);kill -9 ⇒ 留下活檔給收割端測。
// stdout 每行一個 JSON 事件(started／chunk 每 5 秒一次／command／stopped／refused)。
import Foundation
import AVFoundation
#if canImport(Darwin)
import Darwin
#endif

@main
struct FakeWriter {
    static func main() {
        var args = Array(CommandLine.arguments.dropFirst())
        func take(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            let v = args[i + 1]; args.removeSubrange(i...(i + 1)); return v
        }
        guard let dirArg = take("--dir") else {
            FileHandle.standardError.write(Data("用法:fake-writer --dir <recordingsDir> [--mode new|old] [--owner cli|gui] [--name X] [--seconds N]\n".utf8))
            exit(2)
        }
        let mode = take("--mode") ?? "new"
        let owner = take("--owner") ?? "cli"
        let title = take("--name") ?? "fake"
        let seconds = take("--seconds").flatMap(Double.init)
        let dir = URL(fileURLWithPath: (dirArg as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        MyParrotPaths.currentRecordingsDir = dir   // C2(#2646):租約/state/commands 在 <錄音夾>/.myparrot,跟正式 Core 同一條規則
        let w = Writer(dir: dir, mode: mode, owner: owner, title: title, maxSeconds: seconds)
        w.run()
    }
}

func emit(_ obj: [String: Any]) {
    if let d = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]),
       let s = String(data: d, encoding: .utf8) {
        print(s); fflush(stdout)
    }
}

final class Writer: @unchecked Sendable {
    let dir: URL, mode: String, owner: String, title: String, maxSeconds: Double?
    let sessionId = UUID().uuidString
    var holder: RecordingLeaseHolder?
    var file: AVAudioFile?
    var writeURL: URL!
    var stem = ""
    var framesWritten: Int64 = 0
    var paused = false
    var elapsed: Double = 0
    var markers = 0
    var stopRequested = false
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
    var phase: Float = 0

    init(dir: URL, mode: String, owner: String, title: String, maxSeconds: Double?) {
        self.dir = dir; self.mode = mode; self.owner = owner; self.title = title; self.maxSeconds = maxSeconds
    }

    func stamp(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HHmm"; return f.string(from: d)
    }

    func run() {
        let start = Date()
        stem = "\(stamp(start)) \(title)"
        if mode == "old" {
            writeURL = dir.appendingPathComponent("\(stem).caf")
        } else {
            writeURL = InprogressFiles.audioURL(dir: dir, sessionId: sessionId)
            let lease = RecordingLease(sessionId: sessionId, owner: owner, pid: getpid(), bundleID: "fake-writer",
                                       appVersion: "fake", startedAt: ISO8601.string(start), name: stem,
                                       audioPath: writeURL.path, bootUUID: RecordingLease.bootSessionUUID(),
                                       heartbeatAt: ISO8601.string(start))
            switch RecordingLeaseHolder.acquire(lease) {
            case .failure(let e):
                emit(["event": "refused", "reason": "\(e)"]); exit(4)
            case .success(let h): holder = h
            }
            try? FileManager.default.createDirectory(at: writeURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        if mode == "old" || owner == "cli" {
            try? RecordingStateStore.writePID(getpid())
        }
        do {
            file = try AVAudioFile(forWriting: writeURL, settings: fmt.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        } catch {
            emit(["event": "error", "message": "\(error)"]); holder?.release(); exit(4)
        }
        emit(["event": "started", "pid": Int(getpid()), "sessionId": sessionId, "mode": mode, "owner": owner,
              "writePath": writeURL.path, "stem": stem])

        signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
        let q = DispatchQueue(label: "fake-writer.signal")
        let s1 = DispatchSource.makeSignalSource(signal: SIGINT, queue: q)
        s1.setEventHandler { [weak self] in self?.stopRequested = true }
        s1.resume()
        let s2 = DispatchSource.makeSignalSource(signal: SIGTERM, queue: q)
        s2.setEventHandler { [weak self] in self?.stopRequested = true }
        s2.resume()

        var tick = 0
        var lastBeat = Date()
        while !stopRequested {
            Thread.sleep(forTimeInterval: 0.5)
            tick += 1
            if !paused {
                writeChunk(frames: 24_000)
                elapsed += 0.5
            }
            if mode == "new" {
                writeState(paused ? "paused" : "recording")
                if Date().timeIntervalSince(lastBeat) >= 2 { holder?.heartbeat(); lastBeat = Date() }
                if tick % 2 == 0 { pollCommands() }
            }
            if tick % 10 == 0 { emit(["event": "chunk", "framesWritten": framesWritten, "elapsed": elapsed]) }
            if let m = maxSeconds, elapsed >= m { stopRequested = true }
        }
        finish()
        _ = s1; _ = s2
    }

    func writeChunk(frames: Int) {
        guard let file, let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(frames)),
              let ch = buf.floatChannelData else { return }
        buf.frameLength = AVAudioFrameCount(frames)
        for i in 0..<frames {
            let v = 0.1 * sinf(phase + Float(i) * 2 * .pi * 440 / 48_000)
            ch[0][i] = v; ch[1][i] = v * 0.5
        }
        phase += Float(frames) * 2 * .pi * 440 / 48_000
        do { try file.write(from: buf); framesWritten += Int64(frames) }
        catch { emit(["event": "error", "message": "write: \(error)"]) }
    }

    func writeState(_ st: String) {
        let s = RecordingStateFile(pid: getpid(), startedAt: holder?.lease.startedAt ?? "", audioPath: writeURL.path,
                                   name: stem, state: st, levels: .init(other: 0.3, you: 0.15, otherSignal: true, youSignal: true),
                                   warning: nil, updatedAt: ISO8601.string(), owner: owner, sessionId: sessionId,
                                   elapsed: elapsed, paused: paused, markers: markers)
        try? RecordingStateStore.write(s)
    }

    func pollCommands() {
        for cmd in RecordingCommandStore.pending() {
            emit(["event": "command", "cmd": cmd.cmd, "requestId": cmd.requestId])
            switch cmd.cmd {
            case "stop": stopRequested = true; RecordingCommandStore.complete(cmd.requestId, ok: true, result: "stopping")
            case "pause": paused = true; RecordingCommandStore.complete(cmd.requestId, ok: true, result: "paused")
            case "resume": paused = false; RecordingCommandStore.complete(cmd.requestId, ok: true, result: "recording")
            case "mark": markers += 1; RecordingCommandStore.complete(cmd.requestId, ok: true, result: "marked")
            case "title": RecordingCommandStore.complete(cmd.requestId, ok: true, result: cmd.args["title"] ?? "")
            default: RecordingCommandStore.complete(cmd.requestId, ok: false, result: "unknown cmd")
            }
        }
    }

    func finish() {
        if mode == "new" { writeState("stopping") }
        file = nil   // AVAudioFile deinit ⇒ finalize
        var published = writeURL.path
        if mode == "new" {
            switch InprogressFiles.publish(writeURL, dir: dir, stem: stem) {
            case .success(let u): published = u.path
            case .failure(let e): emit(["event": "error", "message": "publish: \(e)"])
            }
            RecordingStateStore.cleanupState(ifSession: sessionId)
            holder?.release()
        }
        if mode == "old" || owner == "cli" { RecordingStateStore.removePIDFile(ifPID: getpid()) }
        emit(["event": "stopped", "audioPath": published, "framesWritten": framesWritten, "elapsed": elapsed])
        exit(0)
    }
}
