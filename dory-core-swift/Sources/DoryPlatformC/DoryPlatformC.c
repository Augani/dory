#include "DoryPlatformC.h"

uint8_t dory_atomic_u8_load_acquire(const uint8_t *value) {
    return __atomic_load_n(value, __ATOMIC_ACQUIRE);
}

void dory_atomic_u8_store_release(uint8_t *value, uint8_t desired) {
    __atomic_store_n(value, desired, __ATOMIC_RELEASE);
}
