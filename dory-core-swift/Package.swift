// swift-tools-version:6.0
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let doryVMMInfoPlist = packageRoot.appendingPathComponent("Sources/dory-vmm/Info.plist").path

let package = Package(
    name: "dory-core-swift",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "DoryVMContracts", targets: ["DoryVMContracts"]),
        .library(
            name: "DoryRendererWorkerWireContracts",
            targets: ["DoryRendererWorkerWireContracts"]
        ),
        .library(name: "DoryOperations", targets: ["DoryOperations"]),
        .library(name: "DoryCore", targets: ["DoryCore"]),
        .library(name: "DorydKit", targets: ["DorydKit"]),
        .library(name: "DoryVMMKit", targets: ["DoryVMMKit"]),
        .executable(name: "doryd", targets: ["doryd"]),
        .executable(name: "dorydctl", targets: ["dorydctl"]),
        .executable(name: "dory-vmm", targets: ["dory-vmm"]),
        .executable(
            name: "dory-linux-calibration",
            targets: ["dory-linux-calibration"]
        ),
        .executable(name: "dory-network-helper", targets: ["dory-network-helper"]),
        .executable(name: "dory-dataplane-proxy", targets: ["dory-dataplane-proxy"]),
    ],
    targets: [
        .binaryTarget(name: "DoryFFI", path: "artifacts/DoryFFI.xcframework"),
        .target(
            name: "DoryVMContracts",
            dependencies: []
        ),
        // Foundation/CryptoKit-only binary renderer authority shared by doryd and the nested
        // runner. It deliberately owns no Metal, Hypervisor.framework, or foreign renderer code.
        .target(
            name: "DoryRendererWorkerWireContracts",
            dependencies: []
        ),
        .target(
            name: "DoryOperations",
            dependencies: [
                "DoryRendererWorkerWireContracts",
                "DoryVMContracts",
            ],
            linkerSettings: [.linkedLibrary("z")]
        ),
        .target(
            name: "DoryCore",
            dependencies: ["DoryFFI", "DoryOperations"]
        ),
        .target(
            name: "DorydKit",
            dependencies: [
                "DoryCore",
                "DoryOperations",
                "DoryRendererWorkerWireContracts",
                "DoryVMContracts",
            ],
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                .linkedFramework("SystemConfiguration"),
                .linkedFramework("Virtualization"),
            ]
        ),
        .target(
            name: "DoryVMMKit",
            dependencies: ["DoryCore", "DorydKit", "DoryOperations"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
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
            dependencies: ["DoryVMMKit"],
            exclude: ["Info.plist", "dory-vmm.entitlements"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", doryVMMInfoPlist,
                ]),
            ]
        ),
        // Isolated physical-qualification harness. It reuses DorydKit's exact RawHV launch
        // authority but never starts doryd, consumes a production catalog, or advances trust.
        .executableTarget(
            name: "dory-linux-calibration",
            dependencies: ["DorydKit"]
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
            name: "DoryVMContractsTests",
            dependencies: ["DoryVMContracts"]
        ),
        .testTarget(
            name: "DoryRendererWorkerWireContractsTests",
            dependencies: ["DoryRendererWorkerWireContracts"]
        ),
        .testTarget(
            name: "DoryOperationsTests",
            dependencies: ["DoryOperations", "DoryCore", "DoryVMContracts"]
        ),
        .testTarget(
            name: "DorydKitTests",
            dependencies: [
                "DorydKit",
                "DoryCore",
                "DoryRendererWorkerWireContracts",
                "DoryVMMKit",
                "DoryVMContracts",
            ]
        ),
    ]
)
