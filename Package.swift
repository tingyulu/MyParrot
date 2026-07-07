// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyParrot",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        // OpenCC 簡→繁(台灣正體+慣用詞),whisper 中文輸出常是簡體(TR-17)。
        .package(url: "https://github.com/ddddxxx/SwiftyOpenCC.git", branch: "master")
    ],
    targets: [
        // whisper.cpp 推理引擎(Metal+CoreML),由 scripts/fetch-whisper.sh 產出。
        // 二進位不進 git(35MB);clone 後先跑該腳本再 build。
        .binaryTarget(
            name: "whisper",
            path: "Frameworks/whisper.xcframework"
        ),
        .target(
            name: "MyParrotCore",
            dependencies: [
                "whisper",
                .product(name: "OpenCC", package: "SwiftyOpenCC")
            ],
            path: "Sources/MyParrotCore"
        ),
        .executableTarget(
            name: "MyParrot",
            dependencies: ["MyParrotCore"],
            path: "Sources/MyParrot"
        ),
        .executableTarget(
            name: "MyParrotSelfTest",
            dependencies: ["MyParrotCore"],
            path: "Sources/MyParrotSelfTest"
        ),
        // Swift Testing 套件(需完整 Xcode 工具鏈:`swift test` 或 Xcode ⌘U)。
        // 測試邏輯共用 MyParrotCore 的 SelfTest 案例,與 MyParrotSelfTest 執行檔零重複。
        .testTarget(
            name: "MyParrotTests",
            dependencies: ["MyParrotCore"],
            path: "Tests/MyParrotTests"
        )
    ]
)
