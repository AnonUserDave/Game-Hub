// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GameHub",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "GameHub", targets: ["GameHub"])],
    targets: [
        .target(name: "FusionUSB", path: "Sources/FusionUSB", publicHeadersPath: "include", cSettings: [.unsafeFlags(["-fobjc-arc"])], linkerSettings: [.linkedFramework("Foundation"), .linkedFramework("IOKit"), .linkedFramework("IOUSBHost")]),
        .executableTarget(name: "GameHub", dependencies: ["FusionUSB"], path: "Sources/GameHub", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "GameHubTests", dependencies: ["GameHub", "FusionUSB"], path: "Tests/Swift", swiftSettings: [.swiftLanguageMode(.v5)])
    ]
)
