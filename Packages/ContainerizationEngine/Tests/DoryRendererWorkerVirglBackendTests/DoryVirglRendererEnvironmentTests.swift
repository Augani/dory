import Darwin
import DoryVirglRendererShim
import Testing

@Suite(.serialized)
struct DoryVirglRendererStaticConfigurationTests {
    @Test
    func retiredVenusOnlyInitializationContractRemainsExplicit() {
        let threadSync = Int32(DORY_VIRGL_RENDERER_THREAD_SYNC)
        let externalBlob = Int32(DORY_VIRGL_RENDERER_USE_EXTERNAL_BLOB)
        let venus = Int32(DORY_VIRGL_RENDERER_VENUS)
        let noVirgl = Int32(DORY_VIRGL_RENDERER_NO_VIRGL)
        let asyncFenceCallback = Int32(DORY_VIRGL_RENDERER_ASYNC_FENCE_CALLBACK)
        let renderServer = Int32(DORY_VIRGL_RENDERER_RENDER_SERVER)
        let expected = threadSync | externalBlob | venus | noVirgl |
            asyncFenceCallback | renderServer

        #expect(Int32(DORY_VIRGL_RENDERER_VENUS_ONLY_INITIALIZATION_FLAGS) == expected)
        #expect((expected & noVirgl) != 0)
        #expect((expected & threadSync) != 0)
        #expect((expected & asyncFenceCallback) != 0)
    }

    @Test
    func productionWorkerInitializationUsesExternalANGLEAndVenusTogether() {
        let useEGL = Int32(DORY_VIRGL_RENDERER_USE_EGL)
        let threadSync = Int32(DORY_VIRGL_RENDERER_THREAD_SYNC)
        let useGLES = Int32(DORY_VIRGL_RENDERER_USE_GLES)
        let externalBlob = Int32(DORY_VIRGL_RENDERER_USE_EXTERNAL_BLOB)
        let venus = Int32(DORY_VIRGL_RENDERER_VENUS)
        let noVirgl = Int32(DORY_VIRGL_RENDERER_NO_VIRGL)
        let asyncFenceCallback = Int32(DORY_VIRGL_RENDERER_ASYNC_FENCE_CALLBACK)
        let renderServer = Int32(DORY_VIRGL_RENDERER_RENDER_SERVER)
        let nativeSharedTexture = Int32(DORY_VIRGL_RENDERER_NATIVE_SHARE_TEXTURE)
        let expected = threadSync | useGLES | externalBlob | venus |
            asyncFenceCallback | renderServer | nativeSharedTexture

        let actual = Int32(DORY_VIRGL_RENDERER_DUAL_METAL_INITIALIZATION_FLAGS)
        #expect(actual == expected)
        // Deliberately omit USE_EGL: virglrenderer then initializes its external winsys from the
        // callback-provided, explicitly Metal ANGLE EGLDisplay instead of choosing an internal one.
        #expect((actual & useEGL) == 0)
        #expect((actual & noVirgl) == 0)
        #expect((actual & nativeSharedTexture) != 0)
    }

    @Test
    func developmentBuildWithoutStaticArchivesFailsClosedAndReleasesItsSlot() {
        setenv("APP_SANDBOX_GROUP_ID", "attacker-controlled-group", 1)
        var first: OpaquePointer?
        #expect(DoryVirglRendererSessionCreate(&first) == -ENOSYS)
        #expect(first == nil)
        #expect(String(cString: getenv("APP_SANDBOX_GROUP_ID")) == "864H636QW4.dory-renderer")

        var second: OpaquePointer?
        #expect(DoryVirglRendererSessionCreate(&second) == -ENOSYS)
        #expect(second == nil)
    }

}
