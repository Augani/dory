## @file
#  DoryPC-v1 X64 UEFI platform
#
#  Copyright (c) 2006 - 2024, Intel Corporation. All rights reserved.<BR>
#  (C) Copyright 2016 Hewlett Packard Enterprise Development LP<BR>
#  Copyright (c) Microsoft Corporation.
#
#  SPDX-License-Identifier: BSD-2-Clause-Patent
#
##

################################################################################
#
# Defines Section - statements that will be processed to create a Makefile.
#
################################################################################
[Defines]
  PLATFORM_NAME                  = DoryPC
  PLATFORM_GUID                  = 84214f50-91be-494d-817b-573b5201cf09
  PLATFORM_VERSION               = 1.0
  DSC_SPECIFICATION              = 0x00010005
  OUTPUT_DIRECTORY               = Build/DoryPC-X64
  SUPPORTED_ARCHITECTURES        = X64
  BUILD_TARGETS                  = RELEASE
  SKUID_IDENTIFIER               = DEFAULT
  FLASH_DEFINITION               = DoryPCPkg/DoryPC.fdf

  #
  # Defines for default states.  These can be changed on the command line.
  # -D FLAG=VALUE
  #
  DEFINE SECURE_BOOT_ENABLE      = FALSE
  DEFINE SMM_REQUIRE             = FALSE
  DEFINE QEMU_PV_VARS            = FALSE
  DEFINE STANDALONE_MM_ENABLE    = FALSE
  DEFINE SOURCE_DEBUG_ENABLE     = FALSE
  DEFINE CC_MEASUREMENT_ENABLE   = FALSE
  DEFINE DEBUG_TO_MEM            = FALSE

!include OvmfPkg/Include/Dsc/OvmfTpmDefines.dsc.inc

  #
  # Shell can be useful for debugging but should not be enabled for production
  #
  DEFINE BUILD_SHELL             = FALSE

  #
  # Network definition
  #
  DEFINE NETWORK_TLS_ENABLE             = FALSE
  DEFINE NETWORK_IP6_ENABLE             = FALSE
  DEFINE NETWORK_HTTP_BOOT_ENABLE       = FALSE
  DEFINE NETWORK_ALLOW_HTTP_CONNECTIONS = TRUE
  DEFINE NETWORK_ISCSI_ENABLE           = FALSE
  DEFINE NETWORK_ISCSI_DEFAULT_ENABLE   = FALSE
  DEFINE NETWORK_PXE_BOOT_ENABLE        = FALSE

!include NetworkPkg/NetworkDefines.dsc.inc

  #
  # Device drivers
  #
!include OvmfPkg/Include/Dsc/OvmfOptHwDefines.dsc.inc

  #
  # Flash size selection. Setting FD_SIZE_IN_KB on the command line directly to
  # one of the supported values, in place of any of the convenience macros, is
  # permitted.
  #
!ifdef $(FD_SIZE_1MB)
  DEFINE FD_SIZE_IN_KB           = 1024
!else
!ifdef $(FD_SIZE_2MB)
  DEFINE FD_SIZE_IN_KB           = 2048
!else
!ifdef $(FD_SIZE_4MB)
  DEFINE FD_SIZE_IN_KB           = 4096
!else
  DEFINE FD_SIZE_IN_KB           = 4096
!endif
!endif
!endif

  #
  # Define the FILE_GUID of CpuMpPei/CpuDxe for unique-processor version.
  #
  DEFINE UP_CPU_PEI_GUID  = 280251c4-1d09-4035-9062-839acb5f18c1
  DEFINE UP_CPU_DXE_GUID  = 6490f1c5-ebcc-4665-8892-0075b9bb49b7

!include OvmfPkg/Include/Dsc/OvmfPkg.dsc.inc

[BuildOptions]
  GCC:RELEASE_*_*_CC_FLAGS             = -DMDEPKG_NDEBUG
  INTEL:RELEASE_*_*_CC_FLAGS           = /D MDEPKG_NDEBUG
  MSFT:RELEASE_*_*_CC_FLAGS            = /D MDEPKG_NDEBUG
!if $(TOOL_CHAIN_TAG) != "XCODE5" && $(TOOL_CHAIN_TAG) != "CLANGPDB"
  GCC:*_*_*_CC_FLAGS                   = -mno-mmx -mno-sse
!endif
!if $(SOURCE_DEBUG_ENABLE) == TRUE
  MSFT:*_*_X64_GENFW_FLAGS  = --keepexceptiontable
  GCC:*_*_X64_GENFW_FLAGS   = --keepexceptiontable
  INTEL:*_*_X64_GENFW_FLAGS = --keepexceptiontable
!endif
  RELEASE_*_*_GENFW_FLAGS = --zero

  #
  # Disable deprecated APIs.
  #
  MSFT:*_*_*_CC_FLAGS = /D DISABLE_NEW_DEPRECATED_INTERFACES
  INTEL:*_*_*_CC_FLAGS = /D DISABLE_NEW_DEPRECATED_INTERFACES
  GCC:*_*_*_CC_FLAGS = -D DISABLE_NEW_DEPRECATED_INTERFACES

!include NetworkPkg/NetworkBuildOptions.dsc.inc

[BuildOptions.common.EDKII.DXE_RUNTIME_DRIVER, BuildOptions.common.EDKII.DXE_DRIVER, BuildOptions.common.EDKII.UEFI_DRIVER, BuildOptions.common.EDKII.DXE_CORE, BuildOptions.common.EDKII.UEFI_APPLICATION]
  GCC:*_*_*_DLINK_FLAGS = -z common-page-size=0x1000
  XCODE:*_*_*_DLINK_FLAGS = -seg1addr 0x1000 -segalign 0x1000
  XCODE:*_*_*_MTOC_FLAGS = -align 0x1000
  CLANGPDB:*_*_*_DLINK_FLAGS = /ALIGN:4096

# Force PE/COFF sections to be aligned at 4KB boundaries to support page level
# protection of MM/MM_CORE modules
[BuildOptions.common.EDKII.DXE_SMM_DRIVER, BuildOptions.common.EDKII.SMM_CORE, BuildOptions.common.EDKII.MM_CORE_STANDALONE, BuildOptions.common.EDKII.MM_STANDALONE]
  GCC:*_*_*_DLINK_FLAGS = -z common-page-size=0x1000
  XCODE:*_*_*_DLINK_FLAGS = -seg1addr 0x1000 -segalign 0x1000
  XCODE:*_*_*_MTOC_FLAGS = -align 0x1000
  CLANGPDB:*_*_*_DLINK_FLAGS = /ALIGN:4096

################################################################################
#
# SKU Identification section - list of all SKU IDs supported by this Platform.
#
################################################################################
[SkuIds]
  0|DEFAULT

################################################################################
#
# Library Class section - list of all Library Classes needed by this Platform.
#
################################################################################

!include MdePkg/MdeLibs.dsc.inc

[LibraryClasses]
  GptLib|MdeModulePkg/Library/GptLib/GptLib.inf
  SmmRelocationLib|OvmfPkg/Library/SmmRelocationLib/SmmRelocationLib.inf
  PcdLib|MdePkg/Library/BasePcdLibNull/BasePcdLibNull.inf
  TimerLib|DoryPCPkg/Library/DoryTimerLib/DoryTimerLib.inf
  ResetSystemLib|DoryPCPkg/Library/DoryResetSystemLib/DoryResetSystemLib.inf
  PrintLib|MdePkg/Library/BasePrintLib/BasePrintLib.inf
  BaseMemoryLib|MdePkg/Library/BaseMemoryLibRepStr/BaseMemoryLibRepStr.inf
  BaseLib|MdePkg/Library/BaseLib/BaseLib.inf
  SafeIntLib|MdePkg/Library/BaseSafeIntLib/BaseSafeIntLib.inf
  TimeBaseLib|EmbeddedPkg/Library/TimeBaseLib/TimeBaseLib.inf
  BmpSupportLib|MdeModulePkg/Library/BaseBmpSupportLib/BaseBmpSupportLib.inf
  SynchronizationLib|MdePkg/Library/BaseSynchronizationLib/BaseSynchronizationLib.inf
  CpuLib|MdePkg/Library/BaseCpuLib/BaseCpuLib.inf
  PerformanceLib|MdePkg/Library/BasePerformanceLibNull/BasePerformanceLibNull.inf
  PeCoffLib|MdePkg/Library/BasePeCoffLib/BasePeCoffLib.inf
  CacheMaintenanceLib|MdePkg/Library/BaseCacheMaintenanceLib/BaseCacheMaintenanceLib.inf
  UefiDecompressLib|MdePkg/Library/BaseUefiDecompressLib/BaseUefiDecompressLib.inf
  UefiHiiServicesLib|MdeModulePkg/Library/UefiHiiServicesLib/UefiHiiServicesLib.inf
  HiiLib|MdeModulePkg/Library/UefiHiiLib/UefiHiiLib.inf
  SortLib|MdeModulePkg/Library/UefiSortLib/UefiSortLib.inf
  UefiBootManagerLib|MdeModulePkg/Library/UefiBootManagerLib/UefiBootManagerLib.inf
  BootLogoLib|MdeModulePkg/Library/BootLogoLib/BootLogoLib.inf
  FileExplorerLib|MdeModulePkg/Library/FileExplorerLib/FileExplorerLib.inf
  CapsuleLib|MdeModulePkg/Library/DxeCapsuleLibNull/DxeCapsuleLibNull.inf
  DxeServicesLib|MdePkg/Library/DxeServicesLib/DxeServicesLib.inf
  DxeServicesTableLib|MdePkg/Library/DxeServicesTableLib/DxeServicesTableLib.inf
  PeCoffGetEntryPointLib|MdePkg/Library/BasePeCoffGetEntryPointLib/BasePeCoffGetEntryPointLib.inf
  PciCf8Lib|MdePkg/Library/BasePciCf8Lib/BasePciCf8Lib.inf
  PciExpressLib|MdePkg/Library/BasePciExpressLib/BasePciExpressLib.inf
  PciLib|MdePkg/Library/BasePciLibCf8/BasePciLibCf8.inf
  PciSegmentLib|MdePkg/Library/BasePciSegmentLibPci/BasePciSegmentLibPci.inf
  PciCapLib|OvmfPkg/Library/BasePciCapLib/BasePciCapLib.inf
  PciCapPciSegmentLib|OvmfPkg/Library/BasePciCapPciSegmentLib/BasePciCapPciSegmentLib.inf
  PciCapPciIoLib|OvmfPkg/Library/UefiPciCapPciIoLib/UefiPciCapPciIoLib.inf
  IoLib|MdePkg/Library/BaseIoLibIntrinsic/BaseIoLibIntrinsic.inf
  OemHookStatusCodeLib|MdeModulePkg/Library/OemHookStatusCodeLibNull/OemHookStatusCodeLibNull.inf
  SerialPortLib|PcAtChipsetPkg/Library/SerialIoLib/SerialIoLib.inf
  MtrrLib|UefiCpuPkg/Library/MtrrLib/MtrrLib.inf
  MicrocodeLib|UefiCpuPkg/Library/MicrocodeLib/MicrocodeLib.inf
  CpuPageTableLib|UefiCpuPkg/Library/CpuPageTableLib/CpuPageTableLib.inf
  UefiLib|MdePkg/Library/UefiLib/UefiLib.inf
  UefiBootServicesTableLib|MdePkg/Library/UefiBootServicesTableLib/UefiBootServicesTableLib.inf
  UefiRuntimeServicesTableLib|MdePkg/Library/UefiRuntimeServicesTableLib/UefiRuntimeServicesTableLib.inf
  UefiDriverEntryPoint|MdePkg/Library/UefiDriverEntryPoint/UefiDriverEntryPoint.inf
  UefiApplicationEntryPoint|MdePkg/Library/UefiApplicationEntryPoint/UefiApplicationEntryPoint.inf
  DevicePathLib|MdePkg/Library/UefiDevicePathLibDevicePathProtocol/UefiDevicePathLibDevicePathProtocol.inf
  NvVarsFileLib|OvmfPkg/Library/NvVarsFileLib/NvVarsFileLib.inf
  FileHandleLib|MdePkg/Library/UefiFileHandleLib/UefiFileHandleLib.inf
  SecurityManagementLib|MdeModulePkg/Library/DxeSecurityManagementLib/DxeSecurityManagementLib.inf
  UefiUsbLib|MdePkg/Library/UefiUsbLib/UefiUsbLib.inf
  SerializeVariablesLib|OvmfPkg/Library/SerializeVariablesLib/SerializeVariablesLib.inf
  # Upstream consumers retain this library-class name, but Dory never exposes or probes fw_cfg.
  QemuFwCfgLib|OvmfPkg/Library/QemuFwCfgLib/QemuFwCfgLibNull.inf
  QemuFwCfgSimpleParserLib|OvmfPkg/Library/QemuFwCfgSimpleParserLib/QemuFwCfgSimpleParserLib.inf
  VirtioLib|OvmfPkg/Library/VirtioLib/VirtioLib.inf
  LoadLinuxLib|OvmfPkg/Library/LoadLinuxLib/LoadLinuxLib.inf
  MemEncryptSevLib|OvmfPkg/Library/MemEncryptSevLibNull/MemEncryptSevLibNull.inf
  MemEncryptTdxLib|OvmfPkg/Library/BaseMemEncryptTdxLib/BaseMemEncryptTdxLibNull.inf
  PeiHardwareInfoLib|OvmfPkg/Library/HardwareInfoLib/PeiHardwareInfoLib.inf
  DxeHardwareInfoLib|OvmfPkg/Library/HardwareInfoLib/DxeHardwareInfoLib.inf
  ImagePropertiesRecordLib|MdeModulePkg/Library/ImagePropertiesRecordLib/ImagePropertiesRecordLib.inf
  HstiLib|MdePkg/Library/DxeHstiLib/DxeHstiLib.inf

!if $(SMM_REQUIRE) == FALSE
  LockBoxLib|OvmfPkg/Library/LockBoxLib/LockBoxBaseLib.inf
!else
!if $(STANDALONE_MM_ENABLE) == TRUE
  MmPlatformHobProducerLib|OvmfPkg/Library/MmPlatformHobProducerLibOvmf/MmPlatformHobProducerLibOvmf.inf
!endif
!endif
  CcProbeLib|MdePkg/Library/CcProbeLibNull/CcProbeLibNull.inf
  CustomizedDisplayLib|MdeModulePkg/Library/CustomizedDisplayLib/CustomizedDisplayLib.inf
  FrameBufferBltLib|MdeModulePkg/Library/FrameBufferBltLib/FrameBufferBltLib.inf

!if $(SOURCE_DEBUG_ENABLE) == TRUE
  PeCoffExtraActionLib|SourceLevelDebugPkg/Library/PeCoffExtraActionLibDebug/PeCoffExtraActionLibDebug.inf
  DebugCommunicationLib|SourceLevelDebugPkg/Library/DebugCommunicationLibSerialPort/DebugCommunicationLibSerialPort.inf
!else
  PeCoffExtraActionLib|MdePkg/Library/BasePeCoffExtraActionLibNull/BasePeCoffExtraActionLibNull.inf
  DebugAgentLib|MdeModulePkg/Library/DebugAgentLibNull/DebugAgentLibNull.inf
!endif

  LocalApicLib|UefiCpuPkg/Library/BaseXApicX2ApicLib/BaseXApicX2ApicLib.inf
  DebugPrintErrorLevelLib|MdePkg/Library/BaseDebugPrintErrorLevelLib/BaseDebugPrintErrorLevelLib.inf

  RngLib|MdeModulePkg/Library/BaseRngLibTimerLib/BaseRngLibTimerLib.inf

!if $(SECURE_BOOT_ENABLE) == TRUE
  PlatformSecureLib|OvmfPkg/Library/PlatformSecureLib/PlatformSecureLib.inf
  AuthVariableLib|SecurityPkg/Library/AuthVariableLib/AuthVariableLib.inf
  SecureBootVariableLib|SecurityPkg/Library/SecureBootVariableLib/SecureBootVariableLib.inf
  PlatformPKProtectionLib|SecurityPkg/Library/PlatformPKProtectionLibVarPolicy/PlatformPKProtectionLibVarPolicy.inf
  SecureBootVariableProvisionLib|SecurityPkg/Library/SecureBootVariableProvisionLib/SecureBootVariableProvisionLib.inf
!else
  AuthVariableLib|MdeModulePkg/Library/AuthVariableLibNull/AuthVariableLibNull.inf
!endif
  VarCheckLib|MdeModulePkg/Library/VarCheckLib/VarCheckLib.inf
  VariablePolicyLib|MdeModulePkg/Library/VariablePolicyLib/VariablePolicyLib.inf
  VariablePolicyHelperLib|MdeModulePkg/Library/VariablePolicyHelperLib/VariablePolicyHelperLib.inf
  VariableFlashInfoLib|MdeModulePkg/Library/BaseVariableFlashInfoLib/BaseVariableFlashInfoLib.inf

  #
  # Network libraries
  #
!include NetworkPkg/NetworkLibs.dsc.inc

  ShellCEntryLib|ShellPkg/Library/UefiShellCEntryLib/UefiShellCEntryLib.inf

  S3BootScriptLib|MdeModulePkg/Library/PiDxeS3BootScriptLib/DxeS3BootScriptLib.inf
  SmbusLib|MdePkg/Library/BaseSmbusLibNull/BaseSmbusLibNull.inf
  OrderedCollectionLib|MdePkg/Library/BaseOrderedCollectionRedBlackTreeLib/BaseOrderedCollectionRedBlackTreeLib.inf

!include OvmfPkg/Include/Dsc/OvmfTpmLibs.dsc.inc
!include OvmfPkg/Include/Dsc/ShellLibs.dsc.inc
!include OvmfPkg/Include/Dsc/OvmfTlsLibs.dsc.inc

[LibraryClasses.common]
  # PeiMpInitLib consumes AmdSvsmLib unconditionally. Confidential-guest
  # detection and exits remain disabled through the null bindings below.
  AmdSvsmLib|OvmfPkg/Library/AmdSvsmLib/AmdSvsmLib.inf
  BaseCryptLib|CryptoPkg/Library/BaseCryptLib/BaseCryptLib.inf
  CcExitLib|UefiCpuPkg/Library/CcExitLibNull/CcExitLibNull.inf
  TdxLib|MdePkg/Library/TdxLib/TdxLib.inf
  TdxMailboxLib|OvmfPkg/Library/TdxMailboxLib/TdxMailboxLibNull.inf
!if $(DEBUG_TO_MEM)
  MemDebugLogLib|OvmfPkg/Library/MemDebugLogLib/MemDebugLogDxeLib.inf
!else
  MemDebugLogLib|OvmfPkg/Library/MemDebugLogLib/MemDebugLogLibNull.inf
!endif

[LibraryClasses.common.SEC]
  TimerLib|DoryPCPkg/Library/DoryTimerLib/DoryTimerLib.inf
  QemuFwCfgLib|OvmfPkg/Library/QemuFwCfgLib/QemuFwCfgLibNull.inf
!ifdef $(DEBUG_ON_SERIAL_PORT)
  DebugLib|MdePkg/Library/BaseDebugLibSerialPort/BaseDebugLibSerialPort.inf
!else
  DebugLib|OvmfPkg/Library/PlatformDebugLibIoPort/PlatformRomDebugLibIoPort.inf
!endif
!if $(DEBUG_TO_MEM)
  MemDebugLogLib|OvmfPkg/Library/MemDebugLogLib/MemDebugLogSecLib.inf
!endif
  ReportStatusCodeLib|MdeModulePkg/Library/PeiReportStatusCodeLib/PeiReportStatusCodeLib.inf
  ExtractGuidedSectionLib|MdePkg/Library/BaseExtractGuidedSectionLib/BaseExtractGuidedSectionLib.inf
!if $(SOURCE_DEBUG_ENABLE) == TRUE
  DebugAgentLib|SourceLevelDebugPkg/Library/DebugAgent/SecPeiDebugAgentLib.inf
!endif
  HobLib|MdePkg/Library/PeiHobLib/PeiHobLib.inf
  PeiServicesLib|MdePkg/Library/PeiServicesLib/PeiServicesLib.inf
  PeiServicesTablePointerLib|MdePkg/Library/PeiServicesTablePointerLibIdt/PeiServicesTablePointerLibIdt.inf
  MemoryAllocationLib|MdePkg/Library/PeiMemoryAllocationLib/PeiMemoryAllocationLib.inf
  CpuExceptionHandlerLib|UefiCpuPkg/Library/CpuExceptionHandlerLib/SecPeiCpuExceptionHandlerLib.inf
  CcExitLib|UefiCpuPkg/Library/CcExitLibNull/CcExitLibNull.inf
  MemEncryptSevLib|OvmfPkg/Library/MemEncryptSevLibNull/MemEncryptSevLibNull.inf
  CcProbeLib|MdePkg/Library/CcProbeLibNull/CcProbeLibNull.inf
  TdxMeasurementLib|MdeModulePkg/Library/TdxMeasurementLibNull/TdxMeasurementLibNull.inf

[LibraryClasses.common.PEI_CORE]
  HobLib|MdePkg/Library/PeiHobLib/PeiHobLib.inf
  PeiServicesTablePointerLib|MdePkg/Library/PeiServicesTablePointerLibIdt/PeiServicesTablePointerLibIdt.inf
  PeiServicesLib|MdePkg/Library/PeiServicesLib/PeiServicesLib.inf
  MemoryAllocationLib|MdePkg/Library/PeiMemoryAllocationLib/PeiMemoryAllocationLib.inf
  PeiCoreEntryPoint|MdePkg/Library/PeiCoreEntryPoint/PeiCoreEntryPoint.inf
  ReportStatusCodeLib|MdeModulePkg/Library/PeiReportStatusCodeLib/PeiReportStatusCodeLib.inf
  OemHookStatusCodeLib|MdeModulePkg/Library/OemHookStatusCodeLibNull/OemHookStatusCodeLibNull.inf
  PeCoffGetEntryPointLib|MdePkg/Library/BasePeCoffGetEntryPointLib/BasePeCoffGetEntryPointLib.inf
!ifdef $(DEBUG_ON_SERIAL_PORT)
  DebugLib|MdePkg/Library/BaseDebugLibSerialPort/BaseDebugLibSerialPort.inf
!else
  DebugLib|OvmfPkg/Library/PlatformDebugLibIoPort/PlatformRomDebugLibIoPort.inf
!endif
!if $(DEBUG_TO_MEM)
  MemDebugLogLib|OvmfPkg/Library/MemDebugLogLib/MemDebugLogPeiCoreLib.inf
!endif
  PeCoffLib|MdePkg/Library/BasePeCoffLib/BasePeCoffLib.inf
  CcProbeLib|MdePkg/Library/CcProbeLibNull/CcProbeLibNull.inf
  TimerLib|DoryPCPkg/Library/DoryTimerLib/DoryTimerLib.inf

[LibraryClasses.common.PEIM]
  HobLib|MdePkg/Library/PeiHobLib/PeiHobLib.inf
  PeiServicesTablePointerLib|MdePkg/Library/PeiServicesTablePointerLibIdt/PeiServicesTablePointerLibIdt.inf
  PeiServicesLib|MdePkg/Library/PeiServicesLib/PeiServicesLib.inf
  MemoryAllocationLib|MdePkg/Library/PeiMemoryAllocationLib/PeiMemoryAllocationLib.inf
  PeimEntryPoint|MdePkg/Library/PeimEntryPoint/PeimEntryPoint.inf
  ReportStatusCodeLib|MdeModulePkg/Library/PeiReportStatusCodeLib/PeiReportStatusCodeLib.inf
  OemHookStatusCodeLib|MdeModulePkg/Library/OemHookStatusCodeLibNull/OemHookStatusCodeLibNull.inf
  PeCoffGetEntryPointLib|MdePkg/Library/BasePeCoffGetEntryPointLib/BasePeCoffGetEntryPointLib.inf
!ifdef $(DEBUG_ON_SERIAL_PORT)
  DebugLib|MdePkg/Library/BaseDebugLibSerialPort/BaseDebugLibSerialPort.inf
!else
  DebugLib|OvmfPkg/Library/PlatformDebugLibIoPort/PlatformRomDebugLibIoPort.inf
!endif
!if $(DEBUG_TO_MEM)
  MemDebugLogLib|OvmfPkg/Library/MemDebugLogLib/MemDebugLogPeiCoreLib.inf
!endif
  PeCoffLib|MdePkg/Library/BasePeCoffLib/BasePeCoffLib.inf
  ResourcePublicationLib|MdePkg/Library/PeiResourcePublicationLib/PeiResourcePublicationLib.inf
  ExtractGuidedSectionLib|MdePkg/Library/PeiExtractGuidedSectionLib/PeiExtractGuidedSectionLib.inf
!if $(SOURCE_DEBUG_ENABLE) == TRUE
  DebugAgentLib|SourceLevelDebugPkg/Library/DebugAgent/SecPeiDebugAgentLib.inf
!endif
  CpuExceptionHandlerLib|UefiCpuPkg/Library/CpuExceptionHandlerLib/PeiCpuExceptionHandlerLib.inf
  MpInitLib|UefiCpuPkg/Library/MpInitLib/PeiMpInitLib.inf
  QemuFwCfgS3Lib|OvmfPkg/Library/QemuFwCfgS3Lib/BaseQemuFwCfgS3LibNull.inf
  PcdLib|MdePkg/Library/PeiPcdLib/PeiPcdLib.inf
  TimerLib|DoryPCPkg/Library/DoryTimerLib/DoryTimerLib.inf
  QemuFwCfgLib|OvmfPkg/Library/QemuFwCfgLib/QemuFwCfgLibNull.inf
  PlatformInitLib|OvmfPkg/Library/PlatformInitLib/PlatformInitLib.inf

  MemEncryptSevLib|OvmfPkg/Library/MemEncryptSevLibNull/MemEncryptSevLibNull.inf
  CcProbeLib|MdePkg/Library/CcProbeLibNull/CcProbeLibNull.inf
  BaseCryptLib|CryptoPkg/Library/BaseCryptLib/PeiCryptLib.inf
  TdxMeasurementLib|MdeModulePkg/Library/TdxMeasurementLibNull/TdxMeasurementLibNull.inf
  TdxHelperLib|OvmfPkg/IntelTdx/TdxHelperLib/TdxHelperLibNull.inf
!if $(SMM_REQUIRE) == TRUE && $(STANDALONE_MM_ENABLE) == TRUE
  MmUnblockMemoryLib|UefiCpuPkg/Library/MmUnblockMemoryLib/MmUnblockMemoryLib.inf
!endif

[LibraryClasses.common.DXE_CORE]
  HobLib|MdePkg/Library/DxeCoreHobLib/DxeCoreHobLib.inf
  DxeCoreEntryPoint|MdePkg/Library/DxeCoreEntryPoint/DxeCoreEntryPoint.inf
  MemoryAllocationLib|MdeModulePkg/Library/DxeCoreMemoryAllocationLib/DxeCoreMemoryAllocationLib.inf
  ReportStatusCodeLib|MdeModulePkg/Library/DxeReportStatusCodeLib/DxeReportStatusCodeLib.inf
!ifdef $(DEBUG_ON_SERIAL_PORT)
  DebugLib|MdePkg/Library/BaseDebugLibSerialPort/BaseDebugLibSerialPort.inf
!else
  DebugLib|OvmfPkg/Library/PlatformDebugLibIoPort/PlatformDebugLibIoPort.inf
!endif
  ExtractGuidedSectionLib|MdePkg/Library/DxeExtractGuidedSectionLib/DxeExtractGuidedSectionLib.inf
!if $(SOURCE_DEBUG_ENABLE) == TRUE
  DebugAgentLib|SourceLevelDebugPkg/Library/DebugAgent/DxeDebugAgentLib.inf
!endif
  CpuExceptionHandlerLib|UefiCpuPkg/Library/CpuExceptionHandlerLib/DxeCpuExceptionHandlerLib.inf
  PcdLib|MdePkg/Library/DxePcdLib/DxePcdLib.inf

[LibraryClasses.common.DXE_RUNTIME_DRIVER]
  PcdLib|MdePkg/Library/DxePcdLib/DxePcdLib.inf
  TimerLib|DoryPCPkg/Library/DoryTimerLib/DoryTimerLib.inf
  ResetSystemLib|DoryPCPkg/Library/DoryResetSystemLib/DoryResetSystemLib.inf
  HobLib|MdePkg/Library/DxeHobLib/DxeHobLib.inf
  DxeCoreEntryPoint|MdePkg/Library/DxeCoreEntryPoint/DxeCoreEntryPoint.inf
  MemoryAllocationLib|MdePkg/Library/UefiMemoryAllocationLib/UefiMemoryAllocationLib.inf
  ReportStatusCodeLib|MdeModulePkg/Library/RuntimeDxeReportStatusCodeLib/RuntimeDxeReportStatusCodeLib.inf
!ifdef $(DEBUG_ON_SERIAL_PORT)
  DebugLib|MdePkg/Library/BaseDebugLibSerialPort/BaseDebugLibSerialPort.inf
!else
  DebugLib|OvmfPkg/Library/PlatformDebugLibIoPort/PlatformDebugLibIoPort.inf
!endif
!if $(DEBUG_TO_MEM)
  MemDebugLogLib|OvmfPkg/Library/MemDebugLogLib/MemDebugLogRtLib.inf
!endif
  UefiRuntimeLib|MdePkg/Library/UefiRuntimeLib/UefiRuntimeLib.inf
  BaseCryptLib|CryptoPkg/Library/BaseCryptLib/RuntimeCryptLib.inf
  PciLib|MdePkg/Library/BasePciLibPciExpress/BasePciLibPciExpress.inf
  QemuFwCfgS3Lib|OvmfPkg/Library/QemuFwCfgS3Lib/BaseQemuFwCfgS3LibNull.inf
  VariablePolicyLib|MdeModulePkg/Library/VariablePolicyLib/VariablePolicyLibRuntimeDxe.inf
!if $(SMM_REQUIRE) == TRUE || $(QEMU_PV_VARS) == TRUE
  MmUnblockMemoryLib|MdePkg/Library/MmUnblockMemoryLib/MmUnblockMemoryLibNull.inf
!endif

[LibraryClasses.common.UEFI_DRIVER]
  PcdLib|MdePkg/Library/DxePcdLib/DxePcdLib.inf
  TimerLib|DoryPCPkg/Library/DoryTimerLib/DoryTimerLib.inf
  ResetSystemLib|DoryPCPkg/Library/DoryResetSystemLib/DoryResetSystemLib.inf
  HobLib|MdePkg/Library/DxeHobLib/DxeHobLib.inf
  DxeCoreEntryPoint|MdePkg/Library/DxeCoreEntryPoint/DxeCoreEntryPoint.inf
  MemoryAllocationLib|MdePkg/Library/UefiMemoryAllocationLib/UefiMemoryAllocationLib.inf
  ReportStatusCodeLib|MdeModulePkg/Library/DxeReportStatusCodeLib/DxeReportStatusCodeLib.inf
!ifdef $(DEBUG_ON_SERIAL_PORT)
  DebugLib|MdePkg/Library/BaseDebugLibSerialPort/BaseDebugLibSerialPort.inf
!else
  DebugLib|OvmfPkg/Library/PlatformDebugLibIoPort/PlatformDebugLibIoPort.inf
!endif
  UefiScsiLib|MdePkg/Library/UefiScsiLib/UefiScsiLib.inf
  PciLib|MdePkg/Library/BasePciLibPciExpress/BasePciLibPciExpress.inf

[LibraryClasses.common.DXE_DRIVER]
  AcpiPlatformLib|OvmfPkg/Library/AcpiPlatformLib/DxeAcpiPlatformLib.inf
  PcdLib|MdePkg/Library/DxePcdLib/DxePcdLib.inf
  TimerLib|DoryPCPkg/Library/DoryTimerLib/DoryTimerLib.inf
  ResetSystemLib|DoryPCPkg/Library/DoryResetSystemLib/DoryResetSystemLib.inf
  HobLib|MdePkg/Library/DxeHobLib/DxeHobLib.inf
  MemoryAllocationLib|MdePkg/Library/UefiMemoryAllocationLib/UefiMemoryAllocationLib.inf
  ReportStatusCodeLib|MdeModulePkg/Library/DxeReportStatusCodeLib/DxeReportStatusCodeLib.inf
  UefiScsiLib|MdePkg/Library/UefiScsiLib/UefiScsiLib.inf
!ifdef $(DEBUG_ON_SERIAL_PORT)
  DebugLib|MdePkg/Library/BaseDebugLibSerialPort/BaseDebugLibSerialPort.inf
!else
  DebugLib|OvmfPkg/Library/PlatformDebugLibIoPort/PlatformDebugLibIoPort.inf
!endif
  PlatformBootManagerLib|DoryPCPkg/Library/DoryPlatformBootManagerLib/DoryPlatformBootManagerLib.inf
  PlatformBmPrintScLib|OvmfPkg/Library/PlatformBmPrintScLib/PlatformBmPrintScLib.inf
  PlatformBootManagerCommonLib|OvmfPkg/Library/PlatformBootManagerCommonLib/PlatformBootManagerCommonLib.inf
  CpuExceptionHandlerLib|UefiCpuPkg/Library/CpuExceptionHandlerLib/DxeCpuExceptionHandlerLib.inf
!if $(STANDALONE_MM_ENABLE) == TRUE
  LockBoxLib|MdeModulePkg/Library/LockBoxNullLib/LockBoxNullLib.inf
!elseif $(SMM_REQUIRE) == TRUE
  LockBoxLib|MdeModulePkg/Library/SmmLockBoxLib/SmmLockBoxDxeLib.inf
!else
  LockBoxLib|OvmfPkg/Library/LockBoxLib/LockBoxDxeLib.inf
!endif
!if $(SOURCE_DEBUG_ENABLE) == TRUE
  DebugAgentLib|SourceLevelDebugPkg/Library/DebugAgent/DxeDebugAgentLib.inf
!endif
  PciLib|MdePkg/Library/BasePciLibPciExpress/BasePciLibPciExpress.inf
  MpInitLib|UefiCpuPkg/Library/MpInitLib/DxeMpInitLib.inf
  NestedInterruptTplLib|OvmfPkg/Library/NestedInterruptTplLib/NestedInterruptTplLib.inf
  QemuFwCfgS3Lib|OvmfPkg/Library/QemuFwCfgS3Lib/BaseQemuFwCfgS3LibNull.inf
  TdxMeasurementLib|MdeModulePkg/Library/TdxMeasurementLibNull/TdxMeasurementLibNull.inf

[LibraryClasses.common.UEFI_APPLICATION]
  PcdLib|MdePkg/Library/DxePcdLib/DxePcdLib.inf
  TimerLib|DoryPCPkg/Library/DoryTimerLib/DoryTimerLib.inf
  ResetSystemLib|DoryPCPkg/Library/DoryResetSystemLib/DoryResetSystemLib.inf
  HobLib|MdePkg/Library/DxeHobLib/DxeHobLib.inf
  MemoryAllocationLib|MdePkg/Library/UefiMemoryAllocationLib/UefiMemoryAllocationLib.inf
  ReportStatusCodeLib|MdeModulePkg/Library/DxeReportStatusCodeLib/DxeReportStatusCodeLib.inf
!ifdef $(DEBUG_ON_SERIAL_PORT)
  DebugLib|MdePkg/Library/BaseDebugLibSerialPort/BaseDebugLibSerialPort.inf
!else
  DebugLib|OvmfPkg/Library/PlatformDebugLibIoPort/PlatformDebugLibIoPort.inf
!endif
  PciLib|MdePkg/Library/BasePciLibPciExpress/BasePciLibPciExpress.inf

[LibraryClasses.common.DXE_SMM_DRIVER]
  PcdLib|MdePkg/Library/DxePcdLib/DxePcdLib.inf
  TimerLib|DoryPCPkg/Library/DoryTimerLib/DoryTimerLib.inf
  ResetSystemLib|DoryPCPkg/Library/DoryResetSystemLib/DoryResetSystemLib.inf
  MemoryAllocationLib|MdePkg/Library/SmmMemoryAllocationLib/SmmMemoryAllocationLib.inf
  ReportStatusCodeLib|MdeModulePkg/Library/DxeReportStatusCodeLib/DxeReportStatusCodeLib.inf
  HobLib|MdePkg/Library/DxeHobLib/DxeHobLib.inf
  SmmMemLib|MdePkg/Library/SmmMemLib/SmmMemLib.inf
  MmServicesTableLib|MdePkg/Library/MmServicesTableLib/MmServicesTableLib.inf
  SmmServicesTableLib|MdePkg/Library/SmmServicesTableLib/SmmServicesTableLib.inf
!ifdef $(DEBUG_ON_SERIAL_PORT)
  DebugLib|MdePkg/Library/BaseDebugLibSerialPort/BaseDebugLibSerialPort.inf
!else
  DebugLib|OvmfPkg/Library/PlatformDebugLibIoPort/PlatformDebugLibIoPort.inf
!endif
  CpuExceptionHandlerLib|UefiCpuPkg/Library/CpuExceptionHandlerLib/SmmCpuExceptionHandlerLib.inf
!if $(SOURCE_DEBUG_ENABLE) == TRUE
  DebugAgentLib|SourceLevelDebugPkg/Library/DebugAgent/SmmDebugAgentLib.inf
!endif
  BaseCryptLib|CryptoPkg/Library/BaseCryptLib/SmmCryptLib.inf
  PciLib|MdePkg/Library/BasePciLibPciExpress/BasePciLibPciExpress.inf
  SmmCpuRendezvousLib|UefiCpuPkg/Library/SmmCpuRendezvousLib/SmmCpuRendezvousLib.inf

[LibraryClasses.common.SMM_CORE]
  PcdLib|MdePkg/Library/DxePcdLib/DxePcdLib.inf
  TimerLib|DoryPCPkg/Library/DoryTimerLib/DoryTimerLib.inf
  ResetSystemLib|DoryPCPkg/Library/DoryResetSystemLib/DoryResetSystemLib.inf
  SmmCorePlatformHookLib|MdeModulePkg/Library/SmmCorePlatformHookLibNull/SmmCorePlatformHookLibNull.inf
  MemoryAllocationLib|MdeModulePkg/Library/PiSmmCoreMemoryAllocationLib/PiSmmCoreMemoryAllocationLib.inf
  ReportStatusCodeLib|MdeModulePkg/Library/DxeReportStatusCodeLib/DxeReportStatusCodeLib.inf
  HobLib|MdePkg/Library/DxeHobLib/DxeHobLib.inf
  SmmMemLib|MdePkg/Library/SmmMemLib/SmmMemLib.inf
  SmmServicesTableLib|MdeModulePkg/Library/PiSmmCoreSmmServicesTableLib/PiSmmCoreSmmServicesTableLib.inf
!ifdef $(DEBUG_ON_SERIAL_PORT)
  DebugLib|MdePkg/Library/BaseDebugLibSerialPort/BaseDebugLibSerialPort.inf
!else
  DebugLib|OvmfPkg/Library/PlatformDebugLibIoPort/PlatformDebugLibIoPort.inf
!endif
  PciLib|MdePkg/Library/BasePciLibPciExpress/BasePciLibPciExpress.inf

[LibraryClasses.common.MM_STANDALONE]
!ifdef $(DEBUG_ON_SERIAL_PORT)
  DebugLib|MdePkg/Library/BaseDebugLibSerialPort/BaseDebugLibSerialPort.inf
!else
  DebugLib|OvmfPkg/Library/PlatformDebugLibIoPort/PlatformDebugLibIoPort.inf
!endif
  StandaloneMmDriverEntryPoint|MdePkg/Library/DynamicStackCookieEntryPointLib/StandaloneMmDriverEntryPoint.inf
  TimerLib|DoryPCPkg/Library/DoryTimerLib/DoryTimerLib.inf
  MemoryAllocationLib|StandaloneMmPkg/Library/StandaloneMmMemoryAllocationLib/StandaloneMmMemoryAllocationLib.inf
  MmServicesTableLib|MdePkg/Library/StandaloneMmServicesTableLib/StandaloneMmServicesTableLib.inf
  HobLib|StandaloneMmPkg/Library/StandaloneMmHobLib/StandaloneMmHobLib.inf
  CpuExceptionHandlerLib|UefiCpuPkg/Library/CpuExceptionHandlerLib/SmmCpuExceptionHandlerLib.inf
  ReportStatusCodeLib|MdeModulePkg/Library/SmmReportStatusCodeLib/StandaloneMmReportStatusCodeLib.inf
  CcExitLib|UefiCpuPkg/Library/CcExitLibNull/CcExitLibNull.inf
  MemLib|StandaloneMmPkg/Library/StandaloneMmMemLib/StandaloneMmMemLib.inf
  DevicePathLib|MdePkg/Library/UefiDevicePathLib/UefiDevicePathLibBase.inf
  BaseCryptLib|CryptoPkg/Library/BaseCryptLib/SmmCryptLib.inf

[LibraryClasses.common.MM_CORE_STANDALONE]
!ifdef $(DEBUG_ON_SERIAL_PORT)
  DebugLib|MdePkg/Library/BaseDebugLibSerialPort/BaseDebugLibSerialPort.inf
!else
  DebugLib|OvmfPkg/Library/PlatformDebugLibIoPort/PlatformDebugLibIoPort.inf
!endif
  ExtractGuidedSectionLib|StandaloneMmPkg/Library/StandaloneMmExtractGuidedSectionLib/StandaloneMmExtractGuidedSectionLib.inf
  HobLib|StandaloneMmPkg/Library/StandaloneMmCoreHobLib/StandaloneMmCoreHobLib.inf
  MemoryAllocationLib|StandaloneMmPkg/Library/StandaloneMmCoreMemoryAllocationLib/StandaloneMmCoreMemoryAllocationLib.inf
  MemLib|StandaloneMmPkg/Library/StandaloneMmMemLib/StandaloneMmMemLib.inf
  ReportStatusCodeLib|MdeModulePkg/Library/SmmReportStatusCodeLib/StandaloneMmReportStatusCodeLib.inf
  StandaloneMmCoreEntryPoint|MdePkg/Library/DynamicStackCookieEntryPointLib/StandaloneMmCoreEntryPoint.inf
  HobPrintLib|MdeModulePkg/Library/HobPrintLib/HobPrintLib.inf
  MmServicesTableLib|MdePkg/Library/StandaloneMmServicesTableLib/StandaloneMmServicesTableLib.inf

################################################################################
#
# Pcd Section - list of all EDK II PCD Entries defined by this Platform.
#
################################################################################
[PcdsFeatureFlag]
  gEfiMdeModulePkgTokenSpaceGuid.PcdHiiOsRuntimeSupport|FALSE
  gEfiMdeModulePkgTokenSpaceGuid.PcdDxeIplSupportUefiDecompress|FALSE
  gEfiMdeModulePkgTokenSpaceGuid.PcdDxeIplSwitchToLongMode|FALSE
  gEfiMdeModulePkgTokenSpaceGuid.PcdConOutGopSupport|TRUE
  gEfiMdeModulePkgTokenSpaceGuid.PcdInstallAcpiSdtProtocol|TRUE
!if $(SMM_REQUIRE) == TRUE
  gUefiOvmfPkgTokenSpaceGuid.PcdSmmSmramRequire|TRUE
  gUefiCpuPkgTokenSpaceGuid.PcdCpuHotPlugSupport|TRUE
  gEfiMdeModulePkgTokenSpaceGuid.PcdEnableVariableRuntimeCache|FALSE
  gUefiOvmfPkgTokenSpaceGuid.PcdStandaloneMmEnable|$(STANDALONE_MM_ENABLE)
!endif
!if $(QEMU_PV_VARS) == TRUE
  gUefiOvmfPkgTokenSpaceGuid.PcdQemuVarsRequire|TRUE
  gEfiMdeModulePkgTokenSpaceGuid.PcdEnableVariableRuntimeCache|FALSE
!endif
!if $(SECURE_BOOT_ENABLE) == TRUE
  gUefiOvmfPkgTokenSpaceGuid.PcdSecureBootSupported|TRUE
  gEfiMdeModulePkgTokenSpaceGuid.PcdRequireSelfSignedPk|FALSE
!endif
  gEfiMdeModulePkgTokenSpaceGuid.PcdPeiMemoryBinsEnable|TRUE

[PcdsFixedAtBuild]
  gEfiMdeModulePkgTokenSpaceGuid.PcdStatusCodeMemorySize|1
!if $(SMM_REQUIRE) == FALSE
  gEfiMdeModulePkgTokenSpaceGuid.PcdResetOnMemoryTypeInformationChange|FALSE
!endif
  gEfiMdePkgTokenSpaceGuid.PcdMaximumGuidedExtractHandler|0x10
  gEfiMdePkgTokenSpaceGuid.PcdMaximumLinkedListLength|0
!if ($(FD_SIZE_IN_KB) == 1024) || ($(FD_SIZE_IN_KB) == 2048)
  gEfiMdeModulePkgTokenSpaceGuid.PcdMaxVariableSize|0x2000
  gEfiMdeModulePkgTokenSpaceGuid.PcdMaxAuthVariableSize|0x2800
!if $(NETWORK_TLS_ENABLE) == FALSE
  # match PcdFlashNvStorageVariableSize purely for convenience
  gEfiMdeModulePkgTokenSpaceGuid.PcdVariableStoreSize|0xe000
!endif
!endif
!if $(FD_SIZE_IN_KB) == 4096
  gEfiMdeModulePkgTokenSpaceGuid.PcdMaxVariableSize|0x8400
  gEfiMdeModulePkgTokenSpaceGuid.PcdMaxAuthVariableSize|0x8400
!if $(NETWORK_TLS_ENABLE) == FALSE
  # match PcdFlashNvStorageVariableSize purely for convenience
  gEfiMdeModulePkgTokenSpaceGuid.PcdVariableStoreSize|0x40000
!endif
!endif
!if $(NETWORK_TLS_ENABLE) == TRUE
  gEfiMdeModulePkgTokenSpaceGuid.PcdVariableStoreSize|0x80000
  gEfiMdeModulePkgTokenSpaceGuid.PcdMaxVolatileVariableSize|0x40000
!endif

  gEfiMdeModulePkgTokenSpaceGuid.PcdVpdBaseAddress|0x0
  gEfiMdeModulePkgTokenSpaceGuid.PcdStatusCodeUseSerial|FALSE
  gEfiMdeModulePkgTokenSpaceGuid.PcdStatusCodeUseMemory|TRUE

  gEfiMdePkgTokenSpaceGuid.PcdReportStatusCodePropertyMask|0x07

  # DEBUG_INIT      0x00000001  // Initialization
  # DEBUG_WARN      0x00000002  // Warnings
  # DEBUG_LOAD      0x00000004  // Load events
  # DEBUG_FS        0x00000008  // EFI File system
  # DEBUG_POOL      0x00000010  // Alloc & Free (pool)
  # DEBUG_PAGE      0x00000020  // Alloc & Free (page)
  # DEBUG_INFO      0x00000040  // Informational debug messages
  # DEBUG_DISPATCH  0x00000080  // PEI/DXE/SMM Dispatchers
  # DEBUG_VARIABLE  0x00000100  // Variable
  # DEBUG_BM        0x00000400  // Boot Manager
  # DEBUG_BLKIO     0x00001000  // BlkIo Driver
  # DEBUG_NET       0x00004000  // SNP Driver
  # DEBUG_UNDI      0x00010000  // UNDI Driver
  # DEBUG_LOADFILE  0x00020000  // LoadFile
  # DEBUG_EVENT     0x00080000  // Event messages
  # DEBUG_GCD       0x00100000  // Global Coherency Database changes
  # DEBUG_CACHE     0x00200000  // Memory range cachability changes
  # DEBUG_VERBOSE   0x00400000  // Detailed debug messages that may
  #                             // significantly impact boot performance
  # DEBUG_ERROR     0x80000000  // Error
  gEfiMdePkgTokenSpaceGuid.PcdDebugPrintErrorLevel|0x8000004F

!if $(SOURCE_DEBUG_ENABLE) == TRUE
  gEfiMdePkgTokenSpaceGuid.PcdDebugPropertyMask|0x17
!else
  gEfiMdePkgTokenSpaceGuid.PcdDebugPropertyMask|0x2F
!endif

  # This PCD is used to set the base address of the PCI express hierarchy. It
  # is only consulted when OVMF runs on Q35. In that case it is programmed into
  # the PCIEXBAR register.
  #
  # On Q35 machine types that QEMU intends to support in the long term, QEMU
  # never lets the RAM below 4 GB exceed 2816 MB.
  gEfiMdePkgTokenSpaceGuid.PcdPciExpressBaseAddress|0xE0000000

!if $(SOURCE_DEBUG_ENABLE) == TRUE
  gEfiSourceLevelDebugPkgTokenSpaceGuid.PcdDebugLoadImageMethod|0x2
!endif

  #
  # The NumberOfPages values below are ad-hoc. They are updated sporadically at
  # best (please refer to git-blame for past updates). The values capture a set
  # of BIN hints that made sense at a particular time, for some (now likely
  # unknown) workloads / boot paths.
  #
  gEmbeddedTokenSpaceGuid.PcdMemoryTypeEfiACPIMemoryNVS|0x80
  gEmbeddedTokenSpaceGuid.PcdMemoryTypeEfiACPIReclaimMemory|0x12
  gEmbeddedTokenSpaceGuid.PcdMemoryTypeEfiReservedMemoryType|0x80
  gEmbeddedTokenSpaceGuid.PcdMemoryTypeEfiRuntimeServicesCode|0x100
  gEmbeddedTokenSpaceGuid.PcdMemoryTypeEfiRuntimeServicesData|0x100

  #
  # Keep firmware page tables inside the frozen compatible-v1 CPU profile.
  gEfiMdeModulePkgTokenSpaceGuid.PcdUse1GPageTable|FALSE

  #
  # Network Pcds
  #
!include NetworkPkg/NetworkFixedPcds.dsc.inc

!if $(SMM_REQUIRE) == TRUE
  gUefiCpuPkgTokenSpaceGuid.PcdCpuSmmStackSize|0x4000
!endif

  # Point to the MdeModulePkg/Application/BootManagerMenuApp/BootManagerMenuApp.inf
  gEfiMdeModulePkgTokenSpaceGuid.PcdBootManagerMenuFile|{ 0xdc, 0x5b, 0xc2, 0xee, 0xf2, 0x67, 0x95, 0x4d, 0xb1, 0xd5, 0xf8, 0x1b, 0x20, 0x39, 0xd1, 0x1d }
  #
  # INIT is now triggered before BIOS by ucode/hardware. In the OVMF
  # environment, QEMU lacks a simulation for the INIT process.
  # To address this, PcdFirstTimeWakeUpAPsBySipi set to FALSE to
  # broadcast INIT-SIPI-SIPI for the first time.
  #
  gUefiCpuPkgTokenSpaceGuid.PcdFirstTimeWakeUpAPsBySipi|FALSE

  gEfiMdePkgTokenSpaceGuid.PcdFSBClock|1000000000

################################################################################
#
# Pcd Dynamic Section - list of all EDK II PCD Entries defined by this Platform
#
################################################################################

[PcdsDynamicDefault]
  # only set when
  #   ($(SMM_REQUIRE) == FALSE)
  gEfiMdeModulePkgTokenSpaceGuid.PcdEmuVariableNvStoreReserved|0

!if $(SMM_REQUIRE) == FALSE
  gEfiMdeModulePkgTokenSpaceGuid.PcdFlashNvStorageVariableBase64|0
  gEfiMdeModulePkgTokenSpaceGuid.PcdFlashNvStorageFtwWorkingBase64|0
  gEfiMdeModulePkgTokenSpaceGuid.PcdFlashNvStorageFtwSpareBase64|0
  gEfiMdeModulePkgTokenSpaceGuid.PcdFlashNvStorageFtwWorkingBase|0
  gEfiMdeModulePkgTokenSpaceGuid.PcdFlashNvStorageFtwSpareBase|0
!endif
  gEfiMdeModulePkgTokenSpaceGuid.PcdAcpiS3Enable|FALSE
  gUefiOvmfPkgTokenSpaceGuid.PcdOvmfHostBridgePciDevId|0
  gUefiOvmfPkgTokenSpaceGuid.PcdPciIoBase|0x0
  gUefiOvmfPkgTokenSpaceGuid.PcdPciIoSize|0x0
  gUefiOvmfPkgTokenSpaceGuid.PcdPciMmio32Base|0x0
  gUefiOvmfPkgTokenSpaceGuid.PcdPciMmio32Size|0x0
  gUefiOvmfPkgTokenSpaceGuid.PcdPciMmio64Base|0x0
  gUefiOvmfPkgTokenSpaceGuid.PcdPciMmio64Size|0x800000000

  gEfiMdePkgTokenSpaceGuid.PcdPlatformBootTimeOut|0

  # Set video resolution for text setup.
  gEfiMdeModulePkgTokenSpaceGuid.PcdSetupVideoHorizontalResolution|640
  gEfiMdeModulePkgTokenSpaceGuid.PcdSetupVideoVerticalResolution|480

  gEfiMdeModulePkgTokenSpaceGuid.PcdSmbiosVersion|0x0208
  gEfiMdeModulePkgTokenSpaceGuid.PcdSmbiosDocRev|0x0
  gUefiOvmfPkgTokenSpaceGuid.PcdQemuSmbiosValidated|FALSE

  # Noexec settings for DXE.
  gEfiMdeModulePkgTokenSpaceGuid.PcdSetNxForStack|FALSE

  # UefiCpuPkg PCDs related to initial AP bringup and general AP management.
  gUefiCpuPkgTokenSpaceGuid.PcdCpuMaxLogicalProcessorNumber|64
  gUefiCpuPkgTokenSpaceGuid.PcdCpuBootLogicalProcessorNumber|0

  # Set memory encryption mask
  gEfiMdeModulePkgTokenSpaceGuid.PcdPteMemoryEncryptionAddressOrMask|0x0

  # Set Tdx shared bit mask
  gEfiMdeModulePkgTokenSpaceGuid.PcdTdxSharedBitMask|0x0

  # Set SEV-ES defaults
  gEfiMdeModulePkgTokenSpaceGuid.PcdGhcbBase|0
  gEfiMdeModulePkgTokenSpaceGuid.PcdGhcbSize|0
  gUefiCpuPkgTokenSpaceGuid.PcdSevEsIsEnabled|0

!if $(SMM_REQUIRE) == TRUE
  gUefiOvmfPkgTokenSpaceGuid.PcdQ35TsegMbytes|8
  gUefiOvmfPkgTokenSpaceGuid.PcdQ35SmramAtDefaultSmbase|FALSE
  gUefiCpuPkgTokenSpaceGuid.PcdCpuSmmSyncMode|0x01
  gUefiCpuPkgTokenSpaceGuid.PcdCpuSmmApSyncTimeout|100000
  gUefiCpuPkgTokenSpaceGuid.PcdCpuSmmApSyncTimeout2|100000
!endif

  gEfiSecurityPkgTokenSpaceGuid.PcdOptionRomImageVerificationPolicy|0x00

!include OvmfPkg/Include/Dsc/OvmfTpmPcds.dsc.inc
!include OvmfPkg/Include/Dsc/OvmfDisplayPcds.dsc.inc

!include NetworkPkg/NetworkDynamicPcds.dsc.inc

  # Set ConfidentialComputing defaults
  gEfiMdePkgTokenSpaceGuid.PcdConfidentialComputingGuestAttr|0

[PcdsDynamicHii]
!include OvmfPkg/Include/Dsc/OvmfTpmPcdsHii.dsc.inc

################################################################################
#
# Components Section - list of all EDK II Modules needed by this Platform.
#
################################################################################
[Components]
  OvmfPkg/ResetVector/ResetVector.inf

  #
  # SEC Phase modules
  #
  OvmfPkg/Sec/SecMain.inf {
    <LibraryClasses>
      NULL|MdeModulePkg/Library/LzmaCustomDecompressLib/LzmaCustomDecompressLib.inf
      BaseCryptLib|CryptoPkg/Library/BaseCryptLib/SecCryptLib.inf
  }

  #
  # PEI Phase modules
  #
  MdeModulePkg/Core/Pei/PeiMain.inf
!if $(DEBUG_TO_MEM)
  OvmfPkg/MemDebugLogPei/MemDebugLogPei.inf {
    <LibraryClasses>
      MemDebugLogLib|OvmfPkg/Library/MemDebugLogLib/MemDebugLogPeiLib.inf
  }
!endif
  MdeModulePkg/Universal/PCD/Pei/Pcd.inf  {
    <LibraryClasses>
      PcdLib|MdePkg/Library/BasePcdLibNull/BasePcdLibNull.inf
  }
  MdeModulePkg/Universal/ReportStatusCodeRouter/Pei/ReportStatusCodeRouterPei.inf {
    <LibraryClasses>
      PcdLib|MdePkg/Library/BasePcdLibNull/BasePcdLibNull.inf
  }
  MdeModulePkg/Universal/StatusCodeHandler/Pei/StatusCodeHandlerPei.inf {
    <LibraryClasses>
      PcdLib|MdePkg/Library/BasePcdLibNull/BasePcdLibNull.inf
  }
  MdeModulePkg/Core/DxeIplPeim/DxeIpl.inf

  DoryPCPkg/DoryPlatformPei/DoryPlatformPei.inf

  UefiCpuPkg/Universal/Acpi/S3Resume2Pei/S3Resume2Pei.inf {
    <LibraryClasses>
!if $(SMM_REQUIRE) == TRUE
      LockBoxLib|MdeModulePkg/Library/SmmLockBoxLib/SmmLockBoxPeiLib.inf
!endif
  }
!if $(SMM_REQUIRE) == TRUE
  MdeModulePkg/Universal/FaultTolerantWritePei/FaultTolerantWritePei.inf
  MdeModulePkg/Universal/Variable/Pei/VariablePei.inf
  OvmfPkg/SmmAccess/SmmAccessPei.inf
!endif

  UefiCpuPkg/CpuMpPei/CpuMpPei.inf {
    <LibraryClasses>
      #
      # Directly use PeiMpInitLib. It depends on PeiMpInitLibMpDepLib which
      # checks the PPI of gEfiPeiMpInitLibMpDepPpiGuid.
      #
      MpInitLib|UefiCpuPkg/Library/MpInitLib/PeiMpInitLib.inf
      NULL|OvmfPkg/Library/MpInitLibDepLib/PeiMpInitLibMpDepLib.inf
  }

  UefiCpuPkg/CpuMpPei/CpuMpPei.inf {
    <Defines>
      FILE_GUID = $(UP_CPU_PEI_GUID)

    <LibraryClasses>
      #
      # Directly use MpInitLibUp. It depends on PeiMpInitLibUpDepLib which
      # checks the PPI of gEfiPeiMpInitLibUpDepPpiGuid.
      #
      MpInitLib|UefiCpuPkg/Library/MpInitLibUp/MpInitLibUp.inf
      NULL|OvmfPkg/Library/MpInitLibDepLib/PeiMpInitLibUpDepLib.inf
  }

  #
  # Cc Measurement PPI for Td guest
  #
!if $(CC_MEASUREMENT_ENABLE) == TRUE
  OvmfPkg/Tcg/TdTcg2Pei/TdTcg2Pei.inf
!endif

!include OvmfPkg/Include/Dsc/OvmfTpmComponentsPei.dsc.inc

  #
  # DXE Phase modules
  #
  MdeModulePkg/Core/Dxe/DxeMain.inf {
    <LibraryClasses>
      NULL|MdeModulePkg/Library/LzmaCustomDecompressLib/LzmaCustomDecompressLib.inf
      DevicePathLib|MdePkg/Library/UefiDevicePathLib/UefiDevicePathLib.inf
  }

  MdeModulePkg/Universal/ReportStatusCodeRouter/RuntimeDxe/ReportStatusCodeRouterRuntimeDxe.inf
  MdeModulePkg/Universal/StatusCodeHandler/RuntimeDxe/StatusCodeHandlerRuntimeDxe.inf
  MdeModulePkg/Universal/PCD/Dxe/Pcd.inf  {
   <LibraryClasses>
      PcdLib|MdePkg/Library/BasePcdLibNull/BasePcdLibNull.inf
      MemDebugLogLib|OvmfPkg/Library/MemDebugLogLib/MemDebugLogLibNull.inf
  }

  MdeModulePkg/Core/RuntimeDxe/RuntimeDxe.inf

  MdeModulePkg/Universal/SecurityStubDxe/SecurityStubDxe.inf {
    <LibraryClasses>
!if $(SECURE_BOOT_ENABLE) == TRUE
      NULL|SecurityPkg/Library/DxeImageVerificationLib/DxeImageVerificationLib.inf
!endif
!include OvmfPkg/Include/Dsc/OvmfTpmSecurityStub.dsc.inc
  }

  MdeModulePkg/Universal/EbcDxe/EbcDxe.inf
  UefiCpuPkg/CpuIo2Dxe/CpuIo2Dxe.inf

  UefiCpuPkg/CpuDxe/CpuDxe.inf {
    <LibraryClasses>
      #
      # Directly use DxeMpInitLib. It depends on DxeMpInitLibMpDepLib which
      # checks the Protocol of gEfiMpInitLibMpDepProtocolGuid.
      #
      MpInitLib|UefiCpuPkg/Library/MpInitLib/DxeMpInitLib.inf
      NULL|OvmfPkg/Library/MpInitLibDepLib/DxeMpInitLibMpDepLib.inf
  }

  UefiCpuPkg/CpuDxe/CpuDxe.inf {
    <Defines>
      FILE_GUID = $(UP_CPU_DXE_GUID)

    <LibraryClasses>
      #
      # Directly use MpInitLibUp. It depends on DxeMpInitLibUpDepLib which
      # checks the Protocol of gEfiMpInitLibUpDepProtocolGuid.
      #
      MpInitLib|UefiCpuPkg/Library/MpInitLibUp/MpInitLibUp.inf
      NULL|OvmfPkg/Library/MpInitLibDepLib/DxeMpInitLibUpDepLib.inf
  }

  OvmfPkg/LocalApicTimerDxe/LocalApicTimerDxe.inf
  MdeModulePkg/Bus/Pci/PciHostBridgeDxe/PciHostBridgeDxe.inf {
    <LibraryClasses>
      PciHostBridgeLib|DoryPCPkg/Library/DoryPciHostBridgeLib/DoryPciHostBridgeLib.inf
      PciHostBridgeUtilityLib|OvmfPkg/Library/PciHostBridgeUtilityLib/PciHostBridgeUtilityLib.inf
      NULL|OvmfPkg/Library/PlatformHasIoMmuLib/PlatformHasIoMmuLib.inf
  }
  MdeModulePkg/Bus/Pci/PciBusDxe/PciBusDxe.inf {
    <LibraryClasses>
      PcdLib|MdePkg/Library/DxePcdLib/DxePcdLib.inf
  }
  MdeModulePkg/Universal/ResetSystemRuntimeDxe/ResetSystemRuntimeDxe.inf
  MdeModulePkg/Universal/Metronome/Metronome.inf
  PcAtChipsetPkg/PcatRealTimeClockRuntimeDxe/PcatRealTimeClockRuntimeDxe.inf
  MdeModulePkg/Universal/DriverHealthManagerDxe/DriverHealthManagerDxe.inf
  MdeModulePkg/Universal/BdsDxe/BdsDxe.inf {
    <LibraryClasses>
      XenPlatformLib|OvmfPkg/Library/XenPlatformLib/XenPlatformLib.inf
  }
  MdeModulePkg/Logo/LogoDxe.inf
  MdeModulePkg/Application/UiApp/UiApp.inf {
    <LibraryClasses>
      NULL|MdeModulePkg/Library/DeviceManagerUiLib/DeviceManagerUiLib.inf
      NULL|MdeModulePkg/Library/BootManagerUiLib/BootManagerUiLib.inf
      NULL|MdeModulePkg/Library/BootMaintenanceManagerUiLib/BootMaintenanceManagerUiLib.inf
  }
  MdeModulePkg/Application/BootManagerMenuApp/BootManagerMenuApp.inf
  OvmfPkg/VirtioPciDeviceDxe/VirtioPciDeviceDxe.inf
  OvmfPkg/Virtio10Dxe/Virtio10.inf
  OvmfPkg/VirtioBlkDxe/VirtioBlk.inf
  OvmfPkg/VirtioScsiDxe/VirtioScsi.inf
  OvmfPkg/VirtioSerialDxe/VirtioSerial.inf
  OvmfPkg/VirtioInputDxe/VirtioInput.inf
  MdeModulePkg/Universal/WatchdogTimerDxe/WatchdogTimer.inf
  MdeModulePkg/Universal/MonotonicCounterRuntimeDxe/MonotonicCounterRuntimeDxe.inf
  MdeModulePkg/Universal/CapsuleRuntimeDxe/CapsuleRuntimeDxe.inf
  MdeModulePkg/Universal/Console/ConPlatformDxe/ConPlatformDxe.inf
  MdeModulePkg/Universal/Console/ConSplitterDxe/ConSplitterDxe.inf
  MdeModulePkg/Universal/Console/GraphicsConsoleDxe/GraphicsConsoleDxe.inf {
    <LibraryClasses>
      PcdLib|MdePkg/Library/DxePcdLib/DxePcdLib.inf
  }
  MdeModulePkg/Universal/Console/TerminalDxe/TerminalDxe.inf
  MdeModulePkg/Universal/DevicePathDxe/DevicePathDxe.inf {
    <LibraryClasses>
      DevicePathLib|MdePkg/Library/UefiDevicePathLib/UefiDevicePathLib.inf
      PcdLib|MdePkg/Library/BasePcdLibNull/BasePcdLibNull.inf
!if $(DEBUG_TO_MEM)
      MemDebugLogLib|OvmfPkg/Library/MemDebugLogLib/MemDebugLogLibNull.inf
!endif
  }
  MdeModulePkg/Universal/Disk/DiskIoDxe/DiskIoDxe.inf
  MdeModulePkg/Universal/Disk/PartitionDxe/PartitionDxe.inf
  MdeModulePkg/Universal/Disk/RamDiskDxe/RamDiskDxe.inf
  MdeModulePkg/Universal/Disk/UnicodeCollation/EnglishDxe/EnglishDxe.inf
  FatPkg/EnhancedFatDxe/Fat.inf
  MdeModulePkg/Universal/Disk/UdfDxe/UdfDxe.inf
  OvmfPkg/VirtioFsDxe/VirtioFsDxe.inf
  MdeModulePkg/Bus/Scsi/ScsiBusDxe/ScsiBusDxe.inf
  MdeModulePkg/Bus/Scsi/ScsiDiskDxe/ScsiDiskDxe.inf
  MdeModulePkg/Bus/Pci/SataControllerDxe/SataControllerDxe.inf
  MdeModulePkg/Bus/Ata/AtaAtapiPassThru/AtaAtapiPassThru.inf
  MdeModulePkg/Bus/Ata/AtaBusDxe/AtaBusDxe.inf
  MdeModulePkg/Bus/Pci/NvmExpressDxe/NvmExpressDxe.inf
  MdeModulePkg/Bus/Pci/CxlDxe/CxlDxe.inf
  MdeModulePkg/Universal/HiiDatabaseDxe/HiiDatabaseDxe.inf
  MdeModulePkg/Universal/SetupBrowserDxe/SetupBrowserDxe.inf
  MdeModulePkg/Universal/DisplayEngineDxe/DisplayEngineDxe.inf
  MdeModulePkg/Universal/Acpi/S3SaveStateDxe/S3SaveStateDxe.inf

  OvmfPkg/VirtioGpuDxe/VirtioGpu.inf
  OvmfPkg/VirtHstiDxe/VirtHstiDxe.inf

  #
  # ISA Support
  #
  #
  # SMBIOS Support
  #

  #
  # ACPI Support
  #
!if $(STANDALONE_MM_ENABLE) != TRUE
  MdeModulePkg/Universal/Acpi/BootScriptExecutorDxe/BootScriptExecutorDxe.inf
!endif
  MdeModulePkg/Universal/Acpi/BootGraphicsResourceTableDxe/BootGraphicsResourceTableDxe.inf
  OvmfPkg/WsmtDxe/WsmtDxe.inf

  #
  # Hash2 Protocol producer
  #
!if $(NETWORK_ENABLE) == TRUE
  SecurityPkg/Hash2DxeCrypto/Hash2DxeCrypto.inf
!endif

  #
  # Network Support
  #
!include NetworkPkg/NetworkComponents.dsc.inc
!include OvmfPkg/Include/Dsc/NetworkComponents.dsc.inc
!include OvmfPkg/Include/Dsc/UsbComponents.dsc.inc
!include OvmfPkg/Include/Dsc/ShellComponents.dsc.inc
!include OvmfPkg/Include/Dsc/MorLock.dsc.inc
!include OvmfPkg/Include/Dsc/OvmfRngComponents.dsc.inc
!include OvmfPkg/Include/Dsc/OvmfOptHwComponents.dsc.inc

!if $(SECURE_BOOT_ENABLE) == TRUE
  SecurityPkg/VariableAuthenticated/SecureBootConfigDxe/SecureBootConfigDxe.inf
  OvmfPkg/IgvmSecureBootDxe/IgvmSecureBootDxe.inf
  OvmfPkg/EnrollDefaultKeys/EnrollDefaultKeys.inf
!endif

  DoryPCPkg/DoryPlatformDxe/DoryPlatformDxe.inf

!if $(SMM_REQUIRE) == TRUE
  OvmfPkg/SmmAccess/SmmAccess2Dxe.inf
  OvmfPkg/SmmControl2Dxe/SmmControl2Dxe.inf
  OvmfPkg/CpuS3DataDxe/CpuS3DataDxe.inf

  #
  # SMM Initial Program Load (a DXE_RUNTIME_DRIVER)
  #
!if $(STANDALONE_MM_ENABLE) == TRUE
  OvmfPkg/SmmControl2Dxe/MmControlPei.inf
  StandaloneMmPkg/Drivers/StandaloneMmIplPei/StandaloneMmIplPei.inf
  StandaloneMmPkg/Drivers/MmCommunicationDxe/MmCommunicationDxe.inf {
    <LibraryClasses>
      NULL|StandaloneMmPkg/Library/VariableMmDependency/VariableMmDependency.inf
  }
!else
  MdeModulePkg/Core/PiSmmCore/PiSmmIpl.inf
!endif

  #
  # SMM_CORE
  #
!if $(STANDALONE_MM_ENABLE) == TRUE
  StandaloneMmPkg/Core/StandaloneMmCore.inf
!else
  MdeModulePkg/Core/PiSmmCore/PiSmmCore.inf
!endif

  #
  # Privileged drivers (DXE_SMM_DRIVER modules)
  #
!if $(STANDALONE_MM_ENABLE) == TRUE
  UefiCpuPkg/CpuIo2Smm/CpuIo2StandaloneMm.inf
  UefiCpuPkg/PiSmmCpuDxeSmm/PiSmmCpuStandaloneMm.inf {
    <LibraryClasses>
      SmmCpuPlatformHookLib|OvmfPkg/Library/SmmCpuPlatformHookLibQemu/SmmCpuPlatformHookLibQemu.inf
      SmmCpuFeaturesLib|OvmfPkg/Library/SmmCpuFeaturesLib/StandaloneMmCpuFeaturesLib.inf
      MmSaveStateLib|UefiCpuPkg/Library/MmSaveStateLib/AmdMmSaveStateLib.inf
      AmdSysCallLib|UefiCpuPkg/Library/AmdSysCallLibNull/AmdSysCallLibNull.inf
      SmmCpuSyncLib|UefiCpuPkg/Library/SmmCpuSyncLib/SmmCpuSyncLib.inf
  }

  #
  # Variable driver stack (SMM)
  #
  OvmfPkg/QemuFlashFvbServicesRuntimeDxe/FvbServicesStandaloneMm.inf {
    <LibraryClasses>
    CcExitLib|UefiCpuPkg/Library/CcExitLibNull/CcExitLibNull.inf
  }
  MdeModulePkg/Universal/FaultTolerantWriteDxe/FaultTolerantWriteStandaloneMm.inf
  MdeModulePkg/Universal/Variable/RuntimeDxe/VariableStandaloneMm.inf {
    <LibraryClasses>
      NULL|MdeModulePkg/Library/VarCheckUefiLib/VarCheckUefiLib.inf
      NULL|MdeModulePkg/Library/VarCheckPolicyLib/VarCheckPolicyLibStandaloneMm.inf
  }
!else
  OvmfPkg/CpuHotplugSmm/CpuHotplugSmm.inf
  UefiCpuPkg/CpuIo2Smm/CpuIo2Smm.inf
  MdeModulePkg/Universal/LockBox/SmmLockBox/SmmLockBox.inf {
    <LibraryClasses>
      LockBoxLib|MdeModulePkg/Library/SmmLockBoxLib/SmmLockBoxSmmLib.inf
  }
  UefiCpuPkg/PiSmmCpuDxeSmm/PiSmmCpuDxeSmm.inf {
     <LibraryClasses>
       SmmCpuPlatformHookLib|OvmfPkg/Library/SmmCpuPlatformHookLibQemu/SmmCpuPlatformHookLibQemu.inf
       SmmCpuFeaturesLib|OvmfPkg/Library/SmmCpuFeaturesLib/SmmCpuFeaturesLib.inf
       MmSaveStateLib|UefiCpuPkg/Library/MmSaveStateLib/AmdMmSaveStateLib.inf
       AmdSysCallLib|UefiCpuPkg/Library/AmdSysCallLibNull/AmdSysCallLibNull.inf
       SmmCpuSyncLib|UefiCpuPkg/Library/SmmCpuSyncLib/SmmCpuSyncLib.inf
   }

  #
  # Variable driver stack (SMM)
  #
  OvmfPkg/QemuFlashFvbServicesRuntimeDxe/FvbServicesSmm.inf {
    <LibraryClasses>
    CcExitLib|UefiCpuPkg/Library/CcExitLibNull/CcExitLibNull.inf
  }
  MdeModulePkg/Universal/FaultTolerantWriteDxe/FaultTolerantWriteSmm.inf
  MdeModulePkg/Universal/Variable/RuntimeDxe/VariableSmm.inf {
    <LibraryClasses>
      NULL|MdeModulePkg/Library/VarCheckUefiLib/VarCheckUefiLib.inf
      NULL|MdeModulePkg/Library/VarCheckPolicyLib/VarCheckPolicyLib.inf
  }
!endif
  MdeModulePkg/Universal/SmmCommunicationBufferDxe/SmmCommunicationBufferDxe.inf

  MdeModulePkg/Universal/Variable/RuntimeDxe/VariableSmmRuntimeDxe.inf

!else
!if $(QEMU_PV_VARS) == TRUE

  #
  # Variable driver stack (qemu -device uefi-vars)
  #
  OvmfPkg/VirtMmCommunicationDxe/VirtMmCommunication.inf
  MdeModulePkg/Universal/Variable/RuntimeDxe/VariableSmmRuntimeDxe.inf

!else

  #
  # Variable driver stack (non-SMM)
  #
  DoryPCPkg/DoryVariableRuntimeDxe/DoryVariableRuntimeDxe.inf
!endif
!endif

  #
  # Cc Measurement Protocol for Td guest
  #
!if $(CC_MEASUREMENT_ENABLE) == TRUE
  OvmfPkg/Tcg/TdTcg2Dxe/TdTcg2Dxe.inf {
    <LibraryClasses>
      HashLib|OvmfPkg/Library/HashLibTdx/HashLibTdx.inf
      NULL|SecurityPkg/Library/HashInstanceLibSha384/HashInstanceLibSha384.inf
  }
!endif

  #
  # TPM support
  #
!include OvmfPkg/Include/Dsc/OvmfTpmComponentsDxe.dsc.inc

  #
  # Smbios Measurement support
  #
!if $(TPM2_ENABLE) == TRUE || $(CC_MEASUREMENT_ENABLE) == TRUE
  MdeModulePkg/Universal/SmbiosMeasurementDxe/SmbiosMeasurementDxe.inf
!endif
