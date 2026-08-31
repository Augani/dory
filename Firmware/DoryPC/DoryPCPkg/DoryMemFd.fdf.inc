## @file
#  DoryPC-v1 SEC/PEI/DXE memory firmware-volume layout.
#
#  SPDX-License-Identifier: BSD-2-Clause-Patent
##

[FD.MEMFD]
BaseAddress   = $(MEMFD_BASE_ADDRESS)
Size          = 0x320000
ErasePolarity = 1
BlockSize     = 0x10000
NumBlocks     = 0x32

# Initial reset-vector page tables.
0x000000|0x006000
gUefiOvmfPkgTokenSpaceGuid.PcdOvmfSecPageTablesBase|gUefiOvmfPkgTokenSpaceGuid.PcdOvmfSecPageTablesSize

0x006000|0x001000
gUefiOvmfPkgTokenSpaceGuid.PcdOvmfLockBoxStorageBase|gUefiOvmfPkgTokenSpaceGuid.PcdOvmfLockBoxStorageSize

0x007000|0x001000
gEfiMdePkgTokenSpaceGuid.PcdGuidedExtractHandlerTableAddress|gUefiOvmfPkgTokenSpaceGuid.PcdGuidedExtractHandlerTableSize

0x008000|0x001000
gUefiOvmfPkgTokenSpaceGuid.PcdOvmfSecGhcbPageTableBase|gUefiOvmfPkgTokenSpaceGuid.PcdOvmfSecGhcbPageTableSize

0x009000|0x002000
gUefiOvmfPkgTokenSpaceGuid.PcdOvmfSecGhcbBase|gUefiOvmfPkgTokenSpaceGuid.PcdOvmfSecGhcbSize

0x00B000|0x001000
gUefiOvmfPkgTokenSpaceGuid.PcdOvmfWorkAreaBase|gUefiOvmfPkgTokenSpaceGuid.PcdOvmfWorkAreaSize

0x00C000|0x001000
gUefiOvmfPkgTokenSpaceGuid.PcdOvmfSecGhcbBackupBase|gUefiOvmfPkgTokenSpaceGuid.PcdOvmfSecGhcbBackupSize

0x00D000|0x001000
gUefiOvmfPkgTokenSpaceGuid.PcdOvmfSnpSecretsBase|gUefiOvmfPkgTokenSpaceGuid.PcdOvmfSnpSecretsSize

0x00E000|0x001000
gUefiOvmfPkgTokenSpaceGuid.PcdOvmfCpuidBase|gUefiOvmfPkgTokenSpaceGuid.PcdOvmfCpuidSize

0x00F000|0x001000
gUefiOvmfPkgTokenSpaceGuid.PcdOvmfSecSvsmCaaBase|gUefiOvmfPkgTokenSpaceGuid.PcdOvmfSecSvsmCaaSize

0x010000|0x000C00
gUefiOvmfPkgTokenSpaceGuid.PcdSevLaunchSecretBase|gUefiOvmfPkgTokenSpaceGuid.PcdSevLaunchSecretSize

0x010C00|0x000400
gUefiOvmfPkgTokenSpaceGuid.PcdQemuHashTableBase|gUefiOvmfPkgTokenSpaceGuid.PcdQemuHashTableSize

0x011000|0x001000
gUefiOvmfPkgTokenSpaceGuid.PcdOvmfSecApicPageTableBase|gUefiOvmfPkgTokenSpaceGuid.PcdOvmfSecApicPageTableSize

0x012000|0x001000
gUefiOvmfPkgTokenSpaceGuid.PcdOvmfIgvmParamBase|gUefiOvmfPkgTokenSpaceGuid.PcdOvmfIgvmParamSize

0x013000|0x001000
gUefiOvmfPkgTokenSpaceGuid.PcdOvmfIgvmHobBase|gUefiOvmfPkgTokenSpaceGuid.PcdOvmfIgvmHobSize

# SEC/PEI temporary RAM and diagnostics remain at the upstream-compatible addresses used by the
# reset vector. Only the firmware volumes below are right-sized for Dory's deliberately smaller
# production driver set.
0x014000|0x00C000
gUefiOvmfPkgTokenSpaceGuid.PcdOvmfSecPeiTempRamBase|gUefiOvmfPkgTokenSpaceGuid.PcdOvmfSecPeiTempRamSize

0x020000|0x010000
gUefiOvmfPkgTokenSpaceGuid.PcdOvmfEarlyMemDebugLogBase|gUefiOvmfPkgTokenSpaceGuid.PcdOvmfEarlyMemDebugLogSize

# Current RELEASE usage is below 0x1E000. Keep a full 64 KiB growth block.
0x030000|0x030000
gUefiOvmfPkgTokenSpaceGuid.PcdOvmfPeiMemFvBase|gUefiOvmfPkgTokenSpaceGuid.PcdOvmfPeiMemFvSize
FV = PEIFV

# Current RELEASE usage is below 0x2A0000. Keep two 64 KiB growth blocks.
0x060000|0x2C0000
gUefiOvmfPkgTokenSpaceGuid.PcdOvmfDxeMemFvBase|gUefiOvmfPkgTokenSpaceGuid.PcdOvmfDxeMemFvSize
FV = DXEFV

SET gUefiCpuPkgTokenSpaceGuid.PcdSevEsWorkAreaBase = $(MEMFD_BASE_ADDRESS) +  gUefiOvmfPkgTokenSpaceGuid.PcdOvmfWorkAreaBase + gUefiOvmfPkgTokenSpaceGuid.PcdOvmfConfidentialComputingWorkAreaHeader
SET gUefiCpuPkgTokenSpaceGuid.PcdSevEsWorkAreaSize = gUefiOvmfPkgTokenSpaceGuid.PcdOvmfWorkAreaSize - gUefiOvmfPkgTokenSpaceGuid.PcdOvmfConfidentialComputingWorkAreaHeader
