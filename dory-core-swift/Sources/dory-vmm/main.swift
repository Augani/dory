import DorydKit
import DoryVMMKit
import Foundation

do {
    let arguments = try DoryApplicationLaunchHandoffClient.receiveIfRequested(
        arguments: Array(CommandLine.arguments.dropFirst())
    )
    exit(DoryVMMMain.run(arguments))
} catch {
    FileHandle.standardError.write(
        Data("dory-vmm: application launch authority handoff failed: \(error)\n".utf8)
    )
    exit(2)
}
