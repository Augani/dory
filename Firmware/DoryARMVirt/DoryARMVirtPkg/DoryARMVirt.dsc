# DoryARMVirt-v1 EDK II platform description.
# SPDX-License-Identifier: BSD-2-Clause-Patent

[Defines]
  PLATFORM_NAME           = DoryARMVirt
  PLATFORM_GUID           = 128f4db2-cb46-454b-b2b1-807195794323
  PLATFORM_VERSION        = 1.0
  DSC_SPECIFICATION       = 0x0001001B
  OUTPUT_DIRECTORY        = Build/DoryARMVirt-AArch64
  SUPPORTED_ARCHITECTURES = AARCH64
  BUILD_TARGETS           = RELEASE
  SKUID_IDENTIFIER        = DEFAULT
  FLASH_DEFINITION        = DoryARMVirtPkg/DoryARMVirt.fdf

  DEFINE SECURE_BOOT_ENABLE = FALSE
  DEFINE TTY_TERMINAL       = FALSE

!include ArmVirtPkg/ArmVirtStackCookies.dsc.inc
!include MdePkg/MdeLibs.dsc.inc
!include ArmVirtPkg/ArmVirt.dsc.inc

[LibraryClasses.common]
  ArmPlatformLib|ArmPlatformPkg/Library/ArmPlatformLibNull/ArmPlatformLibNull.inf
  ArmTransferListLib|ArmPkg/Library/ArmTransferListLib/ArmTransferListLib.inf
  ArmVirtMemInfoLib|DoryARMVirtPkg/Library/DoryVirtMemInfoLib/DoryVirtMemInfoLib.inf
  PlatformPeiLib|DoryARMVirtPkg/Library/DoryPlatformPeiLib/DoryPlatformPeiLib.inf

  PlatformBootManagerLib|ArmPkg/Library/PlatformBootManagerLib/PlatformBootManagerLib.inf
  PciHostBridgeUtilityLib|ArmVirtPkg/Library/ArmVirtPciHostBridgeUtilityLib/ArmVirtPciHostBridgeUtilityLib.inf
  PciExpressLib|MdePkg/Library/BasePciExpressLib/BasePciExpressLib.inf

  PlatformHookLib|MdeModulePkg/Library/BasePlatformHookLibNull/BasePlatformHookLibNull.inf
  SerialPortLib|ArmVirtPkg/Library/FdtPL011SerialPortLib/FdtPL011SerialPortLib.inf
  ArmMonitorLib|ArmVirtPkg/Library/ArmVirtMonitorLib/ArmVirtMonitorLib.inf
  ArmCcaBootSyncCryptoLib|ArmVirtPkg/Library/ArmCcaBootSyncCryptoLib/ArmCcaBootSyncCryptoLib.inf

[LibraryClasses.common.SEC, LibraryClasses.common.PEI_CORE, LibraryClasses.common.PEIM]
  SerialPortLib|ArmVirtPkg/Library/FdtPL011SerialPortLib/EarlyFdtPL011SerialPortLib.inf

[LibraryClasses.common.DXE_RUNTIME_DRIVER]
  DebugLib|MdePkg/Library/BaseDebugLibNull/BaseDebugLibNull.inf

[BuildOptions]
  *_*_*_CC_FLAGS = -D DISABLE_NEW_DEPRECATED_INTERFACES
  GCC:*_*_*_CC_XIPFLAGS = -fno-jump-tables
  CLANGDWARF:*_*_AARCH64_CC_FLAGS = -Wno-tautological-constant-out-of-range-compare

[PcdsFeatureFlag.common]
  gEfiMdeModulePkgTokenSpaceGuid.PcdConOutGopSupport|FALSE
  gEfiMdeModulePkgTokenSpaceGuid.PcdHiiOsRuntimeSupport|FALSE
  gEmbeddedTokenSpaceGuid.PcdPrePiProduceMemoryTypeInformationHob|TRUE
  gEfiMdeModulePkgTokenSpaceGuid.PcdInstallAcpiSdtProtocol|FALSE

[PcdsFixedAtBuild.common]
  gEfiMdePkgTokenSpaceGuid.PcdDebugPrintErrorLevel|0x8000000F
  gArmPlatformTokenSpaceGuid.PcdCoreCount|1
  gArmPlatformTokenSpaceGuid.PcdCPUCorePrimaryStackSize|0x4000
  gArmPlatformTokenSpaceGuid.PcdSystemMemoryUefiRegionSize|0x04000000
  gArmTokenSpaceGuid.PcdSystemMemoryBase|0x80000000
  gArmTokenSpaceGuid.PcdSystemMemorySize|0x40000000
  gArmTokenSpaceGuid.PcdFdBaseAddress|0x00000000
  gArmTokenSpaceGuid.PcdFvBaseAddress|0x00001000
  gUefiOvmfPkgTokenSpaceGuid.PcdDeviceTreeInitialBaseAddress|0x90000000

  gEfiMdePkgTokenSpaceGuid.PcdUartDefaultBaudRate|115200
  gEfiMdePkgTokenSpaceGuid.PcdDefaultTerminalType|4
  gEfiMdeModulePkgTokenSpaceGuid.PcdSerialRegisterBase|0x0c000000
  gEfiMdeModulePkgTokenSpaceGuid.PcdSerialUseMmio|TRUE
  gEfiMdeModulePkgTokenSpaceGuid.PcdSerialPciDeviceInfo|{0xFF}

  gEfiMdeModulePkgTokenSpaceGuid.PcdMaxVariableSize|0x100000
  gEfiMdeModulePkgTokenSpaceGuid.PcdResetOnMemoryTypeInformationChange|FALSE
  gEfiMdeModulePkgTokenSpaceGuid.PcdBootManagerMenuFile|{ 0x21, 0xaa, 0x2c, 0x46, 0x14, 0x76, 0x03, 0x45, 0x83, 0x6e, 0x8a, 0xb6, 0xf4, 0x66, 0x23, 0x31 }
  gEmbeddedTokenSpaceGuid.PcdPrePiCpuIoSize|16
  gEfiMdePkgTokenSpaceGuid.PcdReportStatusCodePropertyMask|0

[PcdsDynamicHii]
  gEfiMdePkgTokenSpaceGuid.PcdPlatformBootTimeOut|L"Timeout"|gEfiGlobalVariableGuid|0x0|3

[PcdsDynamicDefault.common]
  gArmTokenSpaceGuid.PcdArmArchTimerSecIntrNum|0
  gArmTokenSpaceGuid.PcdArmArchTimerIntrNum|0
  gArmTokenSpaceGuid.PcdArmArchTimerVirtIntrNum|0
  gArmTokenSpaceGuid.PcdArmArchTimerHypIntrNum|0
  gArmTokenSpaceGuid.PcdArmArchTimerHypVirtIntrNum|0
  gArmTokenSpaceGuid.PcdGicDistributorBase|0
  gArmTokenSpaceGuid.PcdGicRedistributorsBase|0
  gArmTokenSpaceGuid.PcdGicInterruptInterfaceBase|0
  gEfiMdeModulePkgTokenSpaceGuid.PcdPciDisableBusEnumeration|TRUE
  gEfiMdePkgTokenSpaceGuid.PcdPciExpressBaseAddress|0x10000000
  gEfiMdePkgTokenSpaceGuid.PcdPciIoTranslation|0
  gEfiMdeModulePkgTokenSpaceGuid.PcdVideoHorizontalResolution|1024
  gEfiMdeModulePkgTokenSpaceGuid.PcdVideoVerticalResolution|768
  gEfiMdeModulePkgTokenSpaceGuid.PcdSetupVideoHorizontalResolution|1024
  gEfiMdeModulePkgTokenSpaceGuid.PcdSetupVideoVerticalResolution|768

[Components.common]
  ArmPlatformPkg/Sec/Sec.inf
  MdeModulePkg/Core/Pei/PeiMain.inf
  ArmPlatformPkg/PlatformPei/PlatformPeim.inf
  ArmVirtPkg/MemoryInitPei/MemoryInitPeim.inf
  ArmPkg/Drivers/CpuPei/CpuPei.inf
  MdeModulePkg/Core/DxeIplPeim/DxeIpl.inf

  DoryARMVirtPkg/DoryVariableRuntimeDxe/DoryVariableRuntimeDxe.inf
  MdeModulePkg/Universal/SecurityStubDxe/SecurityStubDxe.inf
  DoryARMVirtPkg/DoryPlatformDxe/DoryPlatformDxe.inf

  OvmfPkg/Fdt/VirtioFdtDxe/VirtioFdtDxe.inf
  EmbeddedPkg/Drivers/FdtClientDxe/FdtClientDxe.inf
  OvmfPkg/Fdt/HighMemDxe/HighMemDxe.inf
  OvmfPkg/VirtioBlkDxe/VirtioBlk.inf
  OvmfPkg/VirtioNetDxe/VirtioNet.inf
  OvmfPkg/VirtioRngDxe/VirtioRng.inf

  SecurityPkg/RandomNumberGenerator/RngDxe/RngDxe.inf
  MdeModulePkg/Bus/Pci/PciHostBridgeDxe/PciHostBridgeDxe.inf
