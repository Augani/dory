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

enum {
    dory_jit_tlb_magic = 0x544c4231,
    dory_jit_tlb_access_count = 3,
    dory_jit_block_cache_magic = 0x424c4b31,
    dory_jit_block_cache_empty = 0,
    dory_jit_block_cache_occupied = 1,
    dory_jit_block_cache_tombstone = 2,
    dory_jit_ibtc_magic = 0x49425431,
    dory_jit_shadow_return_stack_magic = 0x52534231,
    dory_jit_exit_pending_work = 5,
};

static const uint64_t dory_jit_tlb_maximum_generation = (UINT64_C(1) << 28) - 1;
// These are the scalar widths admitted by the resolver-backed JIT atomic helpers.
// Requiring compiler-known lock freedom prevents an otherwise invisible libatomic lock
// from becoming the implementation of a guest locked instruction.
_Static_assert(__atomic_always_lock_free(1, 0), "8-bit JIT atomics must be lock-free");
_Static_assert(__atomic_always_lock_free(2, 0), "16-bit JIT atomics must be lock-free");
_Static_assert(__atomic_always_lock_free(4, 0), "32-bit JIT atomics must be lock-free");
_Static_assert(__atomic_always_lock_free(8, 0), "64-bit JIT atomics must be lock-free");

// This gate remains for cooperating interpreter and pair-helper paths. It cannot make
// normal RAM safe for nonparticipating observers, which do not acquire it; aligned scalar
// JIT helpers therefore use the lock-free host atomics below without taking this mutex.
static pthread_mutex_t dory_jit_atomic_mutex = PTHREAD_MUTEX_INITIALIZER;

uint8_t dory_jit_pending_work_load_acquire(const uint8_t *value) {
    return atomic_load_explicit((const _Atomic uint8_t *)value, memory_order_acquire);
}

void dory_jit_pending_work_store_release(uint8_t *value, uint8_t desired) {
    atomic_store_explicit((_Atomic uint8_t *)value, desired, memory_order_release);
}

struct dory_jit_tlb {
    uint32_t magic;
    size_t entry_count;
    dory_jit_tlb_entry *entries;
    uint64_t inline_hit_counts[dory_jit_tlb_access_count];
    uint64_t miss_counts[dory_jit_tlb_access_count];
    uint64_t fill_counts[dory_jit_tlb_access_count];
    uint64_t page_fault_counts[dory_jit_tlb_access_count];
    uint64_t fallback_counts[dory_jit_tlb_access_count];
};

typedef struct dory_jit_block_cache_entry {
    dory_jit_block_key key;
    uint64_t value;
    uint8_t state;
} dory_jit_block_cache_entry;

struct dory_jit_block_cache {
    uint32_t magic;
    size_t count;
    size_t tombstone_count;
    size_t capacity;
    dory_jit_block_cache_entry *entries;
};

struct dory_jit_ibtc {
    uint32_t magic;
    size_t entry_count;
    dory_jit_ibtc_entry *entries;
    uint64_t hit_count;
    uint64_t miss_count;
    uint64_t fill_count;
};

struct dory_jit_shadow_return_stack {
    uint32_t magic;
    size_t entry_count;
    dory_jit_shadow_return_entry *entries;
    uint64_t top;
};

_Static_assert(sizeof(dory_jit_tlb_entry) == 16, "JIT TLB entries must remain two words");
_Static_assert(sizeof(dory_jit_block_key) == 16, "JIT block keys must remain two words");
_Static_assert(sizeof(dory_jit_ibtc_entry) == 32, "IBTC entries must remain four words");
_Static_assert(
    sizeof(dory_jit_shadow_return_entry) == 32,
    "shadow return entries must remain four words"
);
_Static_assert(sizeof(dory_jit_tlb_resolution) == 24, "JIT TLB resolution ABI changed");
_Static_assert(sizeof(dory_jit_atomic_pair_values) == 48, "atomic pair ABI changed");

static int dory_jit_tlb_access_is_valid(dory_jit_tlb_access access) {
    return access >= DORY_JIT_TLB_ACCESS_READ && access <= DORY_JIT_TLB_ACCESS_EXECUTE;
}

static size_t dory_jit_tlb_index(const dory_jit_tlb *tlb, uint64_t linear_address) {
    return (size_t)((linear_address >> 12) & (tlb->entry_count - 1));
}

static uint64_t dory_jit_tlb_tag(
    uint64_t linear_address,
    uint64_t address_space_generation
) {
    if (address_space_generation == 0 ||
        address_space_generation > dory_jit_tlb_maximum_generation) {
        return 0;
    }
    const uint64_t virtual_page_number_mask = (UINT64_C(1) << 36) - 1;
    const uint64_t virtual_page_number = (linear_address >> 12) & virtual_page_number_mask;
    return (virtual_page_number << 28) | address_space_generation;
}

static int dory_jit_block_key_is_valid(dory_jit_block_key key) {
    return key.execution_mode <= 3 && key.privilege_level <= 3 && key.paging_enabled <= 1;
}

static int dory_jit_block_key_equal(dory_jit_block_key lhs, dory_jit_block_key rhs) {
    return lhs.physical_rip == rhs.physical_rip &&
        lhs.execution_mode == rhs.execution_mode &&
        lhs.privilege_level == rhs.privilege_level &&
        lhs.paging_enabled == rhs.paging_enabled;
}

static uint64_t dory_jit_block_key_hash(dory_jit_block_key key) {
    uint64_t value = key.physical_rip;
    value ^= (uint64_t)key.execution_mode << 56;
    value ^= (uint64_t)key.privilege_level << 60;
    value ^= (uint64_t)key.paging_enabled << 63;
    value ^= value >> 30;
    value *= UINT64_C(0xbf58476d1ce4e5b9);
    value ^= value >> 27;
    value *= UINT64_C(0x94d049bb133111eb);
    value ^= value >> 31;
    return value;
}

int dory_jit_ibtc_create(size_t entry_count, dory_jit_ibtc **cache_out) {
    if (cache_out == NULL) {
        return EINVAL;
    }
    *cache_out = NULL;
    if (entry_count == 0 ||
        (entry_count & (entry_count - 1)) != 0 ||
        entry_count > SIZE_MAX / sizeof(dory_jit_ibtc_entry)) {
        return EINVAL;
    }
    dory_jit_ibtc *cache = calloc(1, sizeof(*cache));
    if (cache == NULL) {
        return ENOMEM;
    }
    cache->entries = calloc(entry_count, sizeof(*cache->entries));
    if (cache->entries == NULL) {
        free(cache);
        return ENOMEM;
    }
    cache->magic = dory_jit_ibtc_magic;
    cache->entry_count = entry_count;
    *cache_out = cache;
    return 0;
}

void dory_jit_ibtc_destroy(dory_jit_ibtc *cache) {
    if (cache == NULL || cache->magic != dory_jit_ibtc_magic) {
        return;
    }
    cache->magic = 0;
    free(cache->entries);
    free(cache);
}

size_t dory_jit_ibtc_entry_count(const dory_jit_ibtc *cache) {
    return cache != NULL && cache->magic == dory_jit_ibtc_magic
        ? cache->entry_count
        : 0;
}

size_t dory_jit_ibtc_index(const dory_jit_ibtc *cache, uint64_t guest_rip) {
    if (cache == NULL || cache->magic != dory_jit_ibtc_magic) {
        return SIZE_MAX;
    }
    // Guest instructions are byte aligned. Dropping the two lowest bits avoids concentrating
    // common aligned branch targets while keeping the generated-code index sequence minimal.
    return (size_t)(guest_rip >> 2) & (cache->entry_count - 1);
}

dory_jit_ibtc_entry *dory_jit_ibtc_entries(dory_jit_ibtc *cache) {
    return cache != NULL && cache->magic == dory_jit_ibtc_magic
        ? cache->entries
        : NULL;
}

int dory_jit_ibtc_lookup(
    dory_jit_ibtc *cache,
    uint64_t guest_rip,
    uint64_t generation,
    uint64_t *host_address_out
) {
    if (cache == NULL || cache->magic != dory_jit_ibtc_magic ||
        generation == 0 || host_address_out == NULL) {
        return EINVAL;
    }
    const dory_jit_ibtc_entry *entry =
        &cache->entries[dory_jit_ibtc_index(cache, guest_rip)];
    if (entry->generation != generation || entry->guest_rip != guest_rip ||
        entry->host_address == 0) {
        cache->miss_count++;
        return ENOENT;
    }
    cache->hit_count++;
    *host_address_out = entry->host_address;
    return 0;
}

int dory_jit_ibtc_fill(
    dory_jit_ibtc *cache,
    uint64_t guest_rip,
    uint64_t generation,
    uint64_t host_address
) {
    if (cache == NULL || cache->magic != dory_jit_ibtc_magic ||
        generation == 0 || host_address == 0) {
        return EINVAL;
    }
    dory_jit_ibtc_entry *entry = &cache->entries[dory_jit_ibtc_index(cache, guest_rip)];
    entry->guest_rip = guest_rip;
    entry->host_address = host_address;
    entry->generation = generation;
    entry->reserved = 0;
    cache->fill_count++;
    return 0;
}

void dory_jit_ibtc_clear(dory_jit_ibtc *cache) {
    if (cache == NULL || cache->magic != dory_jit_ibtc_magic) {
        return;
    }
    memset(cache->entries, 0, cache->entry_count * sizeof(*cache->entries));
}

uint64_t dory_jit_ibtc_hit_count(const dory_jit_ibtc *cache) {
    return cache != NULL && cache->magic == dory_jit_ibtc_magic ? cache->hit_count : 0;
}

uint64_t dory_jit_ibtc_miss_count(const dory_jit_ibtc *cache) {
    return cache != NULL && cache->magic == dory_jit_ibtc_magic ? cache->miss_count : 0;
}

uint64_t dory_jit_ibtc_fill_count(const dory_jit_ibtc *cache) {
    return cache != NULL && cache->magic == dory_jit_ibtc_magic ? cache->fill_count : 0;
}

int dory_jit_shadow_return_stack_create(
    size_t entry_count,
    dory_jit_shadow_return_stack **stack_out
) {
    if (stack_out == NULL) {
        return EINVAL;
    }
    *stack_out = NULL;
    if (entry_count == 0 ||
        (entry_count & (entry_count - 1)) != 0 ||
        entry_count > SIZE_MAX / sizeof(dory_jit_shadow_return_entry)) {
        return EINVAL;
    }
    dory_jit_shadow_return_stack *stack = calloc(1, sizeof(*stack));
    if (stack == NULL) {
        return ENOMEM;
    }
    stack->entries = calloc(entry_count, sizeof(*stack->entries));
    if (stack->entries == NULL) {
        free(stack);
        return ENOMEM;
    }
    stack->magic = dory_jit_shadow_return_stack_magic;
    stack->entry_count = entry_count;
    *stack_out = stack;
    return 0;
}

void dory_jit_shadow_return_stack_destroy(dory_jit_shadow_return_stack *stack) {
    if (stack == NULL || stack->magic != dory_jit_shadow_return_stack_magic) {
        return;
    }
    stack->magic = 0;
    free(stack->entries);
    free(stack);
}

size_t dory_jit_shadow_return_stack_entry_count(const dory_jit_shadow_return_stack *stack) {
    return stack != NULL && stack->magic == dory_jit_shadow_return_stack_magic
        ? stack->entry_count
        : 0;
}

dory_jit_shadow_return_entry *dory_jit_shadow_return_stack_entries(
    dory_jit_shadow_return_stack *stack
) {
    return stack != NULL && stack->magic == dory_jit_shadow_return_stack_magic
        ? stack->entries
        : NULL;
}

uint64_t *dory_jit_shadow_return_stack_top(dory_jit_shadow_return_stack *stack) {
    return stack != NULL && stack->magic == dory_jit_shadow_return_stack_magic
        ? &stack->top
        : NULL;
}

int dory_jit_shadow_return_stack_push(
    dory_jit_shadow_return_stack *stack,
    uint64_t guest_rsp,
    uint64_t guest_rip,
    uint64_t host_address,
    uint64_t generation
) {
    if (stack == NULL || stack->magic != dory_jit_shadow_return_stack_magic ||
        generation == 0) {
        return EINVAL;
    }
    const size_t index = (size_t)stack->top & (stack->entry_count - 1);
    dory_jit_shadow_return_entry *entry = &stack->entries[index];
    entry->guest_rsp = guest_rsp;
    entry->guest_rip = guest_rip;
    entry->host_address = host_address;
    entry->generation = generation;
    stack->top++;
    return 0;
}

int dory_jit_shadow_return_stack_lookup_and_pop(
    dory_jit_shadow_return_stack *stack,
    uint64_t guest_rsp,
    uint64_t guest_rip,
    uint64_t generation,
    uint64_t *host_address_out
) {
    if (stack == NULL || stack->magic != dory_jit_shadow_return_stack_magic ||
        generation == 0 || host_address_out == NULL) {
        return EINVAL;
    }
    if (stack->top == 0) {
        return ENOENT;
    }
    stack->top--;
    const dory_jit_shadow_return_entry *entry =
        &stack->entries[(size_t)stack->top & (stack->entry_count - 1)];
    if (entry->guest_rsp != guest_rsp || entry->guest_rip != guest_rip ||
        entry->generation != generation || entry->host_address == 0) {
        return ENOENT;
    }
    *host_address_out = entry->host_address;
    return 0;
}

void dory_jit_shadow_return_stack_clear(dory_jit_shadow_return_stack *stack) {
    if (stack == NULL || stack->magic != dory_jit_shadow_return_stack_magic) {
        return;
    }
    memset(stack->entries, 0, stack->entry_count * sizeof(*stack->entries));
    stack->top = 0;
}

static int dory_jit_block_cache_insert_without_resize(
    dory_jit_block_cache *cache,
    dory_jit_block_key key,
    uint64_t value,
    uint64_t *replaced_value_out
) {
    const size_t mask = cache->capacity - 1;
    size_t index = (size_t)dory_jit_block_key_hash(key) & mask;
    size_t tombstone = SIZE_MAX;
    for (size_t probe = 0; probe < cache->capacity; probe++) {
        dory_jit_block_cache_entry *entry = &cache->entries[index];
        if (entry->state == dory_jit_block_cache_empty) {
            const size_t destination = tombstone == SIZE_MAX ? index : tombstone;
            entry = &cache->entries[destination];
            if (entry->state == dory_jit_block_cache_tombstone) {
                cache->tombstone_count--;
            }
            entry->key = key;
            entry->value = value;
            entry->state = dory_jit_block_cache_occupied;
            cache->count++;
            return 0;
        }
        if (entry->state == dory_jit_block_cache_tombstone) {
            if (tombstone == SIZE_MAX) {
                tombstone = index;
            }
        } else if (dory_jit_block_key_equal(entry->key, key)) {
            if (replaced_value_out != NULL) {
                *replaced_value_out = entry->value;
            }
            entry->value = value;
            return 0;
        }
        index = (index + 1) & mask;
    }
    if (tombstone != SIZE_MAX) {
        dory_jit_block_cache_entry *entry = &cache->entries[tombstone];
        entry->key = key;
        entry->value = value;
        entry->state = dory_jit_block_cache_occupied;
        cache->count++;
        cache->tombstone_count--;
        return 0;
    }
    return ENOSPC;
}

static int dory_jit_block_cache_resize(dory_jit_block_cache *cache, size_t capacity) {
    if (capacity < 16) {
        capacity = 16;
    }
    if ((capacity & (capacity - 1)) != 0 ||
        capacity > SIZE_MAX / sizeof(dory_jit_block_cache_entry)) {
        return EOVERFLOW;
    }
    dory_jit_block_cache_entry *replacement = calloc(capacity, sizeof(*replacement));
    if (replacement == NULL) {
        return ENOMEM;
    }
    dory_jit_block_cache_entry *previous_entries = cache->entries;
    const size_t previous_capacity = cache->capacity;
    cache->entries = replacement;
    cache->capacity = capacity;
    cache->count = 0;
    cache->tombstone_count = 0;
    for (size_t index = 0; index < previous_capacity; index++) {
        const dory_jit_block_cache_entry entry = previous_entries[index];
        if (entry.state == dory_jit_block_cache_occupied) {
            const int result = dory_jit_block_cache_insert_without_resize(
                cache,
                entry.key,
                entry.value,
                NULL
            );
            if (result != 0) {
                free(previous_entries);
                return result;
            }
        }
    }
    free(previous_entries);
    return 0;
}

int dory_jit_block_cache_create(size_t initial_capacity, dory_jit_block_cache **cache_out) {
    if (cache_out == NULL || initial_capacity == 0) {
        return EINVAL;
    }
    *cache_out = NULL;
    size_t capacity = 16;
    while (capacity < initial_capacity) {
        if (capacity > SIZE_MAX / 2) {
            return EOVERFLOW;
        }
        capacity *= 2;
    }
    dory_jit_block_cache *cache = calloc(1, sizeof(*cache));
    if (cache == NULL) {
        return ENOMEM;
    }
    cache->entries = calloc(capacity, sizeof(*cache->entries));
    if (cache->entries == NULL) {
        free(cache);
        return ENOMEM;
    }
    cache->magic = dory_jit_block_cache_magic;
    cache->capacity = capacity;
    *cache_out = cache;
    return 0;
}

void dory_jit_block_cache_destroy(dory_jit_block_cache *cache) {
    if (cache == NULL || cache->magic != dory_jit_block_cache_magic) {
        return;
    }
    cache->magic = 0;
    free(cache->entries);
    free(cache);
}

size_t dory_jit_block_cache_count(const dory_jit_block_cache *cache) {
    return cache != NULL && cache->magic == dory_jit_block_cache_magic ? cache->count : 0;
}

size_t dory_jit_block_cache_capacity(const dory_jit_block_cache *cache) {
    return cache != NULL && cache->magic == dory_jit_block_cache_magic ? cache->capacity : 0;
}

int dory_jit_block_cache_lookup(
    const dory_jit_block_cache *cache,
    dory_jit_block_key key,
    uint64_t *value_out
) {
    if (cache == NULL || cache->magic != dory_jit_block_cache_magic ||
        value_out == NULL || !dory_jit_block_key_is_valid(key)) {
        return EINVAL;
    }
    const size_t mask = cache->capacity - 1;
    size_t index = (size_t)dory_jit_block_key_hash(key) & mask;
    for (size_t probe = 0; probe < cache->capacity; probe++) {
        const dory_jit_block_cache_entry entry = cache->entries[index];
        if (entry.state == dory_jit_block_cache_empty) {
            return ENOENT;
        }
        if (entry.state == dory_jit_block_cache_occupied &&
            dory_jit_block_key_equal(entry.key, key)) {
            *value_out = entry.value;
            return 0;
        }
        index = (index + 1) & mask;
    }
    return ENOENT;
}

int dory_jit_block_cache_insert(
    dory_jit_block_cache *cache,
    dory_jit_block_key key,
    uint64_t value,
    uint64_t *replaced_value_out
) {
    if (cache == NULL || cache->magic != dory_jit_block_cache_magic || value == 0 ||
        !dory_jit_block_key_is_valid(key)) {
        return EINVAL;
    }
    if (replaced_value_out != NULL) {
        *replaced_value_out = 0;
    }
    if (cache->count + cache->tombstone_count + 1 > (cache->capacity * 7) / 10) {
        if (cache->capacity > SIZE_MAX / 2) {
            return EOVERFLOW;
        }
        const int resize = dory_jit_block_cache_resize(cache, cache->capacity * 2);
        if (resize != 0) {
            return resize;
        }
    }
    return dory_jit_block_cache_insert_without_resize(
        cache,
        key,
        value,
        replaced_value_out
    );
}

int dory_jit_block_cache_remove(
    dory_jit_block_cache *cache,
    dory_jit_block_key key,
    uint64_t *removed_value_out
) {
    if (cache == NULL || cache->magic != dory_jit_block_cache_magic ||
        !dory_jit_block_key_is_valid(key)) {
        return EINVAL;
    }
    if (removed_value_out != NULL) {
        *removed_value_out = 0;
    }
    const size_t mask = cache->capacity - 1;
    size_t index = (size_t)dory_jit_block_key_hash(key) & mask;
    for (size_t probe = 0; probe < cache->capacity; probe++) {
        dory_jit_block_cache_entry *entry = &cache->entries[index];
        if (entry->state == dory_jit_block_cache_empty) {
            return ENOENT;
        }
        if (entry->state == dory_jit_block_cache_occupied &&
            dory_jit_block_key_equal(entry->key, key)) {
            if (removed_value_out != NULL) {
                *removed_value_out = entry->value;
            }
            memset(&entry->key, 0, sizeof(entry->key));
            entry->value = 0;
            entry->state = dory_jit_block_cache_tombstone;
            cache->count--;
            cache->tombstone_count++;
            return 0;
        }
        index = (index + 1) & mask;
    }
    return ENOENT;
}

void dory_jit_block_cache_clear(dory_jit_block_cache *cache) {
    if (cache == NULL || cache->magic != dory_jit_block_cache_magic) {
        return;
    }
    memset(cache->entries, 0, cache->capacity * sizeof(*cache->entries));
    cache->count = 0;
    cache->tombstone_count = 0;
}

int dory_jit_tlb_create(size_t entry_count, dory_jit_tlb **tlb_out) {
    if (tlb_out == NULL || entry_count == 0 || (entry_count & (entry_count - 1)) != 0) {
        return EINVAL;
    }
    *tlb_out = NULL;
    if (entry_count > SIZE_MAX / dory_jit_tlb_access_count ||
        entry_count * dory_jit_tlb_access_count > SIZE_MAX / sizeof(dory_jit_tlb_entry)) {
        return EOVERFLOW;
    }
    dory_jit_tlb *tlb = calloc(1, sizeof(*tlb));
    if (tlb == NULL) {
        return ENOMEM;
    }
    tlb->entries = calloc(
        entry_count * dory_jit_tlb_access_count,
        sizeof(dory_jit_tlb_entry)
    );
    if (tlb->entries == NULL) {
        free(tlb);
        return ENOMEM;
    }
    tlb->magic = dory_jit_tlb_magic;
    tlb->entry_count = entry_count;
    *tlb_out = tlb;
    return 0;
}

void dory_jit_tlb_destroy(dory_jit_tlb *tlb) {
    if (tlb == NULL || tlb->magic != dory_jit_tlb_magic) {
        return;
    }
    tlb->magic = 0;
    free(tlb->entries);
    free(tlb);
}

size_t dory_jit_tlb_entry_count(const dory_jit_tlb *tlb) {
    return tlb != NULL && tlb->magic == dory_jit_tlb_magic ? tlb->entry_count : 0;
}

size_t dory_jit_tlb_entry_size(void) {
    return sizeof(dory_jit_tlb_entry);
}

dory_jit_tlb_entry *dory_jit_tlb_entries(
    dory_jit_tlb *tlb,
    dory_jit_tlb_access access
) {
    if (tlb == NULL || tlb->magic != dory_jit_tlb_magic ||
        !dory_jit_tlb_access_is_valid(access)) {
        return NULL;
    }
    return tlb->entries + ((size_t)access * tlb->entry_count);
}

uint64_t *dory_jit_tlb_inline_hit_counter(
    dory_jit_tlb *tlb,
    dory_jit_tlb_access access
) {
    if (tlb == NULL || tlb->magic != dory_jit_tlb_magic ||
        !dory_jit_tlb_access_is_valid(access)) {
        return NULL;
    }
    return &tlb->inline_hit_counts[access];
}

#define DORY_JIT_TLB_COUNTER_GETTER(name, field) \
    uint64_t name(const dory_jit_tlb *tlb, dory_jit_tlb_access access) { \
        if (tlb == NULL || tlb->magic != dory_jit_tlb_magic || \
            !dory_jit_tlb_access_is_valid(access)) { \
            return 0; \
        } \
        return tlb->field[access]; \
    }

DORY_JIT_TLB_COUNTER_GETTER(dory_jit_tlb_inline_hit_count, inline_hit_counts)
DORY_JIT_TLB_COUNTER_GETTER(dory_jit_tlb_miss_count, miss_counts)
DORY_JIT_TLB_COUNTER_GETTER(dory_jit_tlb_fill_count, fill_counts)
DORY_JIT_TLB_COUNTER_GETTER(dory_jit_tlb_page_fault_count, page_fault_counts)
DORY_JIT_TLB_COUNTER_GETTER(dory_jit_tlb_fallback_count, fallback_counts)

#undef DORY_JIT_TLB_COUNTER_GETTER

int dory_jit_tlb_lookup(
    const dory_jit_tlb *tlb,
    dory_jit_tlb_access access,
    uint64_t linear_address,
    uint64_t tag,
    uint64_t *host_address_out
) {
    if (tlb == NULL || tlb->magic != dory_jit_tlb_magic ||
        !dory_jit_tlb_access_is_valid(access) || tag == 0 || host_address_out == NULL) {
        return EINVAL;
    }
    const dory_jit_tlb_entry *entries =
        tlb->entries + ((size_t)access * tlb->entry_count);
    const dory_jit_tlb_entry entry = entries[dory_jit_tlb_index(tlb, linear_address)];
    if (entry.tag != tag) {
        return ENOENT;
    }
    *host_address_out = linear_address + entry.host_address_delta;
    return 0;
}

int dory_jit_tlb_fill(
    dory_jit_tlb *tlb,
    dory_jit_tlb_access access,
    uint64_t linear_address,
    uint64_t tag,
    uint64_t host_address
) {
    dory_jit_tlb_entry *entries = dory_jit_tlb_entries(tlb, access);
    if (entries == NULL || tag == 0) {
        return EINVAL;
    }
    dory_jit_tlb_entry *entry = &entries[dory_jit_tlb_index(tlb, linear_address)];
    entry->host_address_delta = host_address - linear_address;
    entry->tag = tag;
    return 0;
}

void dory_jit_tlb_invalidate_page(dory_jit_tlb *tlb, uint64_t linear_address) {
    if (tlb == NULL || tlb->magic != dory_jit_tlb_magic) {
        return;
    }
    const size_t index = dory_jit_tlb_index(tlb, linear_address);
    for (size_t access = 0; access < dory_jit_tlb_access_count; access++) {
        tlb->entries[access * tlb->entry_count + index].tag = 0;
    }
}

void dory_jit_tlb_invalidate_all(dory_jit_tlb *tlb) {
    if (tlb == NULL || tlb->magic != dory_jit_tlb_magic) {
        return;
    }
    memset(
        tlb->entries,
        0,
        tlb->entry_count * dory_jit_tlb_access_count * sizeof(dory_jit_tlb_entry)
    );
}

int dory_jit_tlb_resolve(
    dory_jit_tlb *tlb,
    dory_jit_tlb_access access,
    uint64_t linear_address,
    uint32_t byte_count,
    uint64_t address_space_generation,
    uint64_t host_address_space_base,
    uint64_t host_address_space_byte_count,
    void *memory_context,
    dory_jit_tlb_resolution *resolution_out
) {
    if (tlb == NULL || tlb->magic != dory_jit_tlb_magic ||
        !dory_jit_tlb_access_is_valid(access) || byte_count == 0 ||
        memory_context == NULL || resolution_out == NULL) {
        return EINVAL;
    }
    memset(resolution_out, 0, sizeof(*resolution_out));
    const uint64_t tag = dory_jit_tlb_tag(linear_address, address_space_generation);
    if (tag == 0) {
        return EINVAL;
    }
    if ((uint64_t)byte_count > UINT64_C(4096) - (linear_address & UINT64_C(4095))) {
        tlb->fallback_counts[access]++;
        resolution_out->status = DORY_JIT_TLB_RESOLUTION_FALLBACK;
        return 0;
    }
    uint64_t host_address = 0;
    const int lookup = dory_jit_tlb_lookup(
        tlb,
        access,
        linear_address,
        tag,
        &host_address
    );
    if (lookup == 0) {
        // A stale entry whose tag survived an invalidation, or a corrupted entry with a
        // matching tag but wrong delta, must not reach a direct access. Validate the host
        // span lies within the host address space before accepting the hit; otherwise
        // fall through to the translation walk and refill with a validated address.
        if (host_address >= host_address_space_base &&
            host_address - host_address_space_base <= host_address_space_byte_count &&
            (uint64_t)byte_count <= host_address_space_byte_count -
                (host_address - host_address_space_base)) {
            tlb->inline_hit_counts[access]++;
            resolution_out->host_address = host_address;
            resolution_out->status = DORY_JIT_TLB_RESOLUTION_HIT;
            return 0;
        }
        tlb->miss_counts[access]++;
    } else if (lookup != ENOENT) {
        return lookup;
    } else {
        tlb->miss_counts[access]++;
    }

    uint64_t host_address_space_offset = 0;
    uint64_t fault_address = 0;
    uint32_t fault_error_code = 0;
    const int32_t translation = dory_x86_jit_translate(
        memory_context,
        linear_address,
        (uint32_t)access,
        byte_count,
        &host_address_space_offset,
        &fault_address,
        &fault_error_code
    );
    if (translation == DORY_JIT_TLB_RESOLUTION_PAGE_FAULT) {
        tlb->page_fault_counts[access]++;
        resolution_out->fault_address = fault_address;
        resolution_out->fault_error_code = fault_error_code;
        resolution_out->status = DORY_JIT_TLB_RESOLUTION_PAGE_FAULT;
        return 0;
    }
    if (translation != DORY_JIT_TLB_RESOLUTION_FILLED ||
        host_address_space_offset > host_address_space_byte_count ||
        (uint64_t)byte_count > host_address_space_byte_count - host_address_space_offset ||
        host_address_space_base > UINT64_MAX - host_address_space_offset) {
        tlb->fallback_counts[access]++;
        resolution_out->status = DORY_JIT_TLB_RESOLUTION_FALLBACK;
        return 0;
    }
    host_address = host_address_space_base + host_address_space_offset;
    const int fill = dory_jit_tlb_fill(tlb, access, linear_address, tag, host_address);
    if (fill != 0) {
        return fill;
    }
    tlb->fill_counts[access]++;
    resolution_out->host_address = host_address;
    resolution_out->status = DORY_JIT_TLB_RESOLUTION_FILLED;
    return 0;
}

int dory_jit_tlb_resolve_from_context(
    const uint64_t *context,
    void *memory_context,
    uint32_t access,
    uint64_t linear_address,
    uint32_t byte_count,
    dory_jit_tlb_resolution *resolution_out
) {
    if (context == NULL || access > DORY_JIT_TLB_ACCESS_EXECUTE) {
        return EINVAL;
    }
    dory_jit_tlb *tlb = (dory_jit_tlb *)(uintptr_t)context[34];
    return dory_jit_tlb_resolve(
        tlb,
        (dory_jit_tlb_access)access,
        linear_address,
        byte_count,
        context[32],
        context[27],
        context[33],
        memory_context,
        resolution_out
    );
}

uintptr_t dory_jit_tlb_resolve_from_context_address(void) {
    union {
        int (*function)(
            const uint64_t *,
            void *,
            uint32_t,
            uint64_t,
            uint32_t,
            dory_jit_tlb_resolution *
        );
        uintptr_t address;
    } resolver = {.function = dory_jit_tlb_resolve_from_context};
    return resolver.address;
}

void dory_jit_atomic_lock(void) {
    (void)pthread_mutex_lock(&dory_jit_atomic_mutex);
}

void dory_jit_atomic_unlock(void) {
    (void)pthread_mutex_unlock(&dory_jit_atomic_mutex);
}

static uint64_t dory_jit_atomic_compare_exchange(
    void *host_address,
    uint64_t expected,
    uint64_t desired,
    uint32_t byte_count
) {
    switch (byte_count) {
        case 1: {
            uint8_t value = (uint8_t)expected;
            (void)__atomic_compare_exchange_n(
                (uint8_t *)host_address,
                &value,
                (uint8_t)desired,
                0,
                __ATOMIC_SEQ_CST,
                __ATOMIC_SEQ_CST
            );
            return value;
        }
        case 2: {
            uint16_t value = (uint16_t)expected;
            (void)__atomic_compare_exchange_n(
                (uint16_t *)host_address,
                &value,
                (uint16_t)desired,
                0,
                __ATOMIC_SEQ_CST,
                __ATOMIC_SEQ_CST
            );
            return value;
        }
        case 4: {
            uint32_t value = (uint32_t)expected;
            (void)__atomic_compare_exchange_n(
                (uint32_t *)host_address,
                &value,
                (uint32_t)desired,
                0,
                __ATOMIC_SEQ_CST,
                __ATOMIC_SEQ_CST
            );
            return value;
        }
        default: {
            uint64_t value = expected;
            (void)__atomic_compare_exchange_n(
                (uint64_t *)host_address,
                &value,
                desired,
                0,
                __ATOMIC_SEQ_CST,
                __ATOMIC_SEQ_CST
            );
            return value;
        }
    }
}

int dory_jit_atomic_compare_exchange_from_context(
    const uint64_t *context,
    void *memory_context,
    uint64_t linear_address,
    uint64_t expected,
    uint64_t desired,
    uint32_t byte_count,
    uint64_t *observed_out
) {
    if (context == NULL || observed_out == NULL ||
        (byte_count != 1 && byte_count != 2 && byte_count != 4 && byte_count != 8)) {
        return DORY_JIT_ATOMIC_RESOLUTION_ERROR;
    }
    if ((linear_address & UINT64_C(0xfff)) > UINT64_C(4096) - byte_count) {
        return DORY_JIT_ATOMIC_RESOLUTION_FALLBACK;
    }

    dory_jit_tlb_resolution resolution = {0};
    const int result = dory_jit_tlb_resolve_from_context(
        context,
        memory_context,
        DORY_JIT_TLB_ACCESS_WRITE,
        linear_address,
        byte_count,
        &resolution
    );
    if (result != 0) {
        return DORY_JIT_ATOMIC_RESOLUTION_ERROR;
    }
    if (resolution.status == DORY_JIT_TLB_RESOLUTION_PAGE_FAULT) {
        return DORY_JIT_ATOMIC_RESOLUTION_PAGE_FAULT;
    }
    if (resolution.status == DORY_JIT_TLB_RESOLUTION_FALLBACK ||
        (resolution.host_address & (byte_count - 1)) != 0) {
        return DORY_JIT_ATOMIC_RESOLUTION_FALLBACK;
    }

    *observed_out = dory_jit_atomic_compare_exchange(
        (void *)(uintptr_t)resolution.host_address,
        expected,
        desired,
        byte_count
    );
    return DORY_JIT_ATOMIC_RESOLUTION_SUCCESS;
}

uintptr_t dory_jit_atomic_compare_exchange_from_context_address(void) {
    union {
        int (*function)(
            const uint64_t *,
            void *,
            uint64_t,
            uint64_t,
            uint64_t,
            uint32_t,
            uint64_t *
        );
        uintptr_t address;
    } resolver = {.function = dory_jit_atomic_compare_exchange_from_context};
    return resolver.address;
}

static uint64_t dory_jit_atomic_exchange(
    void *host_address,
    uint64_t value,
    uint32_t byte_count
) {
    switch (byte_count) {
        case 1:
            return __atomic_exchange_n(
                (uint8_t *)host_address,
                (uint8_t)value,
                __ATOMIC_SEQ_CST
            );
        case 2:
            return __atomic_exchange_n(
                (uint16_t *)host_address,
                (uint16_t)value,
                __ATOMIC_SEQ_CST
            );
        case 4:
            return __atomic_exchange_n(
                (uint32_t *)host_address,
                (uint32_t)value,
                __ATOMIC_SEQ_CST
            );
        default:
            return __atomic_exchange_n(
                (uint64_t *)host_address,
                value,
                __ATOMIC_SEQ_CST
            );
    }
}

int dory_jit_atomic_exchange_from_context(
    const uint64_t *context,
    void *memory_context,
    uint64_t linear_address,
    uint64_t value,
    uint32_t byte_count,
    uint64_t *observed_out
) {
    if (context == NULL || observed_out == NULL ||
        (byte_count != 1 && byte_count != 2 && byte_count != 4 && byte_count != 8)) {
        return DORY_JIT_ATOMIC_RESOLUTION_ERROR;
    }
    if ((linear_address & UINT64_C(0xfff)) > UINT64_C(4096) - byte_count) {
        return DORY_JIT_ATOMIC_RESOLUTION_FALLBACK;
    }

    dory_jit_tlb_resolution resolution = {0};
    const int result = dory_jit_tlb_resolve_from_context(
        context,
        memory_context,
        DORY_JIT_TLB_ACCESS_WRITE,
        linear_address,
        byte_count,
        &resolution
    );
    if (result != 0) {
        return DORY_JIT_ATOMIC_RESOLUTION_ERROR;
    }
    if (resolution.status == DORY_JIT_TLB_RESOLUTION_PAGE_FAULT) {
        return DORY_JIT_ATOMIC_RESOLUTION_PAGE_FAULT;
    }
    if (resolution.status == DORY_JIT_TLB_RESOLUTION_FALLBACK ||
        (resolution.host_address & (byte_count - 1)) != 0) {
        return DORY_JIT_ATOMIC_RESOLUTION_FALLBACK;
    }

    *observed_out = dory_jit_atomic_exchange(
        (void *)(uintptr_t)resolution.host_address,
        value,
        byte_count
    );
    return DORY_JIT_ATOMIC_RESOLUTION_SUCCESS;
}

uintptr_t dory_jit_atomic_exchange_from_context_address(void) {
    union {
        int (*function)(
            const uint64_t *,
            void *,
            uint64_t,
            uint64_t,
            uint32_t,
            uint64_t *
        );
        uintptr_t address;
    } resolver = {.function = dory_jit_atomic_exchange_from_context};
    return resolver.address;
}

static uint64_t dory_jit_atomic_fetch_add(
    void *host_address,
    uint64_t value,
    uint32_t byte_count
) {
    switch (byte_count) {
        case 1:
            return __atomic_fetch_add(
                (uint8_t *)host_address,
                (uint8_t)value,
                __ATOMIC_SEQ_CST
            );
        case 2:
            return __atomic_fetch_add(
                (uint16_t *)host_address,
                (uint16_t)value,
                __ATOMIC_SEQ_CST
            );
        case 4:
            return __atomic_fetch_add(
                (uint32_t *)host_address,
                (uint32_t)value,
                __ATOMIC_SEQ_CST
            );
        default:
            return __atomic_fetch_add(
                (uint64_t *)host_address,
                value,
                __ATOMIC_SEQ_CST
            );
    }
}

int dory_jit_atomic_fetch_add_from_context(
    const uint64_t *context,
    void *memory_context,
    uint64_t linear_address,
    uint64_t value,
    uint32_t byte_count,
    uint64_t *observed_out
) {
    if (context == NULL || observed_out == NULL ||
        (byte_count != 1 && byte_count != 2 && byte_count != 4 && byte_count != 8)) {
        return DORY_JIT_ATOMIC_RESOLUTION_ERROR;
    }
    if ((linear_address & UINT64_C(0xfff)) > UINT64_C(4096) - byte_count) {
        return DORY_JIT_ATOMIC_RESOLUTION_FALLBACK;
    }

    dory_jit_tlb_resolution resolution = {0};
    const int result = dory_jit_tlb_resolve_from_context(
        context,
        memory_context,
        DORY_JIT_TLB_ACCESS_WRITE,
        linear_address,
        byte_count,
        &resolution
    );
    if (result != 0) {
        return DORY_JIT_ATOMIC_RESOLUTION_ERROR;
    }
    if (resolution.status == DORY_JIT_TLB_RESOLUTION_PAGE_FAULT) {
        return DORY_JIT_ATOMIC_RESOLUTION_PAGE_FAULT;
    }
    if (resolution.status == DORY_JIT_TLB_RESOLUTION_FALLBACK ||
        (resolution.host_address & (byte_count - 1)) != 0) {
        return DORY_JIT_ATOMIC_RESOLUTION_FALLBACK;
    }

    *observed_out = dory_jit_atomic_fetch_add(
        (void *)(uintptr_t)resolution.host_address,
        value,
        byte_count
    );
    return DORY_JIT_ATOMIC_RESOLUTION_SUCCESS;
}

uintptr_t dory_jit_atomic_fetch_add_from_context_address(void) {
    union {
        int (*function)(
            const uint64_t *,
            void *,
            uint64_t,
            uint64_t,
            uint32_t,
            uint64_t *
        );
        uintptr_t address;
    } resolver = {.function = dory_jit_atomic_fetch_add_from_context};
    return resolver.address;
}

#define DORY_JIT_ATOMIC_RMW_FOR_TYPE(type, host_address, value, operation) \
    switch (operation) { \
        case DORY_JIT_ATOMIC_RMW_ADD: \
            return __atomic_fetch_add((type *)(host_address), (type)(value), __ATOMIC_SEQ_CST); \
        case DORY_JIT_ATOMIC_RMW_SUBTRACT: \
            return __atomic_fetch_sub((type *)(host_address), (type)(value), __ATOMIC_SEQ_CST); \
        case DORY_JIT_ATOMIC_RMW_AND: \
            return __atomic_fetch_and((type *)(host_address), (type)(value), __ATOMIC_SEQ_CST); \
        case DORY_JIT_ATOMIC_RMW_OR: \
            return __atomic_fetch_or((type *)(host_address), (type)(value), __ATOMIC_SEQ_CST); \
        case DORY_JIT_ATOMIC_RMW_XOR: \
            return __atomic_fetch_xor((type *)(host_address), (type)(value), __ATOMIC_SEQ_CST); \
        default: { \
            type observed = __atomic_load_n((type *)(host_address), __ATOMIC_SEQ_CST); \
            type expected; \
            do { \
                expected = observed; \
            } while (!__atomic_compare_exchange_n( \
                (type *)(host_address), \
                &observed, \
                (type)(0 - expected), \
                0, \
                __ATOMIC_SEQ_CST, \
                __ATOMIC_SEQ_CST \
            )); \
            return expected; \
        } \
    }

static uint64_t dory_jit_atomic_rmw(
    void *host_address,
    uint64_t value,
    uint32_t byte_count,
    uint32_t operation
) {
    switch (byte_count) {
        case 1: {
            DORY_JIT_ATOMIC_RMW_FOR_TYPE(uint8_t, host_address, value, operation)
        }
        case 2: {
            DORY_JIT_ATOMIC_RMW_FOR_TYPE(uint16_t, host_address, value, operation)
        }
        case 4: {
            DORY_JIT_ATOMIC_RMW_FOR_TYPE(uint32_t, host_address, value, operation)
        }
        default: {
            DORY_JIT_ATOMIC_RMW_FOR_TYPE(uint64_t, host_address, value, operation)
        }
    }
}

#undef DORY_JIT_ATOMIC_RMW_FOR_TYPE

int dory_jit_atomic_rmw_from_context(
    const uint64_t *context,
    void *memory_context,
    uint64_t linear_address,
    uint64_t value,
    uint32_t byte_count,
    uint32_t operation,
    uint64_t *observed_out
) {
    if (context == NULL || observed_out == NULL ||
        (byte_count != 1 && byte_count != 2 && byte_count != 4 && byte_count != 8) ||
        operation > DORY_JIT_ATOMIC_RMW_NEGATE) {
        return DORY_JIT_ATOMIC_RESOLUTION_ERROR;
    }
    if ((linear_address & UINT64_C(0xfff)) > UINT64_C(4096) - byte_count) {
        return DORY_JIT_ATOMIC_RESOLUTION_FALLBACK;
    }

    dory_jit_tlb_resolution resolution = {0};
    const int result = dory_jit_tlb_resolve_from_context(
        context,
        memory_context,
        DORY_JIT_TLB_ACCESS_WRITE,
        linear_address,
        byte_count,
        &resolution
    );
    if (result != 0) {
        return DORY_JIT_ATOMIC_RESOLUTION_ERROR;
    }
    if (resolution.status == DORY_JIT_TLB_RESOLUTION_PAGE_FAULT) {
        return DORY_JIT_ATOMIC_RESOLUTION_PAGE_FAULT;
    }
    if (resolution.status == DORY_JIT_TLB_RESOLUTION_FALLBACK ||
        (resolution.host_address & (byte_count - 1)) != 0) {
        return DORY_JIT_ATOMIC_RESOLUTION_FALLBACK;
    }

    *observed_out = dory_jit_atomic_rmw(
        (void *)(uintptr_t)resolution.host_address,
        value,
        byte_count,
        operation
    );
    return DORY_JIT_ATOMIC_RESOLUTION_SUCCESS;
}

uintptr_t dory_jit_atomic_rmw_from_context_address(void) {
    union {
        int (*function)(
            const uint64_t *,
            void *,
            uint64_t,
            uint64_t,
            uint32_t,
            uint32_t,
            uint64_t *
        );
        uintptr_t address;
    } resolver = {.function = dory_jit_atomic_rmw_from_context};
    return resolver.address;
}

int dory_jit_atomic_compare_exchange_pair_from_context(
    const uint64_t *context,
    void *memory_context,
    uint64_t linear_address,
    uint32_t byte_count,
    dory_jit_atomic_pair_values *values
) {
    if (context == NULL || values == NULL || (byte_count != 8 && byte_count != 16)) {
        return DORY_JIT_ATOMIC_RESOLUTION_ERROR;
    }
    if ((linear_address & UINT64_C(0xfff)) > UINT64_C(4096) - byte_count) {
        return DORY_JIT_ATOMIC_RESOLUTION_FALLBACK;
    }

    dory_jit_tlb_resolution resolution = {0};
    const int result = dory_jit_tlb_resolve_from_context(
        context,
        memory_context,
        DORY_JIT_TLB_ACCESS_WRITE,
        linear_address,
        byte_count,
        &resolution
    );
    if (result != 0) {
        return DORY_JIT_ATOMIC_RESOLUTION_ERROR;
    }
    if (resolution.status == DORY_JIT_TLB_RESOLUTION_PAGE_FAULT) {
        return DORY_JIT_ATOMIC_RESOLUTION_PAGE_FAULT;
    }
    if (resolution.status == DORY_JIT_TLB_RESOLUTION_FALLBACK ||
        (resolution.host_address & (byte_count - 1)) != 0) {
        return DORY_JIT_ATOMIC_RESOLUTION_FALLBACK;
    }

#if !defined(__aarch64__)
    if (byte_count == 16) {
        return DORY_JIT_ATOMIC_RESOLUTION_FALLBACK;
    }
#endif

    dory_jit_atomic_lock();
    if (byte_count == 8) {
        const uint64_t expected =
            (uint64_t)(uint32_t)values->expected_low |
            ((uint64_t)(uint32_t)values->expected_high << 32);
        const uint64_t desired =
            (uint64_t)(uint32_t)values->desired_low |
            ((uint64_t)(uint32_t)values->desired_high << 32);
        const uint64_t observed = dory_jit_atomic_compare_exchange(
            (void *)(uintptr_t)resolution.host_address,
            expected,
            desired,
            8
        );
        values->observed_low = (uint32_t)observed;
        values->observed_high = observed >> 32;
    }
#if defined(__aarch64__)
    else {
        // The mutex serializes cooperating interpreter helpers, but ordinary generated
        // loads/stores and DMA do not take it. CMPXCHG16B therefore needs one hardware
        // atomic operation over the entire aligned operand. In particular, writing back
        // two separately observed halves on mismatch can overwrite a concurrent store.
        // Do not permit a compiler/library lock-based implementation of this operation.
        _Static_assert(__atomic_always_lock_free(16, 0), "128-bit CAS must be lock-free");
        typedef unsigned __int128 dory_atomic_uint128;
        dory_atomic_uint128 observed =
            (dory_atomic_uint128)values->expected_low |
            ((dory_atomic_uint128)values->expected_high << 64);
        const dory_atomic_uint128 desired =
            (dory_atomic_uint128)values->desired_low |
            ((dory_atomic_uint128)values->desired_high << 64);
        (void)__atomic_compare_exchange_n(
            (dory_atomic_uint128 *)(uintptr_t)resolution.host_address,
            &observed,
            desired,
            0,
            __ATOMIC_SEQ_CST,
            __ATOMIC_SEQ_CST
        );
        values->observed_low = (uint64_t)observed;
        values->observed_high = (uint64_t)(observed >> 64);
    }
#endif
    dory_jit_atomic_unlock();
    return DORY_JIT_ATOMIC_RESOLUTION_SUCCESS;
}

uintptr_t dory_jit_atomic_compare_exchange_pair_from_context_address(void) {
    union {
        int (*function)(
            const uint64_t *,
            void *,
            uint64_t,
            uint32_t,
            dory_jit_atomic_pair_values *
        );
        uintptr_t address;
    } resolver = {.function = dory_jit_atomic_compare_exchange_pair_from_context};
    return resolver.address;
}

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
        PROT_READ | PROT_WRITE | PROT_EXEC,
        MAP_PRIVATE | MAP_ANON | MAP_JIT,
        -1,
        0
    );
    if (reservation == MAP_FAILED) {
        return errno;
    }
    uint8_t *requested_code = (uint8_t *)reservation + page_size;
    // Keep code and guards in one indivisible mapping. The former two-mapping construction
    // temporarily exposed the code span as an unmapped hole, allowing an unrelated concurrent
    // mmap to claim it before cleanup unmapped the complete reservation.
    void *leading_guard = mmap(
        reservation,
        page_size,
        PROT_NONE,
        MAP_PRIVATE | MAP_ANON | MAP_FIXED,
        -1,
        0
    );
    if (leading_guard == MAP_FAILED) {
        const int result = errno;
        munmap(reservation, reservation_size);
        return result;
    }
    void *trailing_guard = mmap(
        requested_code + capacity,
        page_size,
        PROT_NONE,
        MAP_PRIVATE | MAP_ANON | MAP_FIXED,
        -1,
        0
    );
    if (trailing_guard == MAP_FAILED) {
        const int result = errno;
        munmap(reservation, reservation_size);
        return result;
    }
    void *code = requested_code;
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

int dory_jit_region_patch_branch(
    dory_jit_region *region,
    size_t slot_offset,
    size_t target_offset
) {
    if (region == NULL || region->magic != dory_jit_region_magic ||
        (slot_offset & 3) != 0 || (target_offset & 3) != 0 ||
        slot_offset >= region->capacity || target_offset >= region->capacity) {
        return EINVAL;
    }
    int64_t byte_delta;
    if (target_offset >= slot_offset) {
        const size_t magnitude = target_offset - slot_offset;
        if (magnitude > INT64_MAX) {
            return ERANGE;
        }
        byte_delta = (int64_t)magnitude;
    } else {
        const size_t magnitude = slot_offset - target_offset;
        if (magnitude > (size_t)INT64_MAX + 1) {
            return ERANGE;
        }
        byte_delta = magnitude == (size_t)INT64_MAX + 1
            ? INT64_MIN
            : -(int64_t)magnitude;
    }
    if ((byte_delta & 3) != 0) {
        return EINVAL;
    }
    const int64_t word_delta = byte_delta / 4;
    if (word_delta < -(INT64_C(1) << 25) || word_delta >= (INT64_C(1) << 25)) {
        return ERANGE;
    }
    const uint32_t instruction =
        UINT32_C(0x14000000) | ((uint32_t)word_delta & UINT32_C(0x03ffffff));
    return dory_jit_region_publish(
        region,
        slot_offset,
        (const uint8_t *)&instruction,
        sizeof(instruction)
    );
}

typedef struct dory_jit_tracked_memory_callbacks {
    dory_jit_memory_read_function read;
    dory_jit_memory_write_function write;
    dory_jit_memory_compare_exchange_function compare_exchange;
    dory_jit_memory_synchronize_function synchronize;
} dory_jit_tracked_memory_callbacks;

static _Thread_local uintptr_t dory_jit_memory_callback_return_pc = 0;
static _Thread_local dory_jit_tracked_memory_callbacks *dory_jit_active_memory_callbacks = NULL;

#define DORY_JIT_CAPTURE_CALLBACK_RETURN_PC() \
    ((uintptr_t)__builtin_extract_return_addr(__builtin_return_address(0)))

__attribute__((noinline))
static uint64_t dory_jit_tracked_memory_read(
    void *opaque,
    uint64_t address,
    uint32_t byte_count
) {
    dory_jit_memory_callback_return_pc = DORY_JIT_CAPTURE_CALLBACK_RETURN_PC();
    dory_jit_tracked_memory_callbacks *callbacks = dory_jit_active_memory_callbacks;
    return callbacks == NULL ? 0 : callbacks->read(opaque, address, byte_count);
}

__attribute__((noinline))
static void dory_jit_tracked_memory_write(
    void *opaque,
    uint64_t address,
    uint64_t value,
    uint32_t byte_count
) {
    dory_jit_memory_callback_return_pc = DORY_JIT_CAPTURE_CALLBACK_RETURN_PC();
    dory_jit_tracked_memory_callbacks *callbacks = dory_jit_active_memory_callbacks;
    if (callbacks != NULL) {
        callbacks->write(opaque, address, value, byte_count);
    }
}

__attribute__((noinline))
static int32_t dory_jit_tracked_memory_compare_exchange(
    void *opaque,
    uint64_t address,
    uint64_t expected,
    uint64_t desired,
    uint32_t byte_count,
    uint64_t *observed_out
) {
    dory_jit_memory_callback_return_pc = DORY_JIT_CAPTURE_CALLBACK_RETURN_PC();
    dory_jit_tracked_memory_callbacks *callbacks = dory_jit_active_memory_callbacks;
    if (callbacks == NULL) {
        return 0;
    }
    return callbacks->compare_exchange(
        opaque,
        address,
        expected,
        desired,
        byte_count,
        observed_out
    );
}

__attribute__((noinline))
static void dory_jit_tracked_memory_synchronize(void *opaque) {
    dory_jit_memory_callback_return_pc = DORY_JIT_CAPTURE_CALLBACK_RETURN_PC();
    dory_jit_tracked_memory_callbacks *callbacks = dory_jit_active_memory_callbacks;
    if (callbacks != NULL) {
        callbacks->synchronize(opaque);
    }
}

uintptr_t dory_jit_current_memory_callback_return_pc(void) {
    return dory_jit_memory_callback_return_pc;
}

int dory_jit_region_execute(
    const dory_jit_region *region,
    size_t offset,
    uint64_t *context,
    void *memory_context,
    dory_jit_memory_read_function memory_read,
    dory_jit_memory_write_function memory_write,
    dory_jit_memory_compare_exchange_function memory_compare_exchange,
    dory_jit_memory_synchronize_function memory_synchronize,
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
        dory_jit_memory_write_function,
        dory_jit_memory_compare_exchange_function,
        dory_jit_memory_synchronize_function
    );
    union {
        void *pointer;
        dory_jit_function function;
    } callable = {.pointer = entry};
    dory_jit_tracked_memory_callbacks callbacks = {
        .read = memory_read,
        .write = memory_write,
        .compare_exchange = memory_compare_exchange,
        .synchronize = memory_synchronize,
    };
    dory_jit_memory_callback_return_pc = 0;
    dory_jit_tracked_memory_callbacks *previous_callbacks = dory_jit_active_memory_callbacks;
    dory_jit_active_memory_callbacks = &callbacks;
    *exit_code_out = callable.function(
        context,
        memory_context,
        dory_jit_tracked_memory_read,
        dory_jit_tracked_memory_write,
        dory_jit_tracked_memory_compare_exchange,
        dory_jit_tracked_memory_synchronize
    );
    dory_jit_active_memory_callbacks = previous_callbacks;
    return 0;
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
        dory_jit_memory_write_function,
        dory_jit_memory_compare_exchange_function,
        dory_jit_memory_synchronize_function
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
        exit_code = callable.function(context, NULL, NULL, NULL, NULL, NULL);
        if (exit_code == dory_jit_exit_pending_work) {
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
int dory_jit_region_patch_branch(
    dory_jit_region *region,
    size_t slot_offset,
    size_t target_offset
) {
    (void)region;
    (void)slot_offset;
    (void)target_offset;
    return ENOTSUP;
}
int dory_jit_region_execute(
    const dory_jit_region *region,
    size_t offset,
    uint64_t *context,
    void *memory_context,
    dory_jit_memory_read_function memory_read,
    dory_jit_memory_write_function memory_write,
    dory_jit_memory_compare_exchange_function memory_compare_exchange,
    dory_jit_memory_synchronize_function memory_synchronize,
    uint32_t *exit_code_out
) {
    (void)region;
    (void)offset;
    (void)context;
    (void)memory_context;
    (void)memory_read;
    (void)memory_write;
    (void)memory_compare_exchange;
    (void)memory_synchronize;
    (void)exit_code_out;
    return ENOTSUP;
}
uintptr_t dory_jit_current_memory_callback_return_pc(void) {
    return 0;
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
