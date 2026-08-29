#include "DoryGuestMemoryShim.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

enum {
    DoryGuestMemoryHeaderByteCount = 48,
    DoryGuestMemoryCreationAttempts = 16,
};

static const uint8_t DoryGuestMemoryMagic[16] = {
    'D', 'O', 'R', 'Y', '-', 'G', 'U', 'E', 'S', 'T', '-', 'R', 'A', 'M', 0, 1,
};

static void DoryStoreLittleEndian64(uint8_t *destination, uint64_t value) {
    for (int index = 0; index < 8; ++index) {
        destination[index] = (uint8_t)(value >> (index * 8));
    }
}

static uint64_t DoryLoadLittleEndian64(const uint8_t *source) {
    uint64_t value = 0;
    for (int index = 0; index < 8; ++index) {
        value |= ((uint64_t)source[index]) << (index * 8);
    }
    return value;
}

uint64_t DoryGuestMemoryBackingDataOffset(void) {
    return (uint64_t)getpagesize();
}

static int DoryDeclaredFileSize(uint64_t guest_size, uint64_t *declared_file_size) {
    uint64_t data_offset = DoryGuestMemoryBackingDataOffset();
    if (guest_size == 0 || guest_size > (uint64_t)INT64_MAX - data_offset) {
        errno = EOVERFLOW;
        return -1;
    }
    *declared_file_size = guest_size + data_offset;
    return 0;
}

static void DoryMakeHeader(
    uint8_t header[DoryGuestMemoryHeaderByteCount],
    uint64_t guest_size,
    const DoryGuestMemoryBackingIdentity *identity
) {
    memset(header, 0, DoryGuestMemoryHeaderByteCount);
    memcpy(header, DoryGuestMemoryMagic, sizeof(DoryGuestMemoryMagic));
    DoryStoreLittleEndian64(header + 16, 1);
    DoryStoreLittleEndian64(header + 24, guest_size);
    memcpy(header + 32, identity->bytes, sizeof(identity->bytes));
}

int DoryCreateGuestMemoryBacking(
    uint64_t guest_size,
    DoryGuestMemoryBackingIdentity *identity,
    uint64_t *declared_file_size
) {
    if (identity == NULL || declared_file_size == NULL) {
        errno = EINVAL;
        return -1;
    }
    if (DoryDeclaredFileSize(guest_size, declared_file_size) != 0) {
        return -1;
    }

    int descriptor = -1;
    for (int attempt = 0; attempt < DoryGuestMemoryCreationAttempts; ++attempt) {
        uint64_t name_nonce = 0;
        arc4random_buf(&name_nonce, sizeof(name_nonce));
        char name[32];
        int length = snprintf(
            name,
            sizeof(name),
            "/dory-%016llx",
            (unsigned long long)name_nonce
        );
        if (length <= 0 || (size_t)length >= sizeof(name)) {
            errno = EINVAL;
            return -1;
        }
        descriptor = shm_open(name, O_RDWR | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR);
        if (descriptor < 0) {
            if (errno == EEXIST) {
                continue;
            }
            return -1;
        }

        // Do not return or perform fallible sizing/header work while a name is still visible.
        if (shm_unlink(name) != 0) {
            int unlink_error = errno;
            close(descriptor);
            errno = unlink_error;
            return -1;
        }
        break;
    }
    if (descriptor < 0) {
        errno = EEXIST;
        return -1;
    }

    int descriptor_flags = fcntl(descriptor, F_GETFD);
    if (descriptor_flags < 0
        || fcntl(descriptor, F_SETFD, descriptor_flags | FD_CLOEXEC) != 0
        || ftruncate(descriptor, (off_t)*declared_file_size) != 0) {
        int setup_error = errno;
        close(descriptor);
        errno = setup_error;
        return -1;
    }

    arc4random_buf(identity->bytes, sizeof(identity->bytes));
    uint8_t header[DoryGuestMemoryHeaderByteCount];
    DoryMakeHeader(header, guest_size, identity);
    size_t data_offset = (size_t)DoryGuestMemoryBackingDataOffset();
    void *authority_page = mmap(
        NULL,
        data_offset,
        PROT_READ | PROT_WRITE,
        MAP_SHARED,
        descriptor,
        0
    );
    if (authority_page == MAP_FAILED) {
        int map_error = errno;
        close(descriptor);
        errno = map_error;
        return -1;
    }
    memcpy(authority_page, header, sizeof(header));
    if (munmap(authority_page, data_offset) != 0) {
        int unmap_error = errno;
        close(descriptor);
        errno = unmap_error;
        return -1;
    }
    return descriptor;
}

int DoryReadGuestMemoryBackingIdentity(
    int descriptor,
    uint64_t declared_file_size,
    DoryGuestMemoryBackingIdentity *identity
) {
    if (descriptor < 0 || identity == NULL) {
        errno = EINVAL;
        return 0;
    }
    uint64_t data_offset = DoryGuestMemoryBackingDataOffset();
    if (declared_file_size <= data_offset || declared_file_size > (uint64_t)INT64_MAX) {
        errno = EINVAL;
        return 0;
    }

    struct stat status;
    if (fstat(descriptor, &status) != 0
        || (status.st_mode & S_IFMT) != 0
        || status.st_nlink != 0
        || status.st_size < 0
        || (uint64_t)status.st_size != declared_file_size) {
        errno = EINVAL;
        return 0;
    }
    int open_flags = fcntl(descriptor, F_GETFL);
    if (open_flags < 0 || (open_flags & O_ACCMODE) != O_RDWR) {
        errno = EINVAL;
        return 0;
    }

    size_t authority_page_size = (size_t)data_offset;
    void *authority_page = mmap(
        NULL,
        authority_page_size,
        PROT_READ,
        MAP_SHARED,
        descriptor,
        0
    );
    if (authority_page == MAP_FAILED) {
        return 0;
    }
    uint8_t header[DoryGuestMemoryHeaderByteCount];
    memcpy(header, authority_page, sizeof(header));
    if (munmap(authority_page, authority_page_size) != 0) {
        return 0;
    }
    if (memcmp(header, DoryGuestMemoryMagic, sizeof(DoryGuestMemoryMagic)) != 0
        || DoryLoadLittleEndian64(header + 16) != 1
        || DoryLoadLittleEndian64(header + 24) != declared_file_size - data_offset) {
        errno = EINVAL;
        return 0;
    }
    memcpy(identity->bytes, header + 32, sizeof(identity->bytes));
    return 1;
}

int DoryGuestMemoryBackingMatches(
    int descriptor,
    uint64_t declared_file_size,
    const DoryGuestMemoryBackingIdentity *identity
) {
    if (identity == NULL) {
        errno = EINVAL;
        return 0;
    }
    int descriptor_flags = fcntl(descriptor, F_GETFD);
    if (descriptor_flags < 0 || (descriptor_flags & FD_CLOEXEC) == 0) {
        errno = EINVAL;
        return 0;
    }
    DoryGuestMemoryBackingIdentity actual_identity;
    if (!DoryReadGuestMemoryBackingIdentity(
            descriptor,
            declared_file_size,
            &actual_identity
        )) {
        return 0;
    }
    return memcmp(identity->bytes, actual_identity.bytes, sizeof(identity->bytes)) == 0;
}
