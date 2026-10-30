// swift-tools-version: 6.0
import PackageDescription
import Foundation

// BUG-40／CLT-05(公開倉 issue #2):Command Line Tools 的 SDK 有 FoundationModels.framework(`canImport` 為真),
// 但 `@Generable` 的 macro plugin(libFoundationModelsMacros.dylib)只隨 Xcode.app 出貨 ⇒ CLT-only 機器 build 必死。
// SwiftPM manifest 跑在沙箱裡查不到工具鏈有沒有 plugin,所以用明示旗標:`MYPARROT_NO_AFM=1 swift build`
// ⇒ 所有目標多一個 `MYPARROT_NO_AFM` 編譯條件,Apple 本機模型後端整段不編、登錄表不列(設定頁自然不出現)。
let noAFM = ProcessInfo.processInfo.environment["MYPARROT_NO_AFM"] == "1"
let afmSettings: [SwiftSetting] = noAFM ? [.define("MYPARROT_NO_AFM")] : []

// #2646 Mac App Store 免費版(TEST_PLAN X 節 MAS-01):`MYPARROT_MAS=1 swift build` ⇒ 所有目標多一個 `MYPARROT_MAS`
// 編譯條件 ⇒ 商店版(沙盒、bundle id tw.uncle.MyParrot.mas、錄音夾走 security-scoped bookmark、GitHub 更新檢查／
// CLI 後端／外部指令／GUI×CLI 租約監看不編)。同一份原始碼、同一條 main;不帶旗標的 build 與今天逐 byte 等價。
// 守門點集中在 MyParrotCore/BuildFlavor.swift 與各處 `#if MYPARROT_MAS`,`grep -rn 'BuildFlavor\.\|MYPARROT_MAS' Sources` 對帳。
let mas = ProcessInfo.processInfo.environment["MYPARROT_MAS"] == "1"
let flavorSettings: [SwiftSetting] = afmSettings + (mas ? [.define("MYPARROT_MAS")] : [])

let package = Package(
    name: "MyParrot",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        // OpenCC 簡→繁(台灣正體+慣用詞),whisper 中文輸出常是簡體(TR-17)。
        .package(url: "https://github.com/ddddxxx/SwiftyOpenCC.git", branch: "master"),
        // CLI 子命令解析/help/型別安全(D4 拍板)。
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0")
    ],
    targets: [
        // whisper.cpp 推理引擎(Metal+CoreML),由 scripts/fetch-whisper.sh 產出。
        // 二進位不進 git(35MB);clone 後先跑該腳本再 build。
        .binaryTarget(
            name: "whisper",
            path: "Frameworks/whisper.xcframework"
        ),
        // ObjC 小目標:@try/@catch 把 AVFAudio 的 NSException 轉成 Swift 接得到的值
        // (AUD-37,#2523:AirPods 剛連上時 installTap 斷言會把整個 app abort)。
        .target(
            name: "MyParrotObjC",
            path: "Sources/MyParrotObjC",
            publicHeadersPath: "include"
        ),
        .target(
            name: "MyParrotCore",
            dependencies: [
                "whisper",
                "MyParrotObjC",
                .product(name: "OpenCC", package: "SwiftyOpenCC")
            ],
            path: "Sources/MyParrotCore",
            swiftSettings: flavorSettings
        ),
        .executableTarget(
            name: "MyParrot",
            dependencies: ["MyParrotCore"],
            path: "Sources/MyParrot",
            swiftSettings: flavorSettings
        ),
        .executableTarget(
            name: "MyParrotSelfTest",
            dependencies: ["MyParrotCore"],
            path: "Sources/MyParrotSelfTest",
            swiftSettings: flavorSettings
        ),
        // CLI v1(2026-08-10 計畫,docs/worklogs/2026-08-10-cli-feasibility/)。
        // __info_plist 嵌進執行檔(Phase 6):bare CLI 呼叫 TCC 保護 API(語音辨識/
        // 麥克風/系統音訊)時,沒有 usage description 會直接 SIGABRT——嵌入後
        // runtime 才找得到文案。注意:TCC 授權歸屬仍是終端機 app(responsible
        // process),嵌 plist 只解 crash、不改歸屬(decisions.md D7)。
        .executableTarget(
            name: "MyParrotCLI",
            dependencies: [
                "MyParrotCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser")
            ],
            path: "Sources/MyParrotCLI",
            swiftSettings: flavorSettings,
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Resources/CLI-Info.plist"
                ])
            ]
        ),
        // Swift Testing 套件(需完整 Xcode 工具鏈:`swift test` 或 Xcode ⌘U)。
        // 測試邏輯共用 MyParrotCore 的 SelfTest 案例,與 MyParrotSelfTest 執行檔零重複。
        .testTarget(
            name: "MyParrotTests",
            dependencies: ["MyParrotCore"],
            path: "Tests/MyParrotTests",
            swiftSettings: flavorSettings
        )
    ]
)
