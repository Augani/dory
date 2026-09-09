#ifndef DORY_PLATFORM_C_H
#define DORY_PLATFORM_C_H

#include <stdint.h>

uint8_t dory_atomic_u8_load_acquire(const uint8_t *value);
void dory_atomic_u8_store_release(uint8_t *value, uint8_t desired);
uint64_t dory_atomic_u64_load_relaxed(const uint64_t *value);
void dory_atomic_u64_increment_saturating(uint64_t *value);

int dory_install_sigcont_generation_tracker(void);
uint32_t dory_sigcont_generation(void);

#endif
