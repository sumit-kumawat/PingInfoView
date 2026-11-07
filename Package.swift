// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PingInfoView",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "PingInfoView", targets: ["PingInfoView"])
    ],
    targets: [
        .executableTarget(
            name: "PingInfoView",
            path: "Sources/PingInfoView"
        ),
        .testTarget(
            name: "PingInfoViewTests",
            dependencies: ["PingInfoView"],
            path: "Tests/PingInfoViewTests"
        )
    ]
)
