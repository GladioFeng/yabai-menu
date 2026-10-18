// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "YabaiMenu",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "YabaiMenu", targets: ["YabaiMenu"])],
    targets: [
        .target(name: "YabaiMenuKit"),
        .executableTarget(name: "YabaiMenu", dependencies: ["YabaiMenuKit"]),
        .testTarget(name: "YabaiMenuTests", dependencies: ["YabaiMenuKit"], resources: [.process("Fixtures")])
    ]
)
