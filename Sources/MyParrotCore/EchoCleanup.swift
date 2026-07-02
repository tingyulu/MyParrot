import Foundation
import AVFoundation
import Accelerate

/// Offline echo cleanup for a finished stereo recording (Path A): cancels the 對方
/// (left, system audio) echo that bled into 你 (right, mic) when recording on speakers.
///
/// Pipeline (see PRD「AEC 重做研究」):
///  1. **No-echo gate** — if left↔right correlation is low (headphones, no speaker
///     echo) skip entirely, so a clean mic track is never damaged.
///  2. **Bulk-delay alignment** — the two capture paths run on independent clocks, so
///     the real echo delay is 44–165ms and drifts. We estimate it by cross-correlation
///     per block and shift the reference so the echo lands inside the filter's reach.
///  3. **Adaptive NLMS** on the aligned signals (longer filter to cover the residual
///     acoustic path + reverb tail), with Geigel double-talk protection.
///
/// **Non-destructive**: reads `inURL`, writes to a NEW `outURL`, never touches the
/// original. Returns false (and writes nothing) when no echo is detected.
enum EchoCleanup {

    @discardableResult
    static func cleanEcho(from inURL: URL, to outURL: URL,
                          taps: Int = 2048, echoThreshold: Float = 0.10) throws -> Bool {
        let inFile = try AVAudioFile(forReading: inURL)
        let fmt = inFile.processingFormat
        let sr = fmt.sampleRate
        guard fmt.channelCount >= 2, inFile.length > 0 else { return false }
        let total = Int(inFile.length)
        let maxLag = Int(sr * 0.25)              // search echo delay up to 250ms

        // 1) No-echo gate: estimate a representative delay + correlation on the
        //    loudest-對方 window. Low correlation ⇒ headphones / no echo ⇒ skip.
        let (gateDelay, gatePeak) = try scanLoudestEcho(inFile, total: total, sr: sr, maxLag: maxLag)
        guard gatePeak >= echoThreshold else { return false }

        // 2)+3) Block-by-block: re-estimate delay (drift tracking) → align ref → NLMS.
        let outFile = try AVAudioFile(forWriting: outURL, settings: fmt.settings,
                                      commonFormat: .pcmFormatFloat32, interleaved: false)
        let aec = EchoCanceller(taps: taps)
        let guardSamp = Int(sr * 0.005)          // align ~5ms early so delay jitter stays in-window
        let block = Int(sr * 10)                 // 10s blocks
        var alignDelay = max(0, gateDelay - guardSamp)

        var blockStart = 0
        while blockStart < total {
            let regionStart = max(0, blockStart - maxLag)   // lookback runway for the delayed ref
            let blockEnd = min(blockStart + block, total)
            let regionLen = blockEnd - regionStart
            inFile.framePosition = AVAudioFramePosition(regionStart)
            guard let rbuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(regionLen)) else { break }
            try inFile.read(into: rbuf, frameCount: AVAudioFrameCount(regionLen))
            let rn = Int(rbuf.frameLength)
            guard rn > 0, let ch = rbuf.floatChannelData else { break }
            let off = blockStart - regionStart
            let blockLen = rn - off
            if blockLen <= 0 { break }

            let refRegion = Array(UnsafeBufferPointer(start: ch[0], count: rn))               // 對方 (+ lookback)
            let nearBlock = Array(UnsafeBufferPointer(start: ch[1] + off, count: blockLen))   // 你 (block only)

            // Drift tracking: re-estimate on this block; keep previous delay if too quiet.
            let refBlock = Array(refRegion[off...])
            let (d, peak) = DelayEstimator.estimate(near: nearBlock, ref: refBlock, maxLag: maxLag)
            if peak >= echoThreshold { alignDelay = max(0, d - guardSamp) }

            // Aligned reference: alignedRef[k] = refRegion[off + k - alignDelay].
            var alignedRef = [Float](repeating: 0, count: blockLen)
            for k in 0..<blockLen {
                let idx = off + k - alignDelay
                if idx >= 0 && idx < rn { alignedRef[k] = refRegion[idx] }
            }
            let cleaned = aec.process(near: nearBlock, ref: alignedRef)

            guard let obuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(blockLen)),
                  let och = obuf.floatChannelData else { break }
            obuf.frameLength = AVAudioFrameCount(blockLen)
            for k in 0..<blockLen { och[0][k] = refRegion[off + k]; och[1][k] = cleaned[k] }  // 對方 untouched, 你 cleaned
            try outFile.write(from: obuf)

            blockStart = blockEnd
        }
        return true
    }

    /// Scan the file for the loudest-對方 window and estimate (delay, peak) there —
    /// the basis for the no-echo gate and the initial alignment.
    private static func scanLoudestEcho(_ f: AVAudioFile, total: Int, sr: Double, maxLag: Int) throws -> (Int, Float) {
        let fmt = f.processingFormat
        let scan = Int(sr * 4)                    // 4s windows (≫ maxLag, room for the search runway)
        guard let sbuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(scan)) else { return (0, 0) }
        var bestStart = 0, bestL: Float = 0
        var pos = 0
        while pos < total {
            f.framePosition = AVAudioFramePosition(pos)
            let want = min(scan, total - pos)
            try f.read(into: sbuf, frameCount: AVAudioFrameCount(want))
            let n = Int(sbuf.frameLength); if n == 0 { break }
            if let ch = sbuf.floatChannelData {
                var l: Float = 0; vDSP_measqv(ch[0], 1, &l, vDSP_Length(n))
                if l > bestL { bestL = l; bestStart = pos }
            }
            pos += scan
        }
        f.framePosition = AVAudioFramePosition(bestStart)
        let want = min(scan, total - bestStart)
        guard want > maxLag, let wbuf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(want)) else { return (0, 0) }
        try f.read(into: wbuf, frameCount: AVAudioFrameCount(want))
        let n = Int(wbuf.frameLength)
        guard n > maxLag, let ch = wbuf.floatChannelData else { return (0, 0) }
        let near = Array(UnsafeBufferPointer(start: ch[1], count: n))
        let ref = Array(UnsafeBufferPointer(start: ch[0], count: n))
        return DelayEstimator.estimate(near: near, ref: ref, maxLag: maxLag)
    }
}
