#include "DoryJITRuntimeC.h"

#include <errno.h>
#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#if defined(__aarch64__)

enum { dory_jit_region_magic = 0x444f5259 };
enum {
    dory_jit_read_tlb_magic = 0x44544c42,
    dory_jit_read_tlb_page_shift = 12,
    dory_jit_read_tlb_entry_count = 1024,
};

struct dory_jit_read_tlb_entry {
    uint64_t linear_page;
    const uint8_t *host_page;
};

struct dory_jit_read_tlb {
    uint32_t magic;
    struct dory_jit_read_tlb_entry entries[dory_jit_read_tlb_entry_count];
    uint64_t hit_count;
    uint64_t miss_count;
    uint64_t slow_path_count;
};

struct dory_jit_memory_context {
    dory_jit_read_tlb *read_tlb;
    void *slow_context;
    dory_jit_memory_read_function slow_read;
    dory_jit_memory_write_function slow_write;
};

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

static size_t dory_jit_read_tlb_index(uint64_t linear_page) {
    uint64_t value = linear_page;
    value ^= value >> 17;
    value ^= value >> 31;
    return (size_t)(value & (dory_jit_read_tlb_entry_count - 1));
}

int dory_jit_read_tlb_create(dory_jit_read_tlb **tlb_out) {
    if (tlb_out == NULL) {
        return EINVAL;
    }
    *tlb_out = NULL;
    dory_jit_read_tlb *tlb = calloc(1, sizeof(*tlb));
    if (tlb == NULL) {
        return ENOMEM;
    }
    tlb->magic = dory_jit_read_tlb_magic;
    *tlb_out = tlb;
    return 0;
}

void dory_jit_read_tlb_destroy(dory_jit_read_tlb *tlb) {
    if (tlb == NULL || tlb->magic != dory_jit_read_tlb_magic) {
        return;
    }
    tlb->magic = 0;
    free(tlb);
}

void dory_jit_read_tlb_invalidate_all(dory_jit_read_tlb *tlb) {
    if (tlb == NULL || tlb->magic != dory_jit_read_tlb_magic) {
        return;
    }
    memset(tlb->entries, 0, sizeof(tlb->entries));
}

void dory_jit_read_tlb_invalidate(dory_jit_read_tlb *tlb, uint64_t linear_address) {
    if (tlb == NULL || tlb->magic != dory_jit_read_tlb_magic) {
        return;
    }
    const uint64_t linear_page = linear_address >> dory_jit_read_tlb_page_shift;
    struct dory_jit_read_tlb_entry *entry =
        &tlb->entries[dory_jit_read_tlb_index(linear_page)];
    if (entry->host_page != NULL && entry->linear_page == linear_page) {
        memset(entry, 0, sizeof(*entry));
    }
}

int dory_jit_read_tlb_install(
    dory_jit_read_tlb *tlb,
    uint64_t linear_address,
    const void *host_page
) {
    if (tlb == NULL || tlb->magic != dory_jit_read_tlb_magic || host_page == NULL ||
        (linear_address & ((1u << dory_jit_read_tlb_page_shift) - 1)) != 0) {
        return EINVAL;
    }
    const uint64_t linear_page = linear_address >> dory_jit_read_tlb_page_shift;
    struct dory_jit_read_tlb_entry *entry =
        &tlb->entries[dory_jit_read_tlb_index(linear_page)];
    entry->linear_page = linear_page;
    entry->host_page = host_page;
    return 0;
}

void dory_jit_read_tlb_get_metrics(
    const dory_jit_read_tlb *tlb,
    dory_jit_read_tlb_metrics *metrics_out
) {
    if (metrics_out == NULL) {
        return;
    }
    memset(metrics_out, 0, sizeof(*metrics_out));
    if (tlb == NULL || tlb->magic != dory_jit_read_tlb_magic) {
        return;
    }
    metrics_out->hit_count = tlb->hit_count;
    metrics_out->miss_count = tlb->miss_count;
    metrics_out->slow_path_count = tlb->slow_path_count;
}

static uint64_t dory_jit_memory_read_with_tlb(
    void *opaque_context,
    uint64_t address,
    uint32_t byte_count
) {
    struct dory_jit_memory_context *context = opaque_context;
    if (context == NULL || context->read_tlb == NULL ||
        context->read_tlb->magic != dory_jit_read_tlb_magic) {
        return 0;
    }
    dory_jit_read_tlb *tlb = context->read_tlb;
    const uint64_t page_offset = address & ((1u << dory_jit_read_tlb_page_shift) - 1);
    if ((byte_count == 1 || byte_count == 2 || byte_count == 4 || byte_count == 8) &&
        page_offset <= (1u << dory_jit_read_tlb_page_shift) - byte_count) {
        const uint64_t linear_page = address >> dory_jit_read_tlb_page_shift;
        const struct dory_jit_read_tlb_entry *entry =
            &tlb->entries[dory_jit_read_tlb_index(linear_page)];
        if (entry->host_page != NULL && entry->linear_page == linear_page) {
            uint64_t value = 0;
            memcpy(&value, entry->host_page + page_offset, byte_count);
            tlb->hit_count++;
            return value;
        }
    }
    tlb->miss_count++;
    if (context->slow_read == NULL) {
        return 0;
    }
    tlb->slow_path_count++;
    return context->slow_read(context->slow_context, address, byte_count);
}

static void dory_jit_memory_write_slow(
    void *opaque_context,
    uint64_t address,
    uint64_t value,
    uint32_t byte_count
) {
    struct dory_jit_memory_context *context = opaque_context;
    if (context != NULL && context->slow_write != NULL) {
        context->slow_write(context->slow_context, address, value, byte_count);
    }
}

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

int dory_jit_region_execute_with_read_tlb(
    const dory_jit_region *region,
    size_t offset,
    uint64_t *context,
    dory_jit_read_tlb *read_tlb,
    void *slow_memory_context,
    dory_jit_memory_read_function slow_memory_read,
    dory_jit_memory_write_function slow_memory_write,
    uint32_t *exit_code_out
) {
    if (read_tlb == NULL || read_tlb->magic != dory_jit_read_tlb_magic) {
        return EINVAL;
    }
    struct dory_jit_memory_context memory_context = {
        .read_tlb = read_tlb,
        .slow_context = slow_memory_context,
        .slow_read = slow_memory_read,
        .slow_write = slow_memory_write,
    };
    return dory_jit_region_execute(
        region,
        offset,
        context,
        &memory_context,
        dory_jit_memory_read_with_tlb,
        dory_jit_memory_write_slow,
        exit_code_out
    );
}

int dory_jit_region_execute_batch(
    const dory_jit_region *region,
    const size_t *offsets,
    const uint64_t *expected_guest_rips,
    const uint32_t *guest_instruction_counts,
    size_t block_count,
    uint64_t *context,
    uint32_t *exit_code_out,
    uint32_t *executed_block_count_out,
    uint32_t *guest_instruction_count_out
) {
    if (region == NULL || offsets == NULL || expected_guest_rips == NULL ||
        guest_instruction_counts == NULL || block_count == 0 || context == NULL ||
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
        // Batch callers admit only blocks without memory callbacks. Keeping callback authority
        // absent makes that contract fail closed if a mismatched block ever reaches this path.
        exit_code = callable.function(context, NULL, NULL, NULL);
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
struct dory_jit_read_tlb {};

int dory_jit_read_tlb_create(dory_jit_read_tlb **tlb_out) {
    if (tlb_out != NULL) {
        *tlb_out = NULL;
    }
    return ENOTSUP;
}
void dory_jit_read_tlb_destroy(dory_jit_read_tlb *tlb) { (void)tlb; }
void dory_jit_read_tlb_invalidate_all(dory_jit_read_tlb *tlb) { (void)tlb; }
void dory_jit_read_tlb_invalidate(dory_jit_read_tlb *tlb, uint64_t linear_address) {
    (void)tlb;
    (void)linear_address;
}
int dory_jit_read_tlb_install(
    dory_jit_read_tlb *tlb,
    uint64_t linear_address,
    const void *host_page
) {
    (void)tlb;
    (void)linear_address;
    (void)host_page;
    return ENOTSUP;
}
void dory_jit_read_tlb_get_metrics(
    const dory_jit_read_tlb *tlb,
    dory_jit_read_tlb_metrics *metrics_out
) {
    (void)tlb;
    if (metrics_out != NULL) {
        memset(metrics_out, 0, sizeof(*metrics_out));
    }
}

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
int dory_jit_region_execute_with_read_tlb(
    const dory_jit_region *region,
    size_t offset,
    uint64_t *context,
    dory_jit_read_tlb *read_tlb,
    void *slow_memory_context,
    dory_jit_memory_read_function slow_memory_read,
    dory_jit_memory_write_function slow_memory_write,
    uint32_t *exit_code_out
) {
    (void)region;
    (void)offset;
    (void)context;
    (void)read_tlb;
    (void)slow_memory_context;
    (void)slow_memory_read;
    (void)slow_memory_write;
    (void)exit_code_out;
    return ENOTSUP;
}
int dory_jit_region_execute_batch(
    const dory_jit_region *region,
    const size_t *offsets,
    const uint64_t *expected_guest_rips,
    const uint32_t *guest_instruction_counts,
    size_t block_count,
    uint64_t *context,
    uint32_t *exit_code_out,
    uint32_t *executed_block_count_out,
    uint32_t *guest_instruction_count_out
) {
    (void)region;
    (void)offsets;
    (void)expected_guest_rips;
    (void)guest_instruction_counts;
    (void)block_count;
    (void)context;
    (void)exit_code_out;
    (void)executed_block_count_out;
    (void)guest_instruction_count_out;
    return ENOTSUP;
}

#endif
