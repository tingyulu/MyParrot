import Foundation
import AVFoundation

/// Splits a stereo recording (L=對方, R=你) into two temporary mono files so each
/// speaker can be transcribed on its own channel. Returns (url, url) unchanged if
/// the source is already mono. Shared by the SFSpeech and SpeechAnalyzer providers.
///
/// Reads/writes in fixed-size chunks so a long meeting (e.g. an hour of 48 kHz
/// stereo) never balloons into a multi-GB single buffer.
enum AudioChannelSplit {
    private static let chunk: AVAudioFrameCount = 16_384

    static func splitStereoToMono(_ url: URL) throws -> (left: URL, right: URL) {
        let inFile = try AVAudioFile(forReading: url)
        let fmt = inFile.processingFormat
        guard fmt.channelCount >= 2 else { return (url, url) }

        let mono = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: fmt.sampleRate,
                                 channels: 1, interleaved: false)!
        let tmp = FileManager.default.temporaryDirectory
        let lURL = tmp.appendingPathComponent("mp_L_\(UUID().uuidString).caf")
        let rURL = tmp.appendingPathComponent("mp_R_\(UUID().uuidString).caf")
        let lFile = try AVAudioFile(forWriting: lURL, settings: mono.settings,
                                    commonFormat: .pcmFormatFloat32, interleaved: false)
        let rFile = try AVAudioFile(forWriting: rURL, settings: mono.settings,
                                    commonFormat: .pcmFormatFloat32, interleaved: false)

        guard let inBuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: chunk) else { throw "讀取緩衝失敗" }
        // Track remaining frames and never request more than are left: AVAudioFile.read
        // throws (_GenericObjCError "nilError") if frameCount overruns the file end.
        var remaining = inFile.length
        while remaining > 0 {
            try inFile.read(into: inBuf, frameCount: AVAudioFrameCount(min(Int64(chunk), remaining)))
            let n = inBuf.frameLength
            if n == 0 { break }
            remaining -= Int64(n)
            guard let lBuf = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: n),
                  let rBuf = AVAudioPCMBuffer(pcmFormat: mono, frameCapacity: n),
                  let src = inBuf.floatChannelData,
                  let ld = lBuf.floatChannelData, let rd = rBuf.floatChannelData else { throw "單聲道緩衝失敗" }
            lBuf.frameLength = n; rBuf.frameLength = n
            for i in 0..<Int(n) { ld[0][i] = src[0][i]; rd[0][i] = src[1][i] }
            try lFile.write(from: lBuf)
            try rFile.write(from: rBuf)
        }
        return (lURL, rURL)
    }
}
