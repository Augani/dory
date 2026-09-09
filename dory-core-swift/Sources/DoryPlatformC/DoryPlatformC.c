#include "DoryPlatformC.h"

#include <signal.h>
#include <string.h>

static volatile sig_atomic_t dory_sigcont_generation_value = 0;

static void dory_record_sigcont(int signal_number) {
    (void)signal_number;
    dory_sigcont_generation_value =
        dory_sigcont_generation_value == SIG_ATOMIC_MAX
            ? 0
            : dory_sigcont_generation_value + 1;
}

uint8_t dory_atomic_u8_load_acquire(const uint8_t *value) {
    return __atomic_load_n(value, __ATOMIC_ACQUIRE);
}

void dory_atomic_u8_store_release(uint8_t *value, uint8_t desired) {
    __atomic_store_n(value, desired, __ATOMIC_RELEASE);
}

uint64_t dory_atomic_u64_load_relaxed(const uint64_t *value) {
    return __atomic_load_n(value, __ATOMIC_RELAXED);
}

void dory_atomic_u64_increment_saturating(uint64_t *value) {
    uint64_t current = __atomic_load_n(value, __ATOMIC_RELAXED);
    while (current != UINT64_MAX &&
           !__atomic_compare_exchange_n(
               value, &current, current + 1, 1, __ATOMIC_RELAXED, __ATOMIC_RELAXED)) {}
}

int dory_install_sigcont_generation_tracker(void) {
    struct sigaction action;
    memset(&action, 0, sizeof(action));
    action.sa_handler = dory_record_sigcont;
    sigemptyset(&action.sa_mask);
    return sigaction(SIGCONT, &action, NULL);
}

uint32_t dory_sigcont_generation(void) {
    return (uint32_t)dory_sigcont_generation_value;
}
