import Foundation
import SwiftUI
import MyParrotCore

/// MAS-31(#2646;Eric 8/23 拍板 9.6 附帶要求,兩版都有):首次啟動、選完錄音夾之後跳一次「模型下載卡片」——
/// 系統內建的即時逐字稿已可用;想要更高精度可下載 Whisper 模型(列三個與大小)。按「下載建議模型」走既有
/// `WhisperModelStore.download`(進度在設定頁看得到),按「稍後」只記 `onboardingShown`;設定頁可重跑。
/// 已裝任何模型的人視同知道,直接標 shown 不跳。
@MainActor
enum Onboarding {
    static let key = "onboardingShown"
    static var shown: Bool { UserDefaults.standard.bool(forKey: key) }
    static func markShown() { UserDefaults.standard.set(true, forKey: key) }
    static func reset() { UserDefaults.standard.removeObject(forKey: key) }

    /// 該不該跳:沒跳過、也還沒裝任何 Whisper 模型。
    static func shouldShow() -> Bool {
        if shown { return false }
        if !WhisperModelStore.installed().isEmpty { markShown(); return false }
        return true
    }

    /// 卡片內文:固定句 ＋ 三個模型(顯示名已含大小,沿用設定頁的 l10n key)。
    static func message() -> String {
        L("系統內建的即時逐字稿現在就能用。想要更高精度的會後重轉，可以下載 Whisper 模型（之後也能在設定下載）：")
            + "\n" + WhisperModel.knownModels.map { "• " + L($0.display) }.joined(separator: "\n")
    }

    /// 「下載建議模型」＝ large-v3-turbo(設定頁標「建議」的那個)。
    static var recommended: WhisperModel { WhisperModel.knownModels.first { $0.id == "large-v3-turbo" } ?? WhisperModel.knownModels[0] }
}

/// Whisper 模型下載的單一進度中心:設定頁與首啟卡片共用(之前下載狀態是 SettingsView 的 @State,卡片按下載時設定頁可能還沒開)。
@MainActor
@Observable
final class WhisperDownloads {
    static let shared = WhisperDownloads()
    /// 進度 0…1;鍵＝模型 id;沒在下載＝不在字典裡。
    private(set) var progress: [String: Double] = [:]
    /// 最近一次失敗訊息(已依介面語言重組);開始新下載時清掉。
    private(set) var error: String?
    /// 成功下載的累計次數(設定頁用 onChange 重掃已裝清單)。
    private(set) var completedCount = 0

    func start(_ m: WhisperModel, controller: RecordingController) {
        guard progress[m.id] == nil else { return }   // 同一個模型別重複開
        progress[m.id] = 0
        error = nil
        Task {
            do {
                _ = try await WhisperModelStore.download(m) { p in
                    Task { @MainActor in WhisperDownloads.shared.progress[m.id] = p }
                }
                progress[m.id] = nil
                if UserDefaults.standard.string(forKey: "whisperModel") == nil {
                    UserDefaults.standard.set(m.id, forKey: "whisperModel")
                }
                controller.reloadTranscriptionEngine()
                completedCount += 1
            } catch {
                progress[m.id] = nil
                self.error = "\(L("下載失敗")):\(CoreMessageL10n.localize("\(error)"))"   // MAS-12:校驗失敗句依介面語言
            }
        }
    }
}
