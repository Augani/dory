#include "DoryJITRuntimeC.h"

#include <errno.h>
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#if defined(__aarch64__)

enum { dory_jit_region_magic = 0x444f5259 };

struct dory_jit_region {
    uint32_t magic;
    void *reservation;
    size_t reservation_size;
    uint8_t *code;
    size_t capacity;
    pthread_mutex_t publication_lock;
    _Atomic uint64_t generation;
};

struct dory_jit_publication {
    struct dory_jit_region *region;
    size_t offset;
    const uint8_t *bytes;
    size_t byte_count;
    uint64_t generation;
};

static int dory_publish_code(void *opaque_context) {
    struct dory_jit_publication *context = opaque_context;
    if (context == NULL || context->region == NULL || context->bytes == NULL ||
        context->byte_count == 0 || context->generation == 0) {
        return EINVAL;
    }
    struct dory_jit_region *region = context->region;
    if (region->magic != dory_jit_region_magic || region->code == NULL ||
        (context->offset & 3) != 0 || (context->byte_count & 3) != 0 ||
        context->offset > region->capacity ||
        context->byte_count > region->capacity - context->offset) {
        return EINVAL;
    }
    const uint64_t prior = atomic_load_explicit(&region->generation, memory_order_relaxed);
    if (context->generation <= prior) {
        return EPERM;
    }
    uint8_t *destination = region->code + context->offset;
    memcpy(destination, context->bytes, context->byte_count);
    sys_icache_invalidate(destination, context->byte_count);
    atomic_store_explicit(&region->generation, context->generation, memory_order_release);
    return 0;
}

PTHREAD_JIT_WRITE_ALLOW_CALLBACKS_NP(dory_publish_code);

int dory_jit_region_create(size_t minimum_capacity, dory_jit_region **region_out) {
    if (minimum_capacity == 0 || region_out == NULL) {
        return EINVAL;
    }
    *region_out = NULL;
    if (!pthread_jit_write_protect_supported_np()) {
        return ENOTSUP;
    }
    const long page_value = sysconf(_SC_PAGESIZE);
    if (page_value <= 0) {
        return EINVAL;
    }
    const size_t page_size = (size_t)page_value;
    if (minimum_capacity > SIZE_MAX - (page_size - 1)) {
        return EOVERFLOW;
    }
    const size_t capacity = (minimum_capacity + page_size - 1) & ~(page_size - 1);
    if (capacity > SIZE_MAX - 2 * page_size) {
        return EOVERFLOW;
    }
    const size_t reservation_size = capacity + 2 * page_size;
    void *reservation = mmap(
        NULL,
        reservation_size,
        PROT_NONE,
        MAP_PRIVATE | MAP_ANON,
        -1,
        0
    );
    if (reservation == MAP_FAILED) {
        return errno;
    }
    uint8_t *requested_code = (uint8_t *)reservation + page_size;
    if (munmap(requested_code, capacity) != 0) {
        const int result = errno;
        munmap(reservation, reservation_size);
        return result;
    }
    void *code = mmap(
        requested_code,
        capacity,
        PROT_READ | PROT_WRITE | PROT_EXEC,
        MAP_PRIVATE | MAP_ANON | MAP_JIT,
        -1,
        0
    );
    if (code == MAP_FAILED || code != requested_code) {
        const int result = code == MAP_FAILED ? errno : EADDRNOTAVAIL;
        if (code != MAP_FAILED) {
            munmap(code, capacity);
        }
        munmap(reservation, reservation_size);
        return result;
    }
    struct dory_jit_region *region = calloc(1, sizeof(*region));
    if (region == NULL) {
        munmap(reservation, reservation_size);
        return ENOMEM;
    }
    if (pthread_mutex_init(&region->publication_lock, NULL) != 0) {
        free(region);
        munmap(reservation, reservation_size);
        return EINVAL;
    }
    region->magic = dory_jit_region_magic;
    region->reservation = reservation;
    region->reservation_size = reservation_size;
    region->code = code;
    region->capacity = capacity;
    atomic_init(&region->generation, 0);
    *region_out = region;
    return 0;
}

void dory_jit_region_destroy(dory_jit_region *region) {
    if (region == NULL || region->magic != dory_jit_region_magic) {
        return;
    }
    region->magic = 0;
    munmap(region->reservation, region->reservation_size);
    pthread_mutex_destroy(&region->publication_lock);
    free(region);
}

size_t dory_jit_region_capacity(const dory_jit_region *region) {
    return region != NULL && region->magic == dory_jit_region_magic ? region->capacity : 0;
}

void *dory_jit_region_entry(const dory_jit_region *region, size_t offset) {
    if (region == NULL || region->magic != dory_jit_region_magic ||
        (offset & 3) != 0 || offset >= region->capacity) {
        return NULL;
    }
    return region->code + offset;
}

int dory_jit_region_publish(
    dory_jit_region *region,
    size_t offset,
    const uint8_t *bytes,
    size_t byte_count
) {
    if (region == NULL || region->magic != dory_jit_region_magic) {
        return EINVAL;
    }
    pthread_mutex_lock(&region->publication_lock);
    const uint64_t generation =
        atomic_load_explicit(&region->generation, memory_order_relaxed) + 1;
    struct dory_jit_publication publication = {
        .region = region,
        .offset = offset,
        .bytes = bytes,
        .byte_count = byte_count,
        .generation = generation,
    };
    const int result = pthread_jit_write_with_callback_np(dory_publish_code, &publication);
    pthread_mutex_unlock(&region->publication_lock);
    return result;
}

int dory_jit_region_execute(
    const dory_jit_region *region,
    size_t offset,
    uint64_t *context,
    void *memory_context,
    dory_jit_memory_read_function memory_read,
    dory_jit_memory_write_function memory_write,
    uint32_t *exit_code_out
) {
    void *entry = dory_jit_region_entry(region, offset);
    if (entry == NULL || context == NULL || exit_code_out == NULL) {
        return EINVAL;
    }
    typedef uint32_t (*dory_jit_function)(
        uint64_t *,
        void *,
        dory_jit_memory_read_function,
        dory_jit_memory_write_function
    );
    union {
        void *pointer;
        dory_jit_function function;
    } callable = {.pointer = entry};
    *exit_code_out = callable.function(context, memory_context, memory_read, memory_write);
    return 0;
}

int dory_jit_region_execute_batch(
    const dory_jit_region *region,
    const size_t *offsets,
    const uint64_t *expected_guest_rips,
    const uint32_t *guest_instruction_counts,
    const uint8_t *requires_memory_callbacks,
    size_t block_count,
    uint64_t *context,
    dory_jit_memory_context *memory_context,
    dory_jit_memory_read_function memory_read,
    dory_jit_memory_write_function memory_write,
    uint32_t *exit_code_out,
    uint32_t *executed_block_count_out,
    uint32_t *guest_instruction_count_out
) {
    if (region == NULL || offsets == NULL || expected_guest_rips == NULL ||
        guest_instruction_counts == NULL || requires_memory_callbacks == NULL ||
        block_count == 0 || context == NULL ||
        exit_code_out == NULL || executed_block_count_out == NULL ||
        guest_instruction_count_out == NULL) {
        return EINVAL;
    }
    typedef uint32_t (*dory_jit_function)(
        uint64_t *,
        void *,
        dory_jit_memory_read_function,
        dory_jit_memory_write_function
    );
    uint32_t executed = 0;
    uint32_t instructions = 0;
    uint32_t exit_code = 0;
    uint64_t checkpoint[18];
    for (size_t index = 0; index < block_count; index++) {
        if (context[16] != expected_guest_rips[index]) {
            break;
        }
        void *entry = dory_jit_region_entry(region, offsets[index]);
        if (entry == NULL || guest_instruction_counts[index] == 0 ||
            UINT32_MAX - instructions < guest_instruction_counts[index]) {
            return EINVAL;
        }
        union {
            void *pointer;
            dory_jit_function function;
        } callable = {.pointer = entry};
        const bool uses_memory = requires_memory_callbacks[index] != 0;
        if (uses_memory) {
            if (memory_context == NULL || memory_read == NULL || memory_write == NULL) {
                return EINVAL;
            }
            memcpy(checkpoint, context, sizeof(checkpoint));
            memory_context->failed = 0;
        }
        exit_code = callable.function(context, memory_context, memory_read, memory_write);
        if (uses_memory && memory_context->failed != 0) {
            memcpy(context, checkpoint, sizeof(checkpoint));
            exit_code = 1;
            break;
        }
        executed++;
        instructions += guest_instruction_counts[index];
        if (exit_code != 0) {
            break;
        }
    }
    *exit_code_out = exit_code;
    *executed_block_count_out = executed;
    *guest_instruction_count_out = instructions;
    return 0;
}

#else

struct dory_jit_region {};

int dory_jit_region_create(size_t minimum_capacity, dory_jit_region **region_out) {
    (void)minimum_capacity;
    if (region_out != NULL) {
        *region_out = NULL;
    }
    return ENOTSUP;
}

void dory_jit_region_destroy(dory_jit_region *region) { (void)region; }
size_t dory_jit_region_capacity(const dory_jit_region *region) {
    (void)region;
    return 0;
}
void *dory_jit_region_entry(const dory_jit_region *region, size_t offset) {
    (void)region;
    (void)offset;
    return NULL;
}
int dory_jit_region_publish(
    dory_jit_region *region,
    size_t offset,
    const uint8_t *bytes,
    size_t byte_count
) {
    (void)region;
    (void)offset;
    (void)bytes;
    (void)byte_count;
    return ENOTSUP;
}
int dory_jit_region_execute(
    const dory_jit_region *region,
    size_t offset,
    uint64_t *context,
    void *memory_context,
    dory_jit_memory_read_function memory_read,
    dory_jit_memory_write_function memory_write,
    uint32_t *exit_code_out
) {
    (void)region;
    (void)offset;
    (void)context;
    (void)memory_context;
    (void)memory_read;
    (void)memory_write;
    (void)exit_code_out;
    return ENOTSUP;
}
int dory_jit_region_execute_batch(
    const dory_jit_region *region,
    const size_t *offsets,
    const uint64_t *expected_guest_rips,
    const uint32_t *guest_instruction_counts,
    const uint8_t *requires_memory_callbacks,
    size_t block_count,
    uint64_t *context,
    dory_jit_memory_context *memory_context,
    dory_jit_memory_read_function memory_read,
    dory_jit_memory_write_function memory_write,
    uint32_t *exit_code_out,
    uint32_t *executed_block_count_out,
    uint32_t *guest_instruction_count_out
) {
    (void)region;
    (void)offsets;
    (void)expected_guest_rips;
    (void)guest_instruction_counts;
    (void)requires_memory_callbacks;
    (void)block_count;
    (void)context;
    (void)memory_context;
    (void)memory_read;
    (void)memory_write;
    (void)exit_code_out;
    (void)executed_block_count_out;
    (void)guest_instruction_count_out;
    return ENOTSUP;
}

#endif
