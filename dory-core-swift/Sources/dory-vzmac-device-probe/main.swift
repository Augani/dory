import Foundation
import DoryVZMacSDKInventory
import Virtualization

#if canImport(AccessoryAccess)
import AccessoryAccess
#endif

#if arch(arm64)
private let hostArchitecture = "arm64"
#else
private let hostArchitecture = "unsupported"
#endif

private struct ConstructedPublicDevices: Codable {
    var macGraphicsDisplay: Bool
    var configuredGuestDisplayCount: Int
    var macKeyboard: Bool
    var macTrackpad: Bool
    var hostAudioInput: Bool
    var hostAudioOutput: Bool
    var xhciController: Bool
}

private struct PublicSDKBoundary: Codable {
    var sdkMaximumAllowed: Int32
    var accessoryAccessDeclared: Bool
    var physicalUSBPassthroughDeclared: Bool
    var physicalUSBConfigurationConstructorCompiled: Bool
    var physicalUSBMinimumHostVersion: String?
    var physicalUSBAuthorityProcess: String?
    var physicalUSBRequiredEntitlements: [String]
    var cameraInjectionDeclared: Bool
    var runtimeClassPresence: [String: Bool]
}

private struct ProbeReceipt: Codable {
    var schema: String
    var status: String
    var hostArchitecture: String
    var hostProductVersion: String
    var hostBuildVersion: String
    var constructedPublicDevices: ConstructedPublicDevices
    var publicSDKBoundary: PublicSDKBoundary
    var releaseGateClosed: Bool
    var blockers: [String]
}

private func operatingSystemBuildVersion() -> String {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/sw_vers")
    task.arguments = ["-buildVersion"]
    let output = Pipe()
    task.standardOutput = output
    task.standardError = FileHandle.nullDevice
    do {
        try task.run()
        task.waitUntilExit()
        guard task.terminationStatus == 0 else { return "unavailable" }
        return String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    } catch {
        return "unavailable"
    }
}

private func runtimeClassPresence(_ names: [String]) -> [String: Bool] {
    Dictionary(uniqueKeysWithValues: names.map { ($0, NSClassFromString($0) != nil) })
}

#if canImport(AccessoryAccess)
@available(macOS 27.0, *)
private func makePhysicalUSBConfiguration(
    accessory: AAUSBAccessory
) -> VZUSBPassthroughDeviceConfiguration {
    VZUSBPassthroughDeviceConfiguration(device: accessory)
}

private func physicalUSBConfigurationConstructorCompiled() -> Bool {
    guard #available(macOS 27.0, *) else { return false }
    let witness: (AAUSBAccessory) -> VZUSBPassthroughDeviceConfiguration =
        makePhysicalUSBConfiguration
    _ = witness
    return true
}
#else
private func physicalUSBConfigurationConstructorCompiled() -> Bool {
    false
}
#endif

private func publicSDKBoundary() -> PublicSDKBoundary {
    let accessoryAccessDeclared = dory_vzmac_accessory_access_declared()
    let physicalUSBDeclared = dory_vzmac_physical_usb_declared()
    let cameraDeclared = dory_vzmac_camera_injection_declared()
    return PublicSDKBoundary(
        sdkMaximumAllowed: dory_vzmac_sdk_max_allowed(),
        accessoryAccessDeclared: accessoryAccessDeclared,
        physicalUSBPassthroughDeclared: physicalUSBDeclared,
        physicalUSBConfigurationConstructorCompiled:
            physicalUSBConfigurationConstructorCompiled(),
        physicalUSBMinimumHostVersion: physicalUSBDeclared ? "27.0" : nil,
        physicalUSBAuthorityProcess: accessoryAccessDeclared
            ? "ordinary Dock-visible application"
            : nil,
        physicalUSBRequiredEntitlements: accessoryAccessDeclared
            ? [
                "com.apple.developer.accessory-access.usb",
                "com.apple.security.virtualization",
            ]
            : [],
        cameraInjectionDeclared: cameraDeclared,
        runtimeClassPresence: runtimeClassPresence([
            "VZUSBPassthroughDevice",
            "VZUSBPassthroughDeviceConfiguration",
            "VZCameraDevice",
            "VZCameraDeviceConfiguration",
            "VZMacCameraDeviceConfiguration",
        ])
    )
}

private func runProbe() -> ProbeReceipt {
    guard hostArchitecture == "arm64" else {
        return ProbeReceipt(
            schema: "dory.phase0a.vzmac-device-api-probe@2",
            status: "BLOCKED_UNSUPPORTED_HOST",
            hostArchitecture: hostArchitecture,
            hostProductVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            hostBuildVersion: operatingSystemBuildVersion(),
            constructedPublicDevices: .init(
                macGraphicsDisplay: false,
                configuredGuestDisplayCount: 0,
                macKeyboard: false,
                macTrackpad: false,
                hostAudioInput: false,
                hostAudioOutput: false,
                xhciController: false
            ),
            publicSDKBoundary: publicSDKBoundary(),
            releaseGateClosed: false,
            blockers: ["VZMac is available only on Apple-silicon hosts"]
        )
    }

    let display = VZMacGraphicsDisplayConfiguration(
        widthInPixels: 1_920,
        heightInPixels: 1_080,
        pixelsPerInch: 144
    )
    let graphics = VZMacGraphicsDeviceConfiguration()
    graphics.displays = [display]
    _ = VZMacKeyboardConfiguration()
    _ = VZMacTrackpadConfiguration()

    let input = VZVirtioSoundDeviceInputStreamConfiguration()
    input.source = VZHostAudioInputStreamSource()
    let output = VZVirtioSoundDeviceOutputStreamConfiguration()
    output.sink = VZHostAudioOutputStreamSink()
    let sound = VZVirtioSoundDeviceConfiguration()
    sound.streams = [input, output]

    let xhciController: Bool
    if #available(macOS 15.0, *) {
        let xhci = VZXHCIControllerConfiguration()
        xhci.usbDevices = []
        xhciController = xhci.usbDevices.isEmpty
    } else {
        xhciController = false
    }

    let sdkBoundary = publicSDKBoundary()
    var blockers = [
        "the compiling public SDK declares no VZ camera-injection type",
        "configuration construction is not a restore/install/runtime qualification",
    ]
    if sdkBoundary.physicalUSBPassthroughDeclared {
        blockers.append(
            "physical USB requires final-public-API confirmation, an entitled Dock-visible app, an authorized accessory, and runtime attach/detach qualification"
        )
    } else {
        blockers.append("the compiling public SDK declares no VZ physical-USB passthrough type")
    }
    return ProbeReceipt(
        schema: "dory.phase0a.vzmac-device-api-probe@2",
        status: sdkBoundary.physicalUSBPassthroughDeclared
            ? "BLOCKED_CAMERA_ABSENT_USB_RUNTIME_QUALIFICATION_PENDING"
            : "BLOCKED_REQUIRED_PUBLIC_DEVICE_PATHS_ABSENT",
        hostArchitecture: hostArchitecture,
        hostProductVersion: ProcessInfo.processInfo.operatingSystemVersionString,
        hostBuildVersion: operatingSystemBuildVersion(),
        constructedPublicDevices: .init(
            macGraphicsDisplay: graphics.displays.count == 1,
            configuredGuestDisplayCount: graphics.displays.count,
            macKeyboard: true,
            macTrackpad: true,
            hostAudioInput: input.source is VZHostAudioInputStreamSource,
            hostAudioOutput: output.sink is VZHostAudioOutputStreamSink,
            xhciController: xhciController
        ),
        publicSDKBoundary: sdkBoundary,
        releaseGateClosed: false,
        blockers: blockers
    )
}

do {
    let receipt = runProbe()
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    FileHandle.standardOutput.write(try encoder.encode(receipt))
    FileHandle.standardOutput.write(Data([0x0a]))
    exit(receipt.releaseGateClosed ? EXIT_SUCCESS : 3)
} catch {
    FileHandle.standardError.write(Data("dory VZMac device probe failed: \(error)\n".utf8))
    exit(EXIT_FAILURE)
}
