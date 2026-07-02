import Foundation
import AVFoundation

/// Converts the lossless capture file (CAF/PCM) into a compact AAC .m4a for keeping.
/// ~20–25× smaller, and plays everywhere (Windows, NotebookLM, any player).
enum AudioExport {
    static func toM4A(from src: URL, to dst: URL) async throws {
        let asset = AVURLAsset(url: src)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
            throw "無法建立音訊匯出工作"
        }
        try? FileManager.default.removeItem(at: dst)
        export.outputURL = dst
        export.outputFileType = .m4a

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }

        guard export.status == .completed else {
            throw export.error ?? "音訊匯出失敗(狀態 \(export.status.rawValue))"
        }
    }
}
