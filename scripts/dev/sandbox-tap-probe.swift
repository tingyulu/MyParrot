// sandbox-tap-probe.swift — App Sandbox 下 Core Audio process tap 可行性探針（2026-10-28，App Store 研究）
//
// 問題：沙盒裡 AudioHardwareCreateProcessTap＋私有 aggregate device 收不收得到系統音訊？
// 答案（10/28 實測）：收得到。對照組（無沙盒）與沙盒組都是 466 次回呼／238,592 幀／AUDIO_OK。
//
// 用法（Xcode 工具鏈）：
//   swiftc -O -framework CoreAudio -framework AudioToolbox -framework Foundation sandbox-tap-probe.swift -o TapProbe
//   組成 .app（Contents/MacOS/TapProbe＋Info.plist，Info.plist 要有 NSAudioCaptureUsageDescription），
//   codesign --options runtime --entitlements <ent> ；對照組 ent 只有 device.audio-input，實驗組再加 app-sandbox。
//   背景 `afplay -v 0.15 <安靜的音檔>`，`open TapProbe.app`，結果看 unified log：
//   /usr/bin/log show --last 2m --predicate 'subsystem == "tw.uncle.TapProbe"' --style compact
//   （NSLog 的字串在 log 裡會被遮成 <private>，所以用 os_log %{public}@；沙盒內寫的檔案從外面讀不到。）
//   --list-prefs／--dump-prefs／--delete-prefs：列出／base64 倒出／刪除容器內的偏好檔（10/28 善後用）。
//
// 🔴 bundle id 的坑：為了沿用 TCC 授權不跳框，探針用了 MyParrot 的正式 bundle id。
//   同 bundle id 的沙盒 app 第一次啟動，macOS 會把 ~/Library/Preferences/<id>.plist 搬進容器
//   （Application Support／Caches 不搬），真偏好就這樣被動到。再跑之前：先 `defaults export` 備份，
//   或改用別的 bundle id（代價＝系統音訊 TCC 會跳框，要 Eric 點）。善後過程見 TEST_REPORT 10/28 節。
//   從 harness 直接執行二進位會把 TCC 歸因到 Claude app，一律 `open`。

import Foundation
import CoreAudio
import AudioToolbox
import os
import CryptoKit
let oslog = OSLog(subsystem: "tw.uncle.TapProbe", category: "probe")

// Sandbox feasibility probe: global Core Audio process tap + private aggregate device + IOProc,
// measure whether audio buffers arrive. Writes result to its own temp dir and NSLog.
var lines: [String] = []
func out(_ s: String) { os_log("TapProbe: %{public}@", log: oslog, type: .default, s); lines.append(s) }
func fail(_ s: String) -> Never { out("FAIL " + s); finish(); exit(1) }
func finish() {
    let path = (NSTemporaryDirectory() as NSString).appendingPathComponent("tapprobe-result.txt")
    try? (lines.joined(separator: "\n") + "\n").write(toFile: path, atomically: true, encoding: .utf8)
    out("result file: \(path)")
}

let env = ProcessInfo.processInfo.environment
let sandboxed = env["APP_SANDBOX_CONTAINER_ID"] != nil
out("sandboxed=\(sandboxed) container=\(env["APP_SANDBOX_CONTAINER_ID"] ?? "-")")
out("home=\(NSHomeDirectory())")
if CommandLine.arguments.contains("--list-prefs") {
    let dir = NSHomeDirectory() + "/Library/Preferences"
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
    out("LIST prefs dir entries=\(names.count)")
    for n in names.sorted() {
        let fp = dir + "/" + n
        if let d = FileManager.default.contents(atPath: fp) {
            let sha = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined().prefix(12)
            var keys = -1
            if let pl = try? PropertyListSerialization.propertyList(from: d, format: nil) as? [String: Any] { keys = pl.count; if let m = pl["probeMarker"] { out("LIST marker present: \(m)") } }
            out("LIST \(n) size=\(d.count) sha=\(sha) keys=\(keys)")
        } else { out("LIST \(n) (unreadable)") }
    }
    exit(0)
}
if CommandLine.arguments.contains("--dump-prefs") || CommandLine.arguments.contains("--delete-prefs") {
    let path = NSHomeDirectory() + "/Library/Preferences/tw.uncle.MyParrot.plist"
    if let d = FileManager.default.contents(atPath: path) {
        let sha = SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
        out("PREFS size=\(d.count) sha256=\(sha)")
        if CommandLine.arguments.contains("--dump-prefs") {
            let b64 = d.base64EncodedString(); var i = 0; var n = 0
            while i < b64.count { let j = min(i + 700, b64.count); let a = b64.index(b64.startIndex, offsetBy: i), b = b64.index(b64.startIndex, offsetBy: j); out("B64[\(n)] " + String(b64[a..<b])); i = j; n += 1 }
            out("B64 chunks=\(n)")
        }
        if CommandLine.arguments.contains("--delete-prefs") {
            do { try FileManager.default.removeItem(atPath: path); out("PREFS deleted from container") } catch { out("PREFS delete failed: \(error)") }
        }
    } else { out("PREFS not found at \(path)") }
    exit(0)
}

func readDefaultOutput() -> AudioObjectID {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var id = AudioObjectID(kAudioObjectUnknown); var size = UInt32(MemoryLayout<AudioObjectID>.size)
    let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
    if err != noErr { fail("default system output read err=\(err)") }
    return id
}
func readUID(_ dev: AudioObjectID) -> String {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var uid: CFString? = nil
    var size = UInt32(MemoryLayout<CFString?>.size)
    let err = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, $0) }
    if err != noErr || uid == nil { fail("device UID read err=\(err)") }
    return uid! as String
}
func readTapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription {
    var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                          mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var asbd = AudioStreamBasicDescription(); var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    let err = AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd)
    if err != noErr { fail("tap format read err=\(err)") }
    return asbd
}

let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
desc.uuid = UUID(); desc.muteBehavior = .unmuted; desc.isPrivate = true
var tapID = AudioObjectID(kAudioObjectUnknown)
var err = AudioHardwareCreateProcessTap(desc, &tapID)
if err != noErr { fail("AudioHardwareCreateProcessTap err=\(err)") }
out("tap created id=\(tapID)")
let asbd = readTapFormat(tapID)
out("tap format rate=\(asbd.mSampleRate) ch=\(asbd.mChannelsPerFrame) float=\((asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0) bits=\(asbd.mBitsPerChannel) nonInterleaved=\((asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0)")

let outputID = readDefaultOutput(); let outputUID = readUID(outputID)
out("default output id=\(outputID) uid=\(outputUID)")
let aggregateDesc: [String: Any] = [
    kAudioAggregateDeviceNameKey: "TapProbe-SystemTap",
    kAudioAggregateDeviceUIDKey: UUID().uuidString,
    kAudioAggregateDeviceMainSubDeviceKey: outputUID,
    kAudioAggregateDeviceIsPrivateKey: true,
    kAudioAggregateDeviceIsStackedKey: false,
    kAudioAggregateDeviceTapAutoStartKey: true,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]]
]
var aggID = AudioObjectID(kAudioObjectUnknown)
err = AudioHardwareCreateAggregateDevice(aggregateDesc as CFDictionary, &aggID)
if err != noErr { fail("AudioHardwareCreateAggregateDevice err=\(err)") }
out("aggregate created id=\(aggID)")

final class Stats: @unchecked Sendable { var callbacks = 0; var frames = 0; var peak: Float = 0; var sumSq: Double = 0; var samples = 0 }
let stats = Stats()
let q = DispatchQueue(label: "tapprobe.io")
let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0 && asbd.mBitsPerChannel == 32
var procID: AudioDeviceIOProcID? = nil
err = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, q) { _, inInputData, _, _, _ in
    stats.callbacks += 1
    let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
    for buf in abl {
        guard let data = buf.mData else { continue }
        if isFloat {
            let n = Int(buf.mDataByteSize) / 4
            let p = data.bindMemory(to: Float.self, capacity: n)
            for i in 0..<n { let v = abs(p[i]); if v > stats.peak { stats.peak = v }; stats.sumSq += Double(v) * Double(v) }
            stats.samples += n
            stats.frames += n / max(1, Int(buf.mNumberChannels))
        } else {
            stats.frames += Int(buf.mDataByteSize) / max(1, Int(asbd.mBytesPerFrame))
        }
    }
}
if err != noErr { fail("AudioDeviceCreateIOProcIDWithBlock err=\(err)") }
err = AudioDeviceStart(aggID, procID)
if err != noErr { fail("AudioDeviceStart err=\(err)") }
out("device started; capturing 5 s …")
Thread.sleep(forTimeInterval: 5)
AudioDeviceStop(aggID, procID)
if let p = procID { AudioDeviceDestroyIOProcID(aggID, p) }
AudioHardwareDestroyAggregateDevice(aggID)
AudioHardwareDestroyProcessTap(tapID)
let rms = stats.samples > 0 ? sqrt(stats.sumSq / Double(stats.samples)) : 0
let dbPeak = stats.peak > 0 ? 20 * log10(Double(stats.peak)) : -999
let dbRMS = rms > 0 ? 20 * log10(rms) : -999
out(String(format: "RESULT callbacks=%d frames=%d peak_dBFS=%.1f rms_dBFS=%.1f", stats.callbacks, stats.frames, dbPeak, dbRMS))
out("VERDICT " + (stats.callbacks == 0 ? "NO_CALLBACKS" : (stats.peak > 0.001 ? "AUDIO_OK" : "SILENT")))
finish()
exit(0)
