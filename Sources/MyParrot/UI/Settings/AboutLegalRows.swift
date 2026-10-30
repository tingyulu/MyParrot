import SwiftUI
import AppKit

/// MAS-16(#2646,App Review 5.1.1／3.1.1;兩版都有):設定頁「關於」區段的法務列——隱私政策、原始碼與授權（GitHub，MIT）、
/// 第三方授權全文。連結只指 repo 根與 PRIVACY.md(🚫 不指 Releases、🚫 不寫「完整版請到 GitHub 下載」,研究 §9-1)。
enum AppLinks {
    /// 隱私政策:Eric 給最終網址前先指公開倉 docs/PRIVACY.md(5.1.1:ASC 與 app 內要同一份,MAS-27 對讀)。
    static let privacyPolicy = URL(string: "https://github.com/tingyulu/MyParrot/blob/main/docs/PRIVACY.md")!
    /// 原始碼與授權:repo 根。
    static let repository = URL(string: "https://github.com/tingyulu/MyParrot")!
}

/// 第三方元件與授權;全文檔在 Resources/Licenses/(build-app.sh 打進 Contents/Resources/Licenses/)。
struct ThirdPartyLicense: Identifiable {
    let id: String
    let license: String
    let file: String
    static let all: [ThirdPartyLicense] = [
        .init(id: "whisper.cpp / ggml", license: "MIT", file: "whisper.cpp-MIT.txt"),
        .init(id: "SwiftyOpenCC", license: "MIT", file: "SwiftyOpenCC-MIT.txt"),
        .init(id: "OpenCC", license: "Apache-2.0", file: "OpenCC-Apache-2.0.txt"),
        .init(id: "Share Tech Mono", license: "SIL OFL 1.1", file: "ShareTechMono-OFL-1.1.txt"),
    ]
    /// 打包後讀 bundle;`swift run` 開發時退回 repo 的 Resources/Licenses;都沒有就印檔名(不崩)。
    var text: String {
        let candidates: [URL?] = [Bundle.main.resourceURL?.appendingPathComponent("Licenses/\(file)"),
                                  URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Licenses/\(file)")]
        for u in candidates.compactMap({ $0 }) { if let s = try? String(contentsOf: u, encoding: .utf8) { return s } }
        return "(\(file))"
    }
    /// 全文檔是否打進了 bundle(DebugControl 驗 MAS-16 用)。
    var bundled: Bool { Bundle.main.resourceURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("Licenses/\(file)").path) } ?? false }
}

struct AboutLegalRows: View {
    var body: some View {
        Link(L("隱私政策"), destination: AppLinks.privacyPolicy).pointerStyle(.link)
        Link(L("原始碼與授權（GitHub，MIT）"), destination: AppLinks.repository).pointerStyle(.link)
        DisclosureGroup(L("第三方授權")) {
            ForEach(ThirdPartyLicense.all) { lic in
                DisclosureGroup("\(lic.id) · \(lic.license)") {
                    ScrollView {
                        Text(lic.text).font(MPFont.caption.monospaced()).textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 160)
                }
            }
        }
    }
}
