#ifndef DORY_JIT_RUNTIME_C_H
#define DORY_JIT_RUNTIME_C_H

#include <stddef.h>
#include <stdint.h>

typedef struct dory_jit_region dory_jit_region;

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
    uint32_t *exit_code_out
);

#endif
