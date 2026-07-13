// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "dory-core-swift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DoryOperations", targets: ["DoryOperations"]),
        .library(name: "DoryCore", targets: ["DoryCore"]),
        .library(name: "DorydKit", targets: ["DorydKit"]),
        .library(name: "DoryVMMKit", targets: ["DoryVMMKit"]),
        .executable(name: "doryd", targets: ["doryd"]),
        .executable(name: "dorydctl", targets: ["dorydctl"]),
        .executable(name: "dory-vmm", targets: ["dory-vmm"]),
        .executable(name: "dory-network-helper", targets: ["dory-network-helper"]),
        .executable(name: "dory-dataplane-proxy", targets: ["dory-dataplane-proxy"]),
    ],
    targets: [
        .binaryTarget(name: "DoryFFI", path: "artifacts/DoryFFI.xcframework"),
        .target(name: "DoryOperations"),
        .target(
            name: "DoryCore",
            dependencies: ["DoryFFI", "DoryOperations"]
        ),
        .target(
            name: "DorydKit",
            dependencies: ["DoryCore"],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
            ]
        ),
        .target(
            name: "DoryVMMKit",
            dependencies: ["DoryCore", "DorydKit"],
            linkerSettings: [
                .linkedFramework("Virtualization"),
            ]
        ),
        .executableTarget(
            name: "doryd",
            dependencies: ["DorydKit"]
        ),
        .executableTarget(
            name: "dorydctl",
            dependencies: ["DorydKit", "DoryCore"]
        ),
        .executableTarget(
            name: "dory-vmm",
            dependencies: ["DoryVMMKit"]
        ),
        .executableTarget(
            name: "dory-network-helper",
            dependencies: ["DorydKit"]
        ),
        .executableTarget(
            name: "dory-dataplane-proxy",
            dependencies: ["DorydKit", "DoryCore"]
        ),
        .testTarget(
            name: "DoryCoreTests",
            dependencies: ["DoryCore"]
        ),
        .testTarget(
            name: "DoryOperationsTests",
            dependencies: ["DoryOperations"]
        ),
        .testTarget(
            name: "DorydKitTests",
            dependencies: ["DorydKit", "DoryCore", "DoryVMMKit"]
        ),
    ]
)
