import Foundation
import Accelerate

/// Estimates the bulk echo delay between the reference (對方, system audio) and the
/// near-end (你, mic) by normalized cross-correlation. The two capture paths run on
/// independent clocks with different buffering, so the echo of `ref[i]` shows up in
/// `near[i+D]` for some D of 44–165ms (and drifting) — far beyond a short adaptive
/// filter's reach. We estimate D here and pre-align the reference so the filter only
/// has to model the short residual (acoustic path + reverb). See PRD「AEC 重做研究」.
enum DelayEstimator {

    /// Best lag D (samples, 0...maxLag) where `near[t]` correlates with `ref[t-D]`
    /// (echo[t] ≈ a·ref[t-D]), plus the normalized peak (0...1). `decim` downsamples
    /// for speed — precision ≈ `decim` samples, which the adaptive filter mops up.
    /// `near`/`ref` should be the same window; the front `maxLag` samples act as the
    /// backward search runway, so the window must be comfortably longer than maxLag.
    static func estimate(near: [Float], ref: [Float], maxLag: Int, decim: Int = 8) -> (lag: Int, peak: Float) {
        let n = min(near.count, ref.count)
        let dn = n / decim
        let dMax = maxLag / decim
        guard dn > dMax + 16, dMax > 0 else { return (0, 0) }

        var nd = [Float](repeating: 0, count: dn)
        var rd = [Float](repeating: 0, count: dn)
        for i in 0..<dn { nd[i] = near[i * decim]; rd[i] = ref[i * decim] }

        let base = dMax                 // near window = nd[base ..< dn]
        let win = dn - base
        guard win > dMax else { return (0, 0) }

        var nearEnergy: Float = 0
        nd.withUnsafeBufferPointer { vDSP_svesq($0.baseAddress! + base, 1, &nearEnergy, vDSP_Length(win)) }
        guard nearEnergy > 0 else { return (0, 0) }

        var peak: Float = 0, peakLag = 0
        nd.withUnsafeBufferPointer { np in
            rd.withUnsafeBufferPointer { rp in
                let nPtr = np.baseAddress! + base
                for d in 0...dMax {
                    let rPtr = rp.baseAddress! + (base - d)
                    var dot: Float = 0
                    vDSP_dotpr(nPtr, 1, rPtr, 1, &dot, vDSP_Length(win))
                    var refEn: Float = 0
                    vDSP_svesq(rPtr, 1, &refEn, vDSP_Length(win))
                    let c = abs(dot) / (sqrt(nearEnergy * refEn) + 1e-9)
                    if c > peak { peak = c; peakLag = d }
                }
            }
        }
        return (peakLag * decim, peak)
    }
}
