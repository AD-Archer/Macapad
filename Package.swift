// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Macapad",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-http-types.git", from: "1.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Macapad",
            dependencies: [
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "HTTPTypes", package: "swift-http-types"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
