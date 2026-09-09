#include "DoryPlatformC.h"

#include <signal.h>
#include <string.h>
#include <time.h>

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

uint64_t dory_thread_cpu_time_nanoseconds(void) {
    struct timespec value;
    if (clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value) != 0) {
        return 0;
    }
    return (uint64_t)value.tv_sec * UINT64_C(1000000000) + (uint64_t)value.tv_nsec;
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
