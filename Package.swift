// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FanMacly",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "FanMacly", targets: ["FanMacly"]),
        .executable(name: "FanMaclyHelper", targets: ["FanMaclyHelper"]),
        .executable(name: "fanmacly-probe", targets: ["FanMaclyProbe"])
    ],
    targets: [
        .target(name: "SMCBridge", publicHeadersPath: "include", linkerSettings: [.linkedFramework("IOKit")]),
        .target(name: "FanMaclyCore", dependencies: ["SMCBridge"], linkerSettings: [.linkedFramework("Security")]),
        .executableTarget(name: "FanMacly", dependencies: ["FanMaclyCore"], linkerSettings: [.linkedFramework("ServiceManagement")]),
        .executableTarget(name: "FanMaclyHelper", dependencies: ["FanMaclyCore"]),
        .executableTarget(name: "FanMaclyProbe", dependencies: ["FanMaclyCore"]),
        .testTarget(name: "FanMaclyCoreTests", dependencies: ["FanMaclyCore"]),
        .testTarget(name: "FanMaclyUITests", dependencies: ["FanMacly"])
    ],
    swiftLanguageModes: [.v5]
)
