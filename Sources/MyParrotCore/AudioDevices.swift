import Foundation
import AudioToolbox
import CoreAudio

/// An audio input device the user can pick for the "你" (microphone) channel.
public struct AudioInputDevice: Identifiable, Hashable, Sendable {
    public let id: AudioDeviceID
    public let name: String
    /// Stable cross-relaunch identifier (`kAudioDevicePropertyDeviceUID`). The numeric
    /// `id` is reassigned on replug/reboot, so the persisted Settings choice is matched
    /// by `uid`, not `id`. See RecordingController preferred-device restore.
    public let uid: String
    /// Bluetooth (classic 'blue' or LE 'blea'). Such a mic forces the headset off
    /// A2DP onto narrowband HFP/SCO and is often grabbed by the meeting app first
    /// (→ a dead/silent recording), so we avoid auto-selecting it. See PRD 藍牙麥克風研究.
    public let isBluetooth: Bool
    public let isBuiltIn: Bool
    /// iPhone used as a Continuity mic — wireless ('ccwl') or wired ('ccwd').
    /// Both are deprioritized below built-in/USB when auto-selecting: research found
    /// Continuity Audio drops mid-recording (not proven fixed even wired), and wireless
    /// adds AWDL Wi-Fi disruption. `isContinuity` = either.
    public let isContinuityWireless: Bool
    public let isContinuityWired: Bool
    public var isContinuity: Bool { isContinuityWireless || isContinuityWired }
    public init(id: AudioDeviceID, name: String, uid: String = "", isBluetooth: Bool = false, isBuiltIn: Bool = false,
                isContinuityWireless: Bool = false, isContinuityWired: Bool = false) {
        self.id = id; self.name = name; self.uid = uid; self.isBluetooth = isBluetooth; self.isBuiltIn = isBuiltIn
        self.isContinuityWireless = isContinuityWireless; self.isContinuityWired = isContinuityWired
    }
}

public enum AudioDevices {

    /// The system's current default input device (the real mic macOS is using).
    public static func defaultInputDevice() -> AudioInputDevice? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID.system, &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return device(id)
    }

    /// Build an AudioInputDevice with name + transport flags for an id.
    private static func device(_ id: AudioDeviceID) -> AudioInputDevice {
        let name = (try? id.readString(kAudioObjectPropertyName)) ?? "未知裝置"
        let uid = (try? id.readDeviceUID()) ?? ""
        let tt = (try? id.read(kAudioDevicePropertyTransportType, defaultValue: UInt32(0))) ?? 0
        let bt = tt == kAudioDeviceTransportTypeBluetooth || tt == kAudioDeviceTransportTypeBluetoothLE
        // 'ccap' (deprecated) is ambiguous → treat as wireless (deprioritize hardest).
        let contWireless = tt == kAudioDeviceTransportTypeContinuityCaptureWireless || tt == kAudioDeviceTransportTypeContinuityCapture
        return AudioInputDevice(id: id, name: name, uid: uid, isBluetooth: bt,
                                isBuiltIn: tt == kAudioDeviceTransportTypeBuiltIn,
                                isContinuityWireless: contWireless,
                                isContinuityWired: tt == kAudioDeviceTransportTypeContinuityCaptureWired)
    }

    /// Enumerate devices that have at least one input channel.
    public static func inputDevices() -> [AudioInputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)

        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID.system, &address, 0, nil, &dataSize) == noErr else { return [] }
        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID.system, &address, 0, nil, &dataSize, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasInput(id) else { return nil }
            return device(id)
        }
    }

    private static func hasInput(_ id: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return false }
        let bufferList = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { bufferList.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, bufferList) == noErr else { return false }
        let abl = UnsafeMutableAudioBufferListPointer(bufferList.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }
}
