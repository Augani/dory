import DoryVirglRendererShim
import Testing

@Suite struct VirglRendererABITests {
    @Test func resourceInfoUsesThePinnedImportedCLayout() {
        #expect(DoryVirglRendererResourceInfoSize() == 40)
        #expect(DoryVirglRendererResourceInfoFileDescriptorOffset() == 36)
        #expect(
            MemoryLayout<DoryVirglRendererResourceInfo>.size
                == Int(DoryVirglRendererResourceInfoSize())
        )
        #expect(
            MemoryLayout<DoryVirglRendererResourceInfo>.stride
                == Int(DoryVirglRendererResourceInfoSize())
        )
    }
}
