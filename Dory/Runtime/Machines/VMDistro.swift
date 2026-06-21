import Foundation

struct VMDistro: Sendable, Identifiable, Hashable {
    let name: String
    let version: String
    let imageName: String
    let kernelURL: URL
    let initrdURL: URL
    let rootTarURL: URL
    var id: String { imageName }

    static let ubuntu2404 = VMDistro(
        name: "Ubuntu",
        version: "24.04 LTS",
        imageName: "ubuntu-24.04",
        kernelURL: URL(string: "https://cloud-images.ubuntu.com/noble/current/unpacked/noble-server-cloudimg-arm64-vmlinuz-generic")!,
        initrdURL: URL(string: "https://cloud-images.ubuntu.com/noble/current/unpacked/noble-server-cloudimg-arm64-initrd-generic")!,
        rootTarURL: URL(string: "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-arm64-root.tar.xz")!
    )
}
