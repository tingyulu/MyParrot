import Foundation
import Observation

/// 版號解析與比較(UPD)。strip 前綴 v/V;任一段非純數字→nil;比較時短版補 0。
public struct AppVersion: Comparable, Equatable, Sendable {
    public let parts: [Int]
    public init?(_ raw: String) {
        let s = raw.hasPrefix("v") || raw.hasPrefix("V") ? String(raw.dropFirst()) : raw
        let segs = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !segs.isEmpty, !segs.contains(nil) else { return nil }
        parts = segs.compactMap { $0 }
    }
    public static func < (l: AppVersion, r: AppVersion) -> Bool {
        let n = max(l.parts.count, r.parts.count)
        for i in 0..<n {
            let a = i < l.parts.count ? l.parts[i] : 0
            let b = i < r.parts.count ? r.parts[i] : 0
            if a != b { return a < b }
        }
        return false
    }
}

/// GitHub releases/latest 回應(只取需要的兩欄)。
public struct GitHubRelease: Decodable, Sendable {
    public let tagName: String
    public let htmlURL: URL
    enum CodingKeys: String, CodingKey { case tagName = "tag_name", htmlURL = "html_url" }
}

/// 純判斷(internal 供 SelfTest 重用)。
/// nil = 任一邊 parse 失敗(dev build 無版號、或 tag 含非數字段如 "1.0.0-beta")。
func isNewer(remoteTag: String, localVersion: String) -> Bool? {
    guard let remote = AppVersion(remoteTag), let local = AppVersion(localVersion) else { return nil }
    return remote > local
}

/// tag == skipped(用 AppVersion 等值比,非字串,容忍 "0.3"/"0.3.0" 這類補 0 等值)→ false。
/// tag parse 失敗或無 skipped 記錄 → true(照常提示,交給呼叫端的 isNewer 把關是否真的更新)。
func shouldPresentBanner(remoteTag: String, skipped: String?) -> Bool {
    guard let skipped, let remote = AppVersion(remoteTag), let skippedVersion = AppVersion(skipped) else { return true }
    return remote != skippedVersion
}

/// 啟動時背景查 GitHub releases/latest,發現新版時讓 UI 呈現非阻斷提示。
/// 邊界(decisions.md D7):獨立於 RecordingController——更新檢查是 app 層、非錄音域。
@MainActor
@Observable
public final class UpdateChecker {
    public enum Status: Equatable {
        case idle, checking, upToDate
        case updateAvailable(version: String, url: URL)   // version = strip v 後,如 "0.3.0"
        case failed
    }

    public private(set) var status: Status = .idle

    public var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "checkUpdates") }
    }

    public private(set) var skippedVersion: String?

    public init() {
        if UserDefaults.standard.object(forKey: "checkUpdates") == nil {
            enabled = true   // 預設開(decisions.md D4)
        } else {
            enabled = UserDefaults.standard.bool(forKey: "checkUpdates")
        }
        skippedVersion = UserDefaults.standard.string(forKey: "skippedVersion")
    }

    public static var currentVersion: String? {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    #if MYPARROT_MAS
    /// 商店版(2.4.5 vii,MAS-14):更新只能走 Mac App Store。網路檢查整段不編——二進位裡沒有 api.github.com
    /// (`strings` 驗)、設定頁沒有開關與「立即檢查」、不會有更新橫幅;status 永遠停在 .idle。
    public func autoCheckAtLaunch() async {}
    public func checkNow() async {}
    #else
    /// 啟動路徑:enabled 且 currentVersion 有值才打;結果==skippedVersion→status 收斂為
    /// .upToDate(不彈)。一切網路失敗靜默(print log),不彈窗不擋啟動不重試。
    public func autoCheckAtLaunch() async {
        guard enabled, let local = Self.currentVersion else { return }
        guard let release = await fetchLatestRelease() else { status = .failed; return }
        guard let newer = isNewer(remoteTag: release.tagName, localVersion: local) else { status = .failed; return }
        guard newer else { status = .upToDate; return }
        let remoteVersion = stripVPrefix(release.tagName)
        if !shouldPresentBanner(remoteTag: release.tagName, skipped: skippedVersion) {
            status = .upToDate
            return
        }
        guard Self.isTrustedReleaseURL(release.htmlURL) else { status = .upToDate; return }
        status = .updateAvailable(version: remoteVersion, url: release.htmlURL)
    }

    /// Settings 手動:無視 enabled 與 skip,結果原樣呈現。
    public func checkNow() async {
        status = .checking
        guard let local = Self.currentVersion else { status = .failed; return }
        guard let release = await fetchLatestRelease() else { status = .failed; return }
        guard let newer = isNewer(remoteTag: release.tagName, localVersion: local) else { status = .failed; return }
        status = (newer && Self.isTrustedReleaseURL(release.htmlURL))
            ? .updateAvailable(version: stripVPrefix(release.tagName), url: release.htmlURL) : .upToDate
    }

    private func stripVPrefix(_ tag: String) -> String {
        tag.hasPrefix("v") || tag.hasPrefix("V") ? String(tag.dropFirst()) : tag
    }

    private func fetchLatestRelease() async -> GitHubRelease? {
        guard let url = URL(string: "https://api.github.com/repos/tingyulu/MyParrot/releases/latest") else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MyParrot/\(Self.currentVersion ?? "dev")", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                print("[UPD] check failed: unexpected response \((response as? HTTPURLResponse)?.statusCode ?? -1)")
                return nil
            }
            return try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            print("[UPD] check failed: \(error)")
            return nil
        }
    }

    /// v0.3.0 二審:回應裡的 html_url 會直接交給 NSWorkspace.open——只接受 https 且
    /// 是本專案 GitHub 頁面,免得被污染的回應打開任意 URL scheme。
    static func isTrustedReleaseURL(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "github.com" && url.path.hasPrefix("/tingyulu/MyParrot/")
    }
    #endif

    /// banner〔略過此版〕:存 skippedVersion=目前 updateAvailable 的 version,status→.upToDate。
    public func skip() {
        guard case .updateAvailable(let version, _) = status else { return }
        skippedVersion = version
        UserDefaults.standard.set(version, forKey: "skippedVersion")
        status = .upToDate
    }
}
