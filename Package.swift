// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "iPhoneKit", platforms: [.macOS("14.6")],
    products: [
        .library(name: "IPhoneKitCore", targets: ["IPhoneKitCore"]),
        .library(name: "IPhoneKitAPI", targets: ["IPhoneKitAPI"]),
        .library(name: "IPhoneKitAgent", targets: ["IPhoneKitAgent"]),
        .executable(name: "IPhoneKit", targets: ["IPhoneKitApp"]),
        .executable(name: "iphonekit-mcp", targets: ["IPhoneKitMCP"]),
    ],
    targets: [
        .target(name: "IPhoneKitCore", linkerSettings: [
            .linkedFramework("AppKit"), .linkedFramework("AVFoundation"), .linkedFramework("CoreMediaIO"),
            .linkedFramework("CoreBluetooth"), .linkedFramework("IOBluetooth"), .linkedFramework("IOKit"),
        ]),
        .target(name: "IPhoneKitAPI", dependencies: ["IPhoneKitCore"]),
        .target(name: "IPhoneKitAgent", dependencies: ["IPhoneKitCore"]),
        .executableTarget(name: "IPhoneKitApp", dependencies: ["IPhoneKitCore", "IPhoneKitAPI", "IPhoneKitAgent"]),
        .executableTarget(name: "IPhoneKitMCP", dependencies: ["IPhoneKitCore"]),
        .testTarget(name: "IPhoneKitCoreTests", dependencies: ["IPhoneKitCore"]),
        .testTarget(name: "IPhoneKitAPITests", dependencies: ["IPhoneKitAPI"]),
        .testTarget(name: "IPhoneKitAgentTests", dependencies: ["IPhoneKitAgent"]),
    ]
)
