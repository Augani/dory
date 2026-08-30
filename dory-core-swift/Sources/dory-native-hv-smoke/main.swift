import DoryNativeHVArm64
import Foundation

#if arch(arm64)
  if #available(macOS 15.0, *) {
    do {
      let receipt = try DoryNativeHVArm64Smoke.run()
      FileHandle.standardOutput.write(try JSONEncoder().encode(receipt))
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
