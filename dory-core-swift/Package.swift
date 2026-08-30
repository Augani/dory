// swift-tools-version:6.0
import Foundation
import PackageDescription

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let doryVMMInfoPlist = packageRoot.appendingPathComponent("Sources/dory-vmm/Info.plist").path

let package = Package(
  name: "dory-core-swift",
  platforms: [.macOS(.v14)],
  products: [
    .library(name: "DoryExecutionContracts", targets: ["DoryExecutionContracts"]),
    .library(name: "DoryMachineARMVirt", targets: ["DoryMachineARMVirt"]),
    .library(name: "DoryFirmware", targets: ["DoryFirmware"]),
    .library(name: "DoryNativeHVArm64", targets: ["DoryNativeHVArm64"]),
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
    .executable(
      name: "dory-native-hv-smoke",
      targets: ["dory-native-hv-smoke"]
    ),
    .executable(name: "dory-network-helper", targets: ["dory-network-helper"]),
    .executable(name: "dory-dataplane-proxy", targets: ["dory-dataplane-proxy"]),
    .executable(name: "dory-jit-probe", targets: ["dory-jit-probe"]),
    .executable(
      name: "dory-firmware-bundler",
      targets: ["dory-firmware-bundler"]
    ),
  ],
  targets: [
    .binaryTarget(name: "DoryFFI", path: "artifacts/DoryFFI.xcframework"),
    .target(
      name: "DoryExecutionContracts",
      dependencies: []
    ),
    .target(
      name: "DoryMachineARMVirt",
      dependencies: ["DoryExecutionContracts"]
    ),
    .target(
      name: "DoryFirmware",
      dependencies: ["DoryMachineARMVirt"]
    ),
    .target(
      name: "DoryNativeHVArm64",
      dependencies: ["DoryExecutionContracts"],
      linkerSettings: [.linkedFramework("Hypervisor")]
    ),
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
        "DoryExecutionContracts",
        "DoryFirmware",
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
        .linkedFramework("AppKit"),
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
      dependencies: ["DorydKit", "DoryCore", "DoryOperations"]
    ),
    .executableTarget(
      name: "dory-vmm",
      dependencies: ["DoryVMMKit", "DorydKit"],
      exclude: ["Info.plist", "dory-vmm.entitlements"],
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "-sectcreate",
          "-Xlinker", "__TEXT",
          "-Xlinker", "__info_plist",
          "-Xlinker", doryVMMInfoPlist,
        ])
      ]
    ),
    // Isolated physical-qualification harness. It reuses DorydKit's exact RawHV launch
    // authority but never starts doryd, consumes a production catalog, or advances trust.
    .executableTarget(
      name: "dory-linux-calibration",
      dependencies: ["DorydKit"]
    ),
    .executableTarget(
      name: "dory-native-hv-smoke",
      dependencies: ["DoryNativeHVArm64"]
    ),
    .executableTarget(
      name: "dory-network-helper",
      dependencies: ["DorydKit"]
    ),
    .executableTarget(
      name: "dory-dataplane-proxy",
      dependencies: ["DorydKit", "DoryCore"]
    ),
    // Phase 0A release-configuration probe. This intentionally has no dependency on Dory,
    // DBT, Foundation, or dynamically loaded code: the signed executable proves the narrow
    // MAP_JIT/callback-allowlist publication contract before the translator is implemented.
    .executableTarget(
      name: "dory-jit-probe",
      path: "Sources/dory-jit-probe"
    ),
    .executableTarget(
      name: "dory-firmware-bundler",
      dependencies: ["DoryFirmware"]
    ),
    .testTarget(
      name: "DoryCoreTests",
      dependencies: ["DoryCore"]
    ),
    .testTarget(
      name: "DoryExecutionContractsTests",
      dependencies: ["DoryExecutionContracts"]
    ),
    .testTarget(
      name: "DoryMachineARMVirtTests",
      dependencies: ["DoryMachineARMVirt"]
    ),
    .testTarget(
      name: "DoryFirmwareTests",
      dependencies: ["DoryFirmware", "DoryMachineARMVirt"]
    ),
    .testTarget(
      name: "DoryNativeHVArm64Tests",
      dependencies: ["DoryExecutionContracts", "DoryNativeHVArm64"]
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
      dependencies: ["DoryOperations", "DoryCore", "DoryFirmware", "DoryVMContracts"]
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
