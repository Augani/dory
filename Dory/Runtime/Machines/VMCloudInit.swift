import Foundation

enum VMCloudInit {
    static func createSeedISO(name: String, publicKey: String, shareURL: URL, outputURL: URL) async throws {
        let manager = FileManager.default
        let configDir = outputURL.deletingLastPathComponent().appendingPathComponent(".seed-\(name)")
        try? manager.removeItem(at: configDir)
        try manager.createDirectory(at: configDir, withIntermediateDirectories: true)

        let userData = """
        #cloud-config
        hostname: \(name)
        users:
          - name: dory
            sudo: ALL=(ALL) NOPASSWD:ALL
            ssh_authorized_keys:
              - \(publicKey)
        runcmd:
          - mkdir -p /share
          - mount -t virtiofs share /share
          - sh -c "ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1 > /share/ip.txt"
        """
        let metaData = """
        instance-id: \(name)
        local-hostname: \(name)
        """

        try userData.write(to: configDir.appendingPathComponent("user-data"), atomically: true, encoding: .utf8)
        try metaData.write(to: configDir.appendingPathComponent("meta-data"), atomically: true, encoding: .utf8)

        let result = await Shell.runAsyncResult("/usr/bin/hdiutil", [
            "makehybrid", "-iso", "-hfs",
            "-default-volume-name", "cidata",
            "-o", outputURL.path,
            configDir.path
        ])
        try? manager.removeItem(at: configDir)
        guard result.exit == 0 else {
            throw VMError.cloudInitFailed(result.output)
        }
    }
}
