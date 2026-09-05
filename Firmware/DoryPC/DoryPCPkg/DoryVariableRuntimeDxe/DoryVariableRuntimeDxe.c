// SPDX-License-Identifier: BSD-2-Clause-Patent

#include <Uefi.h>
#include <Guid/EventGroup.h>
#include <Library/BaseLib.h>
#include <Library/BaseMemoryLib.h>
#include <Library/DebugLib.h>
#include <Library/DxeServicesTableLib.h>
#include <Library/IoLib.h>
#include <Library/PcdLib.h>
#include <Library/UefiBootServicesTableLib.h>
#include <Library/UefiRuntimeLib.h>
#include <Protocol/Variable.h>

#define DORY_VARIABLE_MAGIC              0x3152415659524F44ULL
#define DORY_VARIABLE_VERSION            1U
#define DORY_VARIABLE_MAX_NAME_BYTES     1024U
#define DORY_VARIABLE_MAX_DATA_BYTES     0x00100000U
#define DORY_VARIABLE_MAX_TOTAL_BYTES    0x01000000ULL
#define DORY_VARIABLE_MAX_COUNT          4096U

#define DORY_VARIABLE_MAGIC_OFFSET       0x0000U
#define DORY_VARIABLE_VERSION_OFFSET     0x0008U
#define DORY_VARIABLE_STATUS_OFFSET      0x000CU
#define DORY_VARIABLE_COMMAND_OFFSET     0x0010U
#define DORY_VARIABLE_ATTRIBUTES_OFFSET  0x0014U
#define DORY_VARIABLE_GENERATION_OFFSET  0x0018U
#define DORY_VARIABLE_VENDOR_OFFSET      0x0020U
#define DORY_VARIABLE_NAME_LENGTH_OFFSET 0x0030U
#define DORY_VARIABLE_DATA_LENGTH_OFFSET 0x0034U
#define DORY_VARIABLE_NAME_OFFSET        0x1000U
#define DORY_VARIABLE_DATA_OFFSET        0x2000U

#define DORY_VARIABLE_COMMAND_RESET      0U
#define DORY_VARIABLE_COMMAND_GET        1U
#define DORY_VARIABLE_COMMAND_SET        2U
#define DORY_VARIABLE_COMMAND_DELETE     3U
#define DORY_VARIABLE_COMMAND_FIRST      4U
#define DORY_VARIABLE_COMMAND_NEXT       5U

#define DORY_VARIABLE_STATUS_IDLE        0U
#define DORY_VARIABLE_STATUS_SUCCESS     1U
#define DORY_VARIABLE_STATUS_NOT_FOUND   2U
#define DORY_VARIABLE_STATUS_INVALID     3U

#define DORY_VARIABLE_SUPPORTED_ATTRIBUTES \
  (EFI_VARIABLE_NON_VOLATILE | EFI_VARIABLE_BOOTSERVICE_ACCESS | \
   EFI_VARIABLE_RUNTIME_ACCESS | EFI_VARIABLE_APPEND_WRITE)

STATIC volatile UINT8  *mBridge;
STATIC EFI_EVENT       mVirtualAddressChangeEvent;
STATIC EFI_HANDLE      mVariableHandle;

STATIC
UINTN
BridgeAddress (
  IN UINTN  Offset
  )
{
  return (UINTN)mBridge + Offset;
}

STATIC
VOID
WriteBytes (
  IN UINTN        Offset,
  IN CONST UINT8  *Bytes,
  IN UINTN        ByteCount
  )
{
  UINTN  Index;

  for (Index = 0; Index < ByteCount; ++Index) {
    MmioWrite8 (BridgeAddress (Offset + Index), Bytes[Index]);
  }
}

STATIC
VOID
ReadBytes (
  IN  UINTN  Offset,
  OUT UINT8  *Bytes,
  IN  UINTN  ByteCount
  )
{
  UINTN  Index;

  for (Index = 0; Index < ByteCount; ++Index) {
    Bytes[Index] = MmioRead8 (BridgeAddress (Offset + Index));
  }
}

STATIC
VOID
WriteVendor (
  IN CONST EFI_GUID  *VendorGuid
  )
{
  UINT8  Bytes[sizeof (EFI_GUID)];

  Bytes[0]  = (UINT8)(VendorGuid->Data1 >> 24);
  Bytes[1]  = (UINT8)(VendorGuid->Data1 >> 16);
  Bytes[2]  = (UINT8)(VendorGuid->Data1 >> 8);
  Bytes[3]  = (UINT8)VendorGuid->Data1;
  Bytes[4]  = (UINT8)(VendorGuid->Data2 >> 8);
  Bytes[5]  = (UINT8)VendorGuid->Data2;
  Bytes[6]  = (UINT8)(VendorGuid->Data3 >> 8);
  Bytes[7]  = (UINT8)VendorGuid->Data3;
  CopyMem (&Bytes[8], VendorGuid->Data4, sizeof (VendorGuid->Data4));
  WriteBytes (DORY_VARIABLE_VENDOR_OFFSET, Bytes, sizeof (Bytes));
}

STATIC
VOID
ReadVendor (
  OUT EFI_GUID  *VendorGuid
  )
{
  UINT8  Bytes[sizeof (EFI_GUID)];

  ReadBytes (DORY_VARIABLE_VENDOR_OFFSET, Bytes, sizeof (Bytes));
  VendorGuid->Data1 = ((UINT32)Bytes[0] << 24) |
                      ((UINT32)Bytes[1] << 16) |
                      ((UINT32)Bytes[2] << 8) |
                      Bytes[3];
  VendorGuid->Data2 = (UINT16)(((UINT16)Bytes[4] << 8) | Bytes[5]);
  VendorGuid->Data3 = (UINT16)(((UINT16)Bytes[6] << 8) | Bytes[7]);
  CopyMem (VendorGuid->Data4, &Bytes[8], sizeof (VendorGuid->Data4));
}

STATIC
EFI_STATUS
Utf16ToUtf8 (
  IN  CONST CHAR16  *Source,
  OUT UINT8         *Destination,
  OUT UINTN         *DestinationSize
  )
{
  UINT32  CodePoint;
  UINT16  Unit;
  UINTN   InputIndex;
  UINTN   OutputIndex;
  UINTN   Required;

  if ((Source == NULL) || (DestinationSize == NULL)) {
    return EFI_INVALID_PARAMETER;
  }

  InputIndex  = 0;
  OutputIndex = 0;
  while ((Unit = Source[InputIndex++]) != 0) {
    if ((Unit >= 0xD800) && (Unit <= 0xDBFF)) {
      UINT16  Low;

      Low = Source[InputIndex++];
      if ((Low < 0xDC00) || (Low > 0xDFFF)) {
        return EFI_INVALID_PARAMETER;
      }

      CodePoint = 0x10000 + (((UINT32)Unit - 0xD800) << 10) +
                  ((UINT32)Low - 0xDC00);
    } else if ((Unit >= 0xDC00) && (Unit <= 0xDFFF)) {
      return EFI_INVALID_PARAMETER;
    } else {
      CodePoint = Unit;
    }

    if (CodePoint <= 0x7F) {
      Required = 1;
    } else if (CodePoint <= 0x7FF) {
      Required = 2;
    } else if (CodePoint <= 0xFFFF) {
      Required = 3;
    } else {
      Required = 4;
    }

    if ((Required > DORY_VARIABLE_MAX_NAME_BYTES) ||
        (OutputIndex > DORY_VARIABLE_MAX_NAME_BYTES - Required))
    {
      return EFI_INVALID_PARAMETER;
    }

    if (Destination != NULL) {
      if (Required == 1) {
        Destination[OutputIndex] = (UINT8)CodePoint;
      } else if (Required == 2) {
        Destination[OutputIndex]     = (UINT8)(0xC0 | (CodePoint >> 6));
        Destination[OutputIndex + 1] = (UINT8)(0x80 | (CodePoint & 0x3F));
      } else if (Required == 3) {
        Destination[OutputIndex]     = (UINT8)(0xE0 | (CodePoint >> 12));
        Destination[OutputIndex + 1] = (UINT8)(0x80 | ((CodePoint >> 6) & 0x3F));
        Destination[OutputIndex + 2] = (UINT8)(0x80 | (CodePoint & 0x3F));
      } else {
        Destination[OutputIndex]     = (UINT8)(0xF0 | (CodePoint >> 18));
        Destination[OutputIndex + 1] = (UINT8)(0x80 | ((CodePoint >> 12) & 0x3F));
        Destination[OutputIndex + 2] = (UINT8)(0x80 | ((CodePoint >> 6) & 0x3F));
        Destination[OutputIndex + 3] = (UINT8)(0x80 | (CodePoint & 0x3F));
      }
    }

    OutputIndex += Required;
  }

  if (OutputIndex == 0) {
    return EFI_INVALID_PARAMETER;
  }

  *DestinationSize = OutputIndex;
  return EFI_SUCCESS;
}

STATIC
EFI_STATUS
Utf8ToUtf16 (
  IN     CONST UINT8  *Source,
  IN     UINTN        SourceSize,
  OUT    CHAR16       *Destination OPTIONAL,
  IN OUT UINTN        *DestinationSize
  )
{
  UINT32  CodePoint;
  UINT8   First;
  UINT8   Continuation;
  UINTN   ContinuationCount;
  UINTN   Index;
  UINTN   OutputUnits;
  UINTN   RequiredSize;
  UINTN   Shift;

  if ((Source == NULL) || (SourceSize == 0) ||
      (SourceSize > DORY_VARIABLE_MAX_NAME_BYTES) || (DestinationSize == NULL))
  {
    return EFI_INVALID_PARAMETER;
  }

  Index       = 0;
  OutputUnits = 0;
  while (Index < SourceSize) {
    First = Source[Index++];
    if ((First & 0x80) == 0) {
      CodePoint        = First;
      ContinuationCount = 0;
    } else if ((First & 0xE0) == 0xC0) {
      CodePoint        = First & 0x1F;
      ContinuationCount = 1;
      if (CodePoint < 2) {
        return EFI_COMPROMISED_DATA;
      }
    } else if ((First & 0xF0) == 0xE0) {
      CodePoint        = First & 0x0F;
      ContinuationCount = 2;
    } else if ((First & 0xF8) == 0xF0) {
      CodePoint        = First & 0x07;
      ContinuationCount = 3;
    } else {
      return EFI_COMPROMISED_DATA;
    }

    if (ContinuationCount > SourceSize - Index) {
      return EFI_COMPROMISED_DATA;
    }

    for (Shift = 0; Shift < ContinuationCount; ++Shift) {
      Continuation = Source[Index++];
      if ((Continuation & 0xC0) != 0x80) {
        return EFI_COMPROMISED_DATA;
      }

      CodePoint = (CodePoint << 6) | (Continuation & 0x3F);
    }

    if (((ContinuationCount == 2) && (CodePoint < 0x800)) ||
        ((ContinuationCount == 3) && (CodePoint < 0x10000)) ||
        (CodePoint == 0) || (CodePoint > 0x10FFFF) ||
        ((CodePoint >= 0xD800) && (CodePoint <= 0xDFFF)))
    {
      return EFI_COMPROMISED_DATA;
    }

    OutputUnits += (CodePoint > 0xFFFF) ? 2 : 1;
  }

  if (OutputUnits > (MAX_UINTN / sizeof (CHAR16)) - 1) {
    return EFI_BAD_BUFFER_SIZE;
  }

  RequiredSize = (OutputUnits + 1) * sizeof (CHAR16);
  if ((Destination == NULL) || (*DestinationSize < RequiredSize)) {
    *DestinationSize = RequiredSize;
    return EFI_BUFFER_TOO_SMALL;
  }

  Index       = 0;
  OutputUnits = 0;
  while (Index < SourceSize) {
    First = Source[Index++];
    if ((First & 0x80) == 0) {
      CodePoint        = First;
      ContinuationCount = 0;
    } else if ((First & 0xE0) == 0xC0) {
      CodePoint        = First & 0x1F;
      ContinuationCount = 1;
    } else if ((First & 0xF0) == 0xE0) {
      CodePoint        = First & 0x0F;
      ContinuationCount = 2;
    } else {
      CodePoint        = First & 0x07;
      ContinuationCount = 3;
    }

    for (Shift = 0; Shift < ContinuationCount; ++Shift) {
      CodePoint = (CodePoint << 6) | (Source[Index++] & 0x3F);
    }

    if (CodePoint <= 0xFFFF) {
      Destination[OutputUnits++] = (CHAR16)CodePoint;
    } else {
      CodePoint -= 0x10000;
      Destination[OutputUnits++] = (CHAR16)(0xD800 | (CodePoint >> 10));
      Destination[OutputUnits++] = (CHAR16)(0xDC00 | (CodePoint & 0x3FF));
    }
  }

  Destination[OutputUnits] = L'\0';
  *DestinationSize         = RequiredSize;
  return EFI_SUCCESS;
}

STATIC
EFI_STATUS
StatusFromBridge (
  VOID
  )
{
  switch (MmioRead32 (BridgeAddress (DORY_VARIABLE_STATUS_OFFSET))) {
    case DORY_VARIABLE_STATUS_SUCCESS:
      return EFI_SUCCESS;
    case DORY_VARIABLE_STATUS_NOT_FOUND:
      return EFI_NOT_FOUND;
    case DORY_VARIABLE_STATUS_INVALID:
      return EFI_INVALID_PARAMETER;
    case DORY_VARIABLE_STATUS_IDLE:
      return EFI_NOT_READY;
    default:
      return EFI_DEVICE_ERROR;
  }
}

STATIC
EFI_STATUS
StageKey (
  IN CONST CHAR16    *VariableName,
  IN CONST EFI_GUID  *VendorGuid
  )
{
  EFI_STATUS  Status;
  UINT8       Name[DORY_VARIABLE_MAX_NAME_BYTES];
  UINTN       NameSize;

  if ((VariableName == NULL) || (VendorGuid == NULL)) {
    return EFI_INVALID_PARAMETER;
  }

  Status = Utf16ToUtf8 (VariableName, Name, &NameSize);
  if (EFI_ERROR (Status)) {
    return Status;
  }

  WriteVendor (VendorGuid);
  WriteBytes (DORY_VARIABLE_NAME_OFFSET, Name, NameSize);
  MmioWrite32 (BridgeAddress (DORY_VARIABLE_NAME_LENGTH_OFFSET), (UINT32)NameSize);
  MmioWrite32 (BridgeAddress (DORY_VARIABLE_DATA_LENGTH_OFFSET), 0);
  return EFI_SUCCESS;
}

STATIC
EFI_STATUS
SubmitKey (
  IN CONST CHAR16    *VariableName,
  IN CONST EFI_GUID  *VendorGuid,
  IN UINT32          Command
  )
{
  EFI_STATUS  Status;

  Status = StageKey (VariableName, VendorGuid);
  if (EFI_ERROR (Status)) {
    return Status;
  }

  MmioWrite32 (BridgeAddress (DORY_VARIABLE_COMMAND_OFFSET), Command);
  return StatusFromBridge ();
}

STATIC
EFI_STATUS
EFIAPI
DoryGetVariable (
  IN     CHAR16    *VariableName,
  IN     EFI_GUID  *VendorGuid,
  OUT    UINT32    *Attributes OPTIONAL,
  IN OUT UINTN     *DataSize,
  OUT    VOID      *Data OPTIONAL
  )
{
  EFI_STATUS  Status;
  UINT32      RequiredSize;

  if ((VariableName == NULL) || (VendorGuid == NULL) || (DataSize == NULL)) {
    return EFI_INVALID_PARAMETER;
  }

  if (VariableName[0] == L'\0') {
    return EFI_NOT_FOUND;
  }

  Status = SubmitKey (VariableName, VendorGuid, DORY_VARIABLE_COMMAND_GET);
  if (EFI_ERROR (Status)) {
    return Status;
  }

  if (EfiAtRuntime () &&
      ((MmioRead32 (BridgeAddress (DORY_VARIABLE_ATTRIBUTES_OFFSET)) &
        EFI_VARIABLE_RUNTIME_ACCESS) == 0))
  {
    return EFI_NOT_FOUND;
  }

  RequiredSize = MmioRead32 (BridgeAddress (DORY_VARIABLE_DATA_LENGTH_OFFSET));
  if (RequiredSize > DORY_VARIABLE_MAX_DATA_BYTES) {
    return EFI_DEVICE_ERROR;
  }

  if (Attributes != NULL) {
    *Attributes = MmioRead32 (BridgeAddress (DORY_VARIABLE_ATTRIBUTES_OFFSET));
  }

  if (*DataSize < RequiredSize) {
    *DataSize = RequiredSize;
    return EFI_BUFFER_TOO_SMALL;
  }

  if ((RequiredSize > 0) && (Data == NULL)) {
    return EFI_INVALID_PARAMETER;
  }

  if (RequiredSize > 0) {
    ReadBytes (DORY_VARIABLE_DATA_OFFSET, Data, RequiredSize);
  }

  *DataSize = RequiredSize;
  return EFI_SUCCESS;
}

STATIC
EFI_STATUS
EFIAPI
DoryGetNextVariableName (
  IN OUT UINTN     *VariableNameSize,
  IN OUT CHAR16    *VariableName,
  IN OUT EFI_GUID  *VendorGuid
  )
{
  EFI_STATUS  Status;
  UINTN       MaximumNameUnits;
  UINT32      NameSize;
  UINT8       Name[DORY_VARIABLE_MAX_NAME_BYTES];

  if ((VariableNameSize == NULL) || (VariableName == NULL) || (VendorGuid == NULL))
  {
    return EFI_INVALID_PARAMETER;
  }

  MaximumNameUnits = *VariableNameSize / sizeof (CHAR16);
  if ((MaximumNameUnits == 0) ||
      (StrnLenS (VariableName, MaximumNameUnits) == MaximumNameUnits))
  {
    return EFI_INVALID_PARAMETER;
  }

  if (VariableName[0] == L'\0') {
    MmioWrite32 (BridgeAddress (DORY_VARIABLE_NAME_LENGTH_OFFSET), 0);
    MmioWrite32 (BridgeAddress (DORY_VARIABLE_DATA_LENGTH_OFFSET), 0);
    MmioWrite32 (
      BridgeAddress (DORY_VARIABLE_COMMAND_OFFSET),
      DORY_VARIABLE_COMMAND_FIRST
      );
    Status = StatusFromBridge ();
  } else {
    Status = SubmitKey (VariableName, VendorGuid, DORY_VARIABLE_COMMAND_NEXT);
  }

  if (EFI_ERROR (Status)) {
    return Status;
  }

  while (EfiAtRuntime () &&
         ((MmioRead32 (BridgeAddress (DORY_VARIABLE_ATTRIBUTES_OFFSET)) &
           EFI_VARIABLE_RUNTIME_ACCESS) == 0))
  {
    MmioWrite32 (
      BridgeAddress (DORY_VARIABLE_COMMAND_OFFSET),
      DORY_VARIABLE_COMMAND_NEXT
      );
    Status = StatusFromBridge ();
    if (EFI_ERROR (Status)) {
      return Status;
    }
  }

  NameSize = MmioRead32 (BridgeAddress (DORY_VARIABLE_NAME_LENGTH_OFFSET));
  if ((NameSize == 0) || (NameSize > DORY_VARIABLE_MAX_NAME_BYTES)) {
    return EFI_DEVICE_ERROR;
  }

  ReadBytes (DORY_VARIABLE_NAME_OFFSET, Name, NameSize);
  Status = Utf8ToUtf16 (Name, NameSize, VariableName, VariableNameSize);
  if (EFI_ERROR (Status)) {
    return Status;
  }

  ReadVendor (VendorGuid);
  return EFI_SUCCESS;
}

STATIC
EFI_STATUS
EFIAPI
DorySetVariable (
  IN CHAR16    *VariableName,
  IN EFI_GUID  *VendorGuid,
  IN UINT32    Attributes,
  IN UINTN     DataSize,
  IN VOID      *Data
  )
{
  BOOLEAN     Append;
  BOOLEAN     Existing;
  EFI_STATUS  Status;
  UINT32      ExistingAttributes;
  UINT32      ExistingSize;
  UINT32      StoredAttributes;

  if ((VariableName == NULL) || (VariableName[0] == L'\0') || (VendorGuid == NULL) ||
      (DataSize > DORY_VARIABLE_MAX_DATA_BYTES) || ((DataSize > 0) && (Data == NULL)))
  {
    return EFI_INVALID_PARAMETER;
  }

  Append = (Attributes & EFI_VARIABLE_APPEND_WRITE) != 0;
  if (!Append &&
      ((DataSize == 0) ||
       ((Attributes & (EFI_VARIABLE_BOOTSERVICE_ACCESS | EFI_VARIABLE_RUNTIME_ACCESS)) == 0)))
  {
    if (EfiAtRuntime ()) {
      Status = SubmitKey (VariableName, VendorGuid, DORY_VARIABLE_COMMAND_GET);
      if (EFI_ERROR (Status)) {
        return Status;
      }

      ExistingAttributes = MmioRead32 (
                             BridgeAddress (DORY_VARIABLE_ATTRIBUTES_OFFSET)
                             );
      if ((ExistingAttributes & EFI_VARIABLE_RUNTIME_ACCESS) == 0) {
        return EFI_WRITE_PROTECTED;
      }
    }

    return SubmitKey (VariableName, VendorGuid, DORY_VARIABLE_COMMAND_DELETE);
  }

  if ((Attributes == 0) || ((Attributes & ~DORY_VARIABLE_SUPPORTED_ATTRIBUTES) != 0) ||
      ((Attributes & EFI_VARIABLE_BOOTSERVICE_ACCESS) == 0))
  {
    return EFI_INVALID_PARAMETER;
  }

  StoredAttributes = Attributes & ~EFI_VARIABLE_APPEND_WRITE;
  Status           = SubmitKey (VariableName, VendorGuid, DORY_VARIABLE_COMMAND_GET);
  if (Status == EFI_SUCCESS) {
    Existing           = TRUE;
    ExistingAttributes = MmioRead32 (BridgeAddress (DORY_VARIABLE_ATTRIBUTES_OFFSET));
    ExistingSize       = MmioRead32 (BridgeAddress (DORY_VARIABLE_DATA_LENGTH_OFFSET));
    if ((ExistingSize > DORY_VARIABLE_MAX_DATA_BYTES) ||
        (ExistingAttributes != StoredAttributes) ||
        (EfiAtRuntime () && ((ExistingAttributes & EFI_VARIABLE_RUNTIME_ACCESS) == 0)))
    {
      return ((ExistingAttributes != StoredAttributes) ||
              (ExistingSize > DORY_VARIABLE_MAX_DATA_BYTES)) ?
             EFI_INVALID_PARAMETER : EFI_WRITE_PROTECTED;
    }
  } else if (Status == EFI_NOT_FOUND) {
    Existing           = FALSE;
    ExistingAttributes = 0;
    ExistingSize       = 0;
    if (Append && (DataSize == 0)) {
      return EFI_SUCCESS;
    }

    if (EfiAtRuntime () &&
        ((StoredAttributes & (EFI_VARIABLE_NON_VOLATILE | EFI_VARIABLE_RUNTIME_ACCESS)) !=
         (EFI_VARIABLE_NON_VOLATILE | EFI_VARIABLE_RUNTIME_ACCESS)))
    {
      return EFI_INVALID_PARAMETER;
    }
  } else {
    return Status;
  }

  if (Append && Existing) {
    if (DataSize > DORY_VARIABLE_MAX_DATA_BYTES - ExistingSize) {
      return EFI_INVALID_PARAMETER;
    }

    WriteBytes (DORY_VARIABLE_DATA_OFFSET + ExistingSize, Data, DataSize);
    DataSize += ExistingSize;
  } else {
    Status = StageKey (VariableName, VendorGuid);
    if (EFI_ERROR (Status)) {
      return Status;
    }

    WriteBytes (DORY_VARIABLE_DATA_OFFSET, Data, DataSize);
  }

  MmioWrite32 (BridgeAddress (DORY_VARIABLE_DATA_LENGTH_OFFSET), (UINT32)DataSize);
  MmioWrite32 (BridgeAddress (DORY_VARIABLE_ATTRIBUTES_OFFSET), StoredAttributes);
  MmioWrite32 (BridgeAddress (DORY_VARIABLE_COMMAND_OFFSET), DORY_VARIABLE_COMMAND_SET);
  return StatusFromBridge ();
}

STATIC
EFI_STATUS
EFIAPI
DoryQueryVariableInfo (
  IN  UINT32  Attributes,
  OUT UINT64  *MaximumVariableStorageSize,
  OUT UINT64  *RemainingVariableStorageSize,
  OUT UINT64  *MaximumVariableSize
  )
{
  EFI_GUID    VendorGuid;
  EFI_STATUS  Status;
  CHAR16      VariableName[DORY_VARIABLE_MAX_NAME_BYTES + 1];
  UINTN       VariableNameSize;
  UINTN       DataSize;
  UINT64      UsedBytes;
  UINTN       Count;

  if ((MaximumVariableStorageSize == NULL) || (RemainingVariableStorageSize == NULL) ||
      (MaximumVariableSize == NULL) || (Attributes == 0) ||
      ((Attributes & ~DORY_VARIABLE_SUPPORTED_ATTRIBUTES) != 0) ||
      ((Attributes & EFI_VARIABLE_APPEND_WRITE) != 0) ||
      ((Attributes & EFI_VARIABLE_BOOTSERVICE_ACCESS) == 0) ||
      (EfiAtRuntime () && ((Attributes & EFI_VARIABLE_RUNTIME_ACCESS) == 0)))
  {
    return EFI_INVALID_PARAMETER;
  }

  ZeroMem (&VendorGuid, sizeof (VendorGuid));
  VariableName[0] = L'\0';
  UsedBytes       = 0;
  for (Count = 0; Count < DORY_VARIABLE_MAX_COUNT; ++Count) {
    VariableNameSize = sizeof (VariableName);
    Status = DoryGetNextVariableName (
               &VariableNameSize,
               VariableName,
               &VendorGuid
               );
    if (Status == EFI_NOT_FOUND) {
      break;
    }

    if (EFI_ERROR (Status)) {
      return Status;
    }

    DataSize = 0;
    Status   = DoryGetVariable (VariableName, &VendorGuid, NULL, &DataSize, NULL);
    if ((Status != EFI_BUFFER_TOO_SMALL) && EFI_ERROR (Status)) {
      return Status;
    }

    if (DataSize > DORY_VARIABLE_MAX_TOTAL_BYTES - UsedBytes) {
      return EFI_DEVICE_ERROR;
    }

    UsedBytes += DataSize;
  }

  if (Count == DORY_VARIABLE_MAX_COUNT) {
    return EFI_DEVICE_ERROR;
  }

  *MaximumVariableStorageSize   = DORY_VARIABLE_MAX_TOTAL_BYTES;
  *RemainingVariableStorageSize = DORY_VARIABLE_MAX_TOTAL_BYTES - UsedBytes;
  *MaximumVariableSize          = DORY_VARIABLE_MAX_DATA_BYTES;
  return EFI_SUCCESS;
}

STATIC
VOID
EFIAPI
DoryVariableVirtualAddressChange (
  IN EFI_EVENT  Event,
  IN VOID       *Context
  )
{
  EfiConvertPointer (0, (VOID **)&mBridge);
}

STATIC
EFI_STATUS
ConfigureRuntimeMemory (
  VOID
  )
{
  EFI_GCD_MEMORY_SPACE_DESCRIPTOR  Descriptor;
  EFI_PHYSICAL_ADDRESS             Base;
  UINT64                           Size;
  EFI_STATUS                       Status;

  Base = FixedPcdGet64 (PcdVariableBridgeBase);
  Size = FixedPcdGet64 (PcdVariableBridgeSize);
  Status = gDS->GetMemorySpaceDescriptor (Base, &Descriptor);
  if (EFI_ERROR (Status) || (Descriptor.GcdMemoryType == EfiGcdMemoryTypeNonExistent)) {
    Status = gDS->AddMemorySpace (
                    EfiGcdMemoryTypeMemoryMappedIo,
                    Base,
                    Size,
                    EFI_MEMORY_UC | EFI_MEMORY_RUNTIME
                    );
    if (EFI_ERROR (Status)) {
      return Status;
    }

    Status = gDS->GetMemorySpaceDescriptor (Base, &Descriptor);
    if (EFI_ERROR (Status)) {
      return Status;
    }
  }

  if (Descriptor.GcdMemoryType != EfiGcdMemoryTypeMemoryMappedIo) {
    return EFI_UNSUPPORTED;
  }

  Status = gDS->SetMemorySpaceAttributes (
                  Base,
                  Size,
                  Descriptor.Attributes | EFI_MEMORY_RUNTIME
                  );
  return Status;
}

EFI_STATUS
EFIAPI
DoryVariableRuntimeDxeEntryPoint (
  IN EFI_HANDLE        ImageHandle,
  IN EFI_SYSTEM_TABLE  *SystemTable
  )
{
  EFI_STATUS  Status;

  Status = ConfigureRuntimeMemory ();
  if (EFI_ERROR (Status)) {
    return Status;
  }

  mBridge = (volatile UINT8 *)(UINTN)FixedPcdGet64 (PcdVariableBridgeBase);
  if ((MmioRead64 (BridgeAddress (DORY_VARIABLE_MAGIC_OFFSET)) != DORY_VARIABLE_MAGIC) ||
      (MmioRead32 (BridgeAddress (DORY_VARIABLE_VERSION_OFFSET)) != DORY_VARIABLE_VERSION))
  {
    return EFI_UNSUPPORTED;
  }

  MmioWrite32 (BridgeAddress (DORY_VARIABLE_COMMAND_OFFSET), DORY_VARIABLE_COMMAND_RESET);
  if (MmioRead32 (BridgeAddress (DORY_VARIABLE_STATUS_OFFSET)) != DORY_VARIABLE_STATUS_IDLE) {
    return EFI_DEVICE_ERROR;
  }

  Status = gBS->CreateEventEx (
                  EVT_NOTIFY_SIGNAL,
                  TPL_NOTIFY,
                  DoryVariableVirtualAddressChange,
                  NULL,
                  &gEfiEventVirtualAddressChangeGuid,
                  &mVirtualAddressChangeEvent
                  );
  if (EFI_ERROR (Status)) {
    return Status;
  }

  SystemTable->RuntimeServices->GetVariable          = DoryGetVariable;
  SystemTable->RuntimeServices->GetNextVariableName = DoryGetNextVariableName;
  SystemTable->RuntimeServices->SetVariable          = DorySetVariable;
  SystemTable->RuntimeServices->QueryVariableInfo    = DoryQueryVariableInfo;
  SystemTable->RuntimeServices->Hdr.CRC32            = 0;
  Status = gBS->CalculateCrc32 (
                  SystemTable->RuntimeServices,
                  SystemTable->RuntimeServices->Hdr.HeaderSize,
                  &SystemTable->RuntimeServices->Hdr.CRC32
                  );
  if (EFI_ERROR (Status)) {
    return Status;
  }

  Status = gBS->InstallMultipleProtocolInterfaces (
                  &mVariableHandle,
                  &gEfiVariableArchProtocolGuid,
                  NULL,
                  &gEfiVariableWriteArchProtocolGuid,
                  NULL,
                  NULL
                  );
  return Status;
}
