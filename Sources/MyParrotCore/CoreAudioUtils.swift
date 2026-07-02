import Foundation
import AudioToolbox

// Lets us `throw "some message"` for terse Core Audio error handling.
extension String: @retroactive Error {}

extension AudioObjectID {
    static let system = AudioObjectID(kAudioObjectSystemObject)
    static let unknown = kAudioObjectUnknown

    var isUnknown: Bool { self == .unknown }
    var isValid: Bool { !isUnknown }

    /// Default system output device (the device the Process Tap references).
    static func readDefaultSystemOutputDevice() throws -> AudioDeviceID {
        try AudioObjectID.system.read(kAudioHardwarePropertyDefaultSystemOutputDevice,
                                      defaultValue: AudioDeviceID.unknown)
    }

    /// Translate a pid to its Core Audio process object (used to exclude our own audio).
    static func translatePIDToProcessObject(_ pid: pid_t) throws -> AudioObjectID {
        try AudioObjectID.system.read(kAudioHardwarePropertyTranslatePIDToProcessObject,
                                      defaultValue: AudioObjectID.unknown,
                                      qualifier: pid)
    }

    func readDeviceUID() throws -> String { try readString(kAudioDevicePropertyDeviceUID) }

    func readAudioTapStreamBasicDescription() throws -> AudioStreamBasicDescription {
        try read(kAudioTapPropertyFormat, defaultValue: AudioStreamBasicDescription())
    }

    /// The device's nominal sample rate. A *secondary* signal — Apple only defines it
    /// as "the current nominal sample rate of the AudioDevice", which is not guaranteed
    /// to equal the rate an IOProc actually transacts in. Prefer `readInputStreamID` +
    /// `readStreamVirtualFormat` (below); this stays as a fallback.
    func readNominalSampleRate() throws -> Double {
        Double(try read(kAudioDevicePropertyNominalSampleRate, defaultValue: Float64(0)))
    }

    /// The stream object IDs on `scope` (variable-length list, hence its own reader).
    func readStreamIDs(scope: AudioObjectPropertyScope) throws -> [AudioStreamID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                 mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, 0, nil, &size)
        guard err == noErr else { throw "Error reading stream list size (\(err))" }
        let count = Int(size) / MemoryLayout<AudioStreamID>.stride
        guard count > 0 else { return [] }
        var ids = [AudioStreamID](repeating: .unknown, count: count)
        err = ids.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(self, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard err == noErr else { throw "Error reading stream list (\(err))" }
        return ids
    }

    /// First input-scope stream of this device (e.g. the tap stream of our aggregate).
    func readInputStreamID() throws -> AudioStreamID {
        guard let first = try readStreamIDs(scope: kAudioObjectPropertyScopeInput).first else {
            throw "No input stream on device"
        }
        return first
    }

    /// The format an IOProc actually transacts in for this stream — the AUTHORITATIVE
    /// source for the delivered sample rate. Apple: `kAudioStreamPropertyVirtualFormat`
    /// is "the data format in which all IOProcs for the owning AudioDevice will perform
    /// IO transactions". The standalone tap format / device nominal rate can disagree
    /// under Bluetooth/HFP and mislabel buffers (→ pitch-shifted 對方, BUG-15).
    func readStreamVirtualFormat() throws -> AudioStreamBasicDescription {
        try read(kAudioStreamPropertyVirtualFormat, defaultValue: AudioStreamBasicDescription())
    }
}

// MARK: - Generic property access

extension AudioObjectID {
    func read<T, Q>(_ selector: AudioObjectPropertySelector,
                    scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                    element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                    defaultValue: T,
                    qualifier: Q) throws -> T {
        var inQualifier = qualifier
        let qualifierSize = UInt32(MemoryLayout<Q>.size(ofValue: qualifier))
        return try withUnsafeMutablePointer(to: &inQualifier) { qPtr in
            try read(AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element),
                     defaultValue: defaultValue, inQualifierSize: qualifierSize, inQualifierData: qPtr)
        }
    }

    func read<T>(_ selector: AudioObjectPropertySelector,
                 scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                 element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain,
                 defaultValue: T) throws -> T {
        try read(AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element),
                 defaultValue: defaultValue)
    }

    func readString(_ selector: AudioObjectPropertySelector) throws -> String {
        try read(AudioObjectPropertyAddress(mSelector: selector,
                                            mScope: kAudioObjectPropertyScopeGlobal,
                                            mElement: kAudioObjectPropertyElementMain),
                 defaultValue: "" as CFString) as String
    }

    private func read<T>(_ inAddress: AudioObjectPropertyAddress,
                         defaultValue: T,
                         inQualifierSize: UInt32 = 0,
                         inQualifierData: UnsafeRawPointer? = nil) throws -> T {
        var address = inAddress
        var dataSize: UInt32 = 0
        var err = AudioObjectGetPropertyDataSize(self, &address, inQualifierSize, inQualifierData, &dataSize)
        guard err == noErr else { throw "Error reading data size (\(err))" }

        var value: T = defaultValue
        err = withUnsafeMutablePointer(to: &value) { ptr in
            AudioObjectGetPropertyData(self, &address, inQualifierSize, inQualifierData, &dataSize, ptr)
        }
        guard err == noErr else { throw "Error reading data (\(err))" }
        return value
    }
}
