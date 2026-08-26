#ifndef DORY_GUEST_MEMORY_SHIM_H
#define DORY_GUEST_MEMORY_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint8_t bytes[16];
} DoryGuestMemoryBackingIdentity;

/// Creates, immediately unlinks, sizes, and identifies one POSIX shared-memory object.
/// Returns an O_RDWR, close-on-exec descriptor, or -1 with errno set.
int DoryCreateGuestMemoryBacking(
    uint64_t guest_size,
    DoryGuestMemoryBackingIdentity *identity,
    uint64_t *declared_file_size
);

/// Returns the page-aligned byte offset at which guest RAM begins in the backing object.
uint64_t DoryGuestMemoryBackingDataOffset(void);

/// Validates an unlinked POSIX shared-memory descriptor and returns its embedded identity.
/// This accepts no regular filesystem file, even when its size and header bytes match.
int DoryReadGuestMemoryBackingIdentity(
    int descriptor,
    uint64_t declared_file_size,
    DoryGuestMemoryBackingIdentity *identity
);

/// Exact owner-side validation, including identity and close-on-exec state.
int DoryGuestMemoryBackingMatches(
    int descriptor,
    uint64_t declared_file_size,
    const DoryGuestMemoryBackingIdentity *identity
);

#ifdef __cplusplus
}
#endif

#endif
