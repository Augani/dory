import Foundation
@inline(never) func fill(_ dest: UnsafeMutableRawPointer, _ pattern: [UInt8], _ count: Int, _ bulk: Bool) {
 pattern.withUnsafeBufferPointer { b in
  if bulk {
   dest.copyMemory(from: b.baseAddress!, byteCount: pattern.count)
   var filled = pattern.count
   let total = count * pattern.count
   while filled < total {
    let n = min(filled, total - filled)
    dest.advanced(by: filled).copyMemory(from: dest, byteCount: n)
    filled += n
   }
  } else {
   for i in 0..<count { dest.advanced(by: i * pattern.count).copyMemory(from: b.baseAddress!, byteCount: pattern.count) }
  }
 }
}
let p = UnsafeMutableRawPointer.allocate(byteCount: 32768, alignment: 16)
defer { p.deallocate() }
for size in [1, 2, 4, 8] {
 let pattern = (0..<size).map { UInt8($0 + 1) }
 for count in [1, 8, 512, 4096] {
  for bulk in [false, true] {
   let start = DispatchTime.now().uptimeNanoseconds
   for _ in 0..<20000 { fill(p, pattern, count, bulk) }
   let ns = DispatchTime.now().uptimeNanoseconds - start
   print("width=\(size) count=\(count) bulk=\(bulk) ns=\(ns) check=\(p.load(as: UInt8.self))")
  }
 }
}
