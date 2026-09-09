// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ForgePlatformInstaller",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ForgePlatformInstallerCore", targets: ["ForgePlatformInstallerCore"]),
        .executable(name: "ForgePlatformInstaller", targets: ["ForgePlatformInstaller"]),
    ],
    targets: [
        .target(name: "ForgePlatformInstallerCore"),
        .executableTarget(
            name: "ForgePlatformInstaller",
            dependencies: ["ForgePlatformInstallerCore"]
        ),
        .testTarget(
            name: "ForgePlatformInstallerCoreTests",
            dependencies: ["ForgePlatformInstallerCore"]
        ),
    ]
)
