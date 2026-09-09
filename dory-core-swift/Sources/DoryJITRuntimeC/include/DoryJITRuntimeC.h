#ifndef DORY_JIT_RUNTIME_C_H
#define DORY_JIT_RUNTIME_C_H

#include <stddef.h>
#include <stdint.h>

typedef struct dory_jit_region dory_jit_region;
typedef struct dory_jit_tlb dory_jit_tlb;

typedef enum dory_jit_tlb_access {
    DORY_JIT_TLB_ACCESS_READ = 0,
    DORY_JIT_TLB_ACCESS_WRITE = 1,
    DORY_JIT_TLB_ACCESS_EXECUTE = 2,
} dory_jit_tlb_access;

typedef struct dory_jit_tlb_entry {
    uint64_t tag;
    uint64_t host_address_delta;
} dory_jit_tlb_entry;

typedef enum dory_jit_tlb_resolution_status {
    DORY_JIT_TLB_RESOLUTION_HIT = 0,
    DORY_JIT_TLB_RESOLUTION_FILLED = 1,
    DORY_JIT_TLB_RESOLUTION_PAGE_FAULT = 2,
    DORY_JIT_TLB_RESOLUTION_FALLBACK = 3,
} dory_jit_tlb_resolution_status;

typedef struct dory_jit_tlb_resolution {
    uint64_t host_address;
    uint64_t fault_address;
    uint32_t fault_error_code;
    uint32_t status;
} dory_jit_tlb_resolution;
typedef uint64_t (*dory_jit_memory_read_function)(
    void *memory_context,
    uint64_t address,
    uint32_t byte_count
);
typedef void (*dory_jit_memory_write_function)(
    void *memory_context,
    uint64_t address,
    uint64_t value,
    uint32_t byte_count
);
typedef int32_t (*dory_jit_memory_compare_exchange_function)(
    void *memory_context,
    uint64_t address,
    uint64_t expected,
    uint64_t desired,
    uint32_t byte_count,
    uint64_t *observed_out
);

typedef void (*dory_jit_memory_synchronize_function)(void *memory_context);

int dory_jit_tlb_create(size_t entry_count, dory_jit_tlb **tlb_out);
void dory_jit_tlb_destroy(dory_jit_tlb *tlb);
size_t dory_jit_tlb_entry_count(const dory_jit_tlb *tlb);
size_t dory_jit_tlb_entry_size(void);
dory_jit_tlb_entry *dory_jit_tlb_entries(
    dory_jit_tlb *tlb,
    dory_jit_tlb_access access
);
uint64_t *dory_jit_tlb_inline_hit_counter(
    dory_jit_tlb *tlb,
    dory_jit_tlb_access access
);
uint64_t dory_jit_tlb_inline_hit_count(
    const dory_jit_tlb *tlb,
    dory_jit_tlb_access access
);
uint64_t dory_jit_tlb_miss_count(
    const dory_jit_tlb *tlb,
    dory_jit_tlb_access access
);
uint64_t dory_jit_tlb_fill_count(
    const dory_jit_tlb *tlb,
    dory_jit_tlb_access access
);
uint64_t dory_jit_tlb_page_fault_count(
    const dory_jit_tlb *tlb,
    dory_jit_tlb_access access
);
uint64_t dory_jit_tlb_fallback_count(
    const dory_jit_tlb *tlb,
    dory_jit_tlb_access access
);
int dory_jit_tlb_lookup(
    const dory_jit_tlb *tlb,
    dory_jit_tlb_access access,
    uint64_t linear_address,
    uint64_t tag,
    uint64_t *host_address_out
);
int dory_jit_tlb_fill(
    dory_jit_tlb *tlb,
    dory_jit_tlb_access access,
    uint64_t linear_address,
    uint64_t tag,
    uint64_t host_address
);
void dory_jit_tlb_invalidate_page(dory_jit_tlb *tlb, uint64_t linear_address);
void dory_jit_tlb_invalidate_all(dory_jit_tlb *tlb);
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
);
int dory_jit_tlb_resolve_from_context(
    const uint64_t *context,
    void *memory_context,
    uint32_t access,
    uint64_t linear_address,
    uint32_t byte_count,
    dory_jit_tlb_resolution *resolution_out
);
uintptr_t dory_jit_tlb_resolve_from_context_address(void);

// Implemented by DoryDBTX86 and called only through dory_jit_tlb_resolve's C boundary.
int32_t dory_x86_jit_translate(
    void *memory_context,
    uint64_t linear_address,
    uint32_t access,
    uint32_t byte_count,
    uint64_t *host_address_space_offset_out,
    uint64_t *fault_address_out,
    uint32_t *fault_error_code_out
);

int dory_jit_region_create(size_t minimum_capacity, dory_jit_region **region_out);
void dory_jit_region_destroy(dory_jit_region *region);
size_t dory_jit_region_capacity(const dory_jit_region *region);
void *dory_jit_region_entry(const dory_jit_region *region, size_t offset);
int dory_jit_region_publish(
    dory_jit_region *region,
    size_t offset,
    const uint8_t *bytes,
    size_t byte_count
);
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
);
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
);

#endif
