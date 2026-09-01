#ifndef DORY_PLATFORM_C_H
#define DORY_PLATFORM_C_H

#include <stdint.h>

uint8_t dory_atomic_u8_load_acquire(const uint8_t *value);
void dory_atomic_u8_store_release(uint8_t *value, uint8_t desired);

int dory_install_sigcont_generation_tracker(void);
uint32_t dory_sigcont_generation(void);

#endif
