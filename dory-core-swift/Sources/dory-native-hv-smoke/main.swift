import DoryNativeHVArm64
import Foundation

#if arch(arm64)
  if #available(macOS 15.0, *) {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      let receipt = try DoryNativeHVArm64Smoke.run()
      FileHandle.standardOutput.write(try encoder.encode(receipt))
      FileHandle.standardOutput.write(Data("\n".utf8))
      let deadlines = try DoryNativeHVArm64Smoke.runDeadlineContract()
      FileHandle.standardOutput.write(try encoder.encode(deadlines))
      FileHandle.standardOutput.write(Data("\n".utf8))
      let lifecycle = try DoryNativeHVArm64Smoke.runLifecycleContract()
      FileHandle.standardOutput.write(try encoder.encode(lifecycle))
      FileHandle.standardOutput.write(Data("\n".utf8))
      let identity = try DoryNativeHVArm64Smoke.runFeatureIdentity()
      FileHandle.standardOutput.write(try encoder.encode(identity))
      FileHandle.standardOutput.write(Data("\n".utf8))
    } catch {
      FileHandle.standardError.write(Data("dory-native-hv-smoke: \(error)\n".utf8))
      exit(1)
    }
  } else {
    FileHandle.standardError.write(Data("dory-native-hv-smoke requires macOS 15 or newer\n".utf8))
    exit(2)
  }
#else
  FileHandle.standardError.write(Data("dory-native-hv-smoke requires Apple silicon\n".utf8))
  exit(2)
#endif
