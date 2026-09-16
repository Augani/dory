# Candidate Freeze — Readiness 2026-09-15

## Release cell

- **Guest**: Ubuntu Server 24.04.4 ARM64
- **Host**: M2 Pro, macOS 27.0 (Build 26A428)
- **Resources**: 4 vCPUs, 8 GiB RAM, 64 GiB blank disk
- **Boot mode**: EFI
- **Engine**: dory.native-hv.arm64@1

## Pinned installer ISO

- **File**: `ubuntu-24.04.4-live-server-arm64.iso`
- **SHA-256**: `9a6ce6d7e66c8abed24d24944570a495caca80b3b0007df02818e13829f27f32`
- **Media ID**: `ubuntu-server-24.04.4-arm64`
- **Cell ID**: `linux-arm64-ubuntu-24.04.4`

## ARM firmware bundle

- **Build identifier**: `dory-armvirt-v1-14d6c32190ba6a06e65c`
- **Firmware ABI**: `dory.edk2.armvirt@1`
- **Machine ABI**: `dory.armvirt@1`
- **firmware-code.fd SHA-256**: `8313e10d930c8e3c5439a4bbda161e701ee0ad3a67fc2e5ca1967c79d0678011`
- **firmware-code.fd size**: 4,194,304 bytes
- **Platform configuration SHA-256**: `8ca421d3b24c4ca25f6ee5fbb9054e5f853392d6c74674d1fc7bbe18fb5880bf`
- **SBOM SHA-256**: `3b2624d79e34649746579648007a590c43f6c8e64af560009672e51276a864cc`
- **Toolchain SHA-256**: `73b5b15e655f95f244cf7b912f3e4d5bd5208796a76dda14539b0dc9270e1a88`
- **Variable store template SHA-256**: `6f1fbeef096baf20e7c6c4ba37ec25e0771496c3c7884dcc9cc50f3ef662ddd8`
- **Firmware tree digest**: `1f134d150fb01ecbdbf0b5bee77e786237c7f4a97eba6854b5f3c61ba8e4a26a`
- **EDK2 source**: `https://github.com/tianocore/edk2.git` @ `2970e5699ba6267f3384ffab20f96647578aebc8`
- **Secure boot policy**: disabled

## Application component hashes (Debug, ad-hoc)

- **Git revision**: `a9a230371` (clean working tree)
- **Dory.app main executable**: `d8e503c5761ebf306f945996862646381bce608ab9d95062231bb8be9f469523`
- **doryd (daemon)**: `34df1b3d02394b0fc2ce220bfe7794922ffd7273eb449b105d747d0df2da0493`
- **dorydctl**: `2a7e74154b3109f7efbff38fb67845315d40980b42b73fceef2e878ebf2a6b71`
- **dory-vmm (runner)**: `929d14051eaf6c55ab28d8501a44f8d2bef659c68ab997bb68210f8bd7a9d14a`
- **dory-hv (HV runner)**: `66db6f2fe0564f2ec301e60470bb0fae7c37e99b6d125ff204f5e9e19d1bda22`
- **DoryVMM.app/dory-vmm**: `68f80efa362da23fae5f9d464e0977ce86bf2b5fbf1e733b2896956840b9c893`
- **dory-network-helper**: `9502022df87c307aa19c4cfb89f62642b1fdb44d6f9d5b79a2e964e30d74e49d`
- **dory-dataplane-proxy**: `1bfa541bba21e6b66be6209bcbdba9a8f72466978098bb5838656e331f3511d6`
- **DoryFSWorker.xpc**: `a001398948bd58499d87dfd625a28194f39302c61d6d3fe3a8d4e7e9e4d087c3`
- **DoryRendererWorker.xpc**: `b4b7889e645148e1cb8687a1b7fc97f30941ce6ca4fcad356fe9a1b2fff390d3`

## Test suite status

- **ContainerizationEngine serial**: PASS (exit 0)
- **dory-core-swift full suite**: PASS (exit 0)
  - DorydKitTests XCTest: PASS
  - DorydKitTests Swift Testing: PASS (SIGBUS in teardown helper, not test failures)
  - DoryDBTX86Tests: PASS (SIGBUS in teardown helper, not test failures)
- **nativeWorkersOverlapFrozenRegistersAndJoin**: PASS (6/6 cases)

## Notes

- This is a Debug ad-hoc signed build, not a release-signed candidate.
- The SIGBUS crashes in the Swift Testing helper occur during process teardown
  after all tests have passed; they are JIT-related teardown issues, not test
  failures.
- `releaseQualified` remains `false` until two independent qualification
  campaigns are completed with evidence and approvals.
