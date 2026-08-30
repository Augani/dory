// SPDX-License-Identifier: BSD-2-Clause-Patent

#include <Base.h>
#include <Library/BaseLib.h>
#include <Library/TimerLib.h>

#define DORY_TSC_FREQUENCY  1000000000ULL

STATIC
VOID
DelayTicks (
  IN UINT64 Ticks
  )
{
  UINT64 Deadline;

  Deadline = AsmReadTsc () + Ticks;
  while (AsmReadTsc () < Deadline) {
    CpuPause ();
  }
}

UINTN EFIAPI MicroSecondDelay (IN UINTN MicroSeconds) {
  DelayTicks (MultU64x32 (MicroSeconds, 1000));
  return MicroSeconds;
}

UINTN EFIAPI NanoSecondDelay (IN UINTN NanoSeconds) {
  DelayTicks (NanoSeconds);
  return NanoSeconds;
}

UINT64 EFIAPI GetPerformanceCounter (VOID) {
  return AsmReadTsc ();
}

UINT64 EFIAPI GetPerformanceCounterProperties (OUT UINT64 *StartValue OPTIONAL, OUT UINT64 *EndValue OPTIONAL) {
  if (StartValue != NULL) {
    *StartValue = 0;
  }
  if (EndValue != NULL) {
    *EndValue = MAX_UINT64;
  }
  return DORY_TSC_FREQUENCY;
}

UINT64 EFIAPI GetTimeInNanoSecond (IN UINT64 Ticks) {
  return Ticks;
}
