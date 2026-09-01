#ifndef DORY_JIT_RUNTIME_C_H
#define DORY_JIT_RUNTIME_C_H

#include <stddef.h>
#include <stdint.h>

typedef struct dory_jit_region dory_jit_region;
typedef struct dory_jit_read_tlb dory_jit_read_tlb;
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

typedef struct dory_jit_read_tlb_metrics {
    uint64_t hit_count;
    uint64_t miss_count;
    uint64_t slow_path_count;
} dory_jit_read_tlb_metrics;

int dory_jit_read_tlb_create(dory_jit_read_tlb **tlb_out);
void dory_jit_read_tlb_destroy(dory_jit_read_tlb *tlb);
void dory_jit_read_tlb_invalidate_all(dory_jit_read_tlb *tlb);
void dory_jit_read_tlb_invalidate(dory_jit_read_tlb *tlb, uint64_t linear_address);
int dory_jit_read_tlb_install(
    dory_jit_read_tlb *tlb,
    uint64_t linear_address,
    const void *host_page
);
void dory_jit_read_tlb_get_metrics(
    const dory_jit_read_tlb *tlb,
    dory_jit_read_tlb_metrics *metrics_out
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
    uint32_t *exit_code_out
);
int dory_jit_region_execute_with_read_tlb(
    const dory_jit_region *region,
    size_t offset,
    uint64_t *context,
    dory_jit_read_tlb *read_tlb,
    void *slow_memory_context,
    dory_jit_memory_read_function slow_memory_read,
    dory_jit_memory_write_function slow_memory_write,
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
