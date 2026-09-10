@testable import DoryDBTX86
import Testing

@Suite struct DoryJITBlockCacheTests {
  private func key(
    _ physicalRIP: UInt64,
    mode: DoryX86ExecutionMode = .long64,
    privilegeLevel: UInt8 = 0,
    pagingEnabled: Bool = true
  ) -> DoryJITBlockCacheKey {
    .init(
      physicalRIP: physicalRIP,
      executionMode: mode,
      privilegeLevel: privilegeLevel,
      pagingEnabled: pagingEnabled
    )
  }

  @Test func insertsReplacesAndRemovesExactPhysicalIdentity() throws {
    let cache = try DoryJITBlockCache(initialCapacity: 4)
    let kernel = key(0x1234)

    #expect(cache.count == 0)
    #expect(try cache.lookup(kernel) == nil)
    #expect(try cache.insert(kernel, value: 41) == nil)
    #expect(cache.count == 1)
    #expect(try cache.lookup(kernel) == 41)
    #expect(try cache.insert(kernel, value: 42) == 41)
    #expect(cache.count == 1)
    #expect(try cache.lookup(kernel) == 42)
    #expect(try cache.remove(kernel) == 42)
    #expect(cache.count == 0)
    #expect(try cache.lookup(kernel) == nil)
    #expect(try cache.remove(kernel) == nil)
  }

  @Test func distinguishesEveryArchitecturalKeyField() throws {
    let cache = try DoryJITBlockCache(initialCapacity: 16)
    let keys = [
      key(0x1000),
      key(0x2000),
      key(0x1000, mode: .protected32),
      key(0x1000, privilegeLevel: 3),
      key(0x1000, pagingEnabled: false),
    ]
    for (index, entry) in keys.enumerated() {
      try cache.insert(entry, value: UInt64(index + 1))
    }
    #expect(cache.count == keys.count)
    for (index, entry) in keys.enumerated() {
      #expect(try cache.lookup(entry) == UInt64(index + 1))
    }
  }

  @Test func preservesProbeChainsAcrossTombstonesAndGrowth() throws {
    let cache = try DoryJITBlockCache(initialCapacity: 4)
    let keys = (0..<1_000).map { key(UInt64($0) << 12) }
    for (index, entry) in keys.enumerated() {
      try cache.insert(entry, value: UInt64(index + 1))
    }
    #expect(cache.capacity >= 2_048)
    #expect(cache.count == keys.count)

    for index in stride(from: 0, to: keys.count, by: 2) {
      #expect(try cache.remove(keys[index]) == UInt64(index + 1))
    }
    for (index, entry) in keys.enumerated() {
      let expected: UInt64? = index.isMultiple(of: 2) ? nil : UInt64(index + 1)
      #expect(try cache.lookup(entry) == expected)
    }

    cache.removeAll()
    #expect(cache.count == 0)
    for entry in keys { #expect(try cache.lookup(entry) == nil) }
  }
}
