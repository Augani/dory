import Testing
@testable import DorydKit

@Suite("Machine diagnostic override projection")
struct DoryMachineDiagnosticOverrideTests {
    @Test("only effective closed overrides are projected without values")
    func configuredProjection() {
        let overrides = DoryMachineDiagnosticOverride.configured(in: [
            "DORY_GPU_TRACE_RESOURCES": "1",
            "DORY_VIRGL_SYNC_MODE": "CLIENT-WAIT",
            "DORY_VIRGLRENDERER_PATH": "/private/renderer.dylib",
            "DORY_MOLTENVK_ICD": "",
            "PRIVATE_TOKEN": "opaque",
        ])

        #expect(overrides == [
            .gpuResourceTracing,
            .virglRendererPath,
            .virglSyncMode,
        ])
        #expect(overrides.map(\.rawValue).joined().contains("/private") == false)
        #expect(overrides.map(\.rawValue).joined().contains("opaque") == false)
    }

    @Test("invalid compatibility values are not reported as active")
    func invalidValuesAreInactive() {
        #expect(DoryMachineDiagnosticOverride.configured(in: [
            "DORY_GPU_TRACE_RESOURCES": "true",
            "DORY_VIRGL_SYNC_MODE": "invented",
        ]).isEmpty)
    }
}
