// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyParrot",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .target(
            name: "MyParrotCore",
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
