#include "DoryJITRuntimeC.h"
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
extern uint64_t dory_test_ordinary_writer(void *, uint8_t *, uint64_t *);
struct shared { void *memory; _Atomic uint8_t stop; uint64_t count; uint64_t overwritten; };
static void *write_thread(void *opaque) {
    struct shared *s = opaque;
    s->overwritten = dory_test_ordinary_writer(s->memory, (uint8_t *)&s->stop, &s->count);
    return NULL;
}
int main(void) {
    struct shared s = {0};
    if (posix_memalign(&s.memory, 4096, 4096) != 0) return 2;
    ((uint64_t *)s.memory)[0] = 0;
    ((uint64_t *)s.memory)[1] = 1;
    dory_jit_tlb *tlb = NULL;
    if (dory_jit_tlb_create(16, &tlb) != 0) return 3;
    if (dory_jit_tlb_fill(tlb, DORY_JIT_TLB_ACCESS_WRITE, 0, 1, (uintptr_t)s.memory) != 0) return 4;
    uint64_t context[128] = {0};
    context[27] = (uintptr_t)s.memory;
    context[32] = 1;
    context[33] = 4096;
    context[34] = (uintptr_t)tlb;
    pthread_t writer;
    if (pthread_create(&writer, NULL, write_thread, &s) != 0) return 5;
    uint64_t bad = 0;
    for (unsigned i = 0; i < 500000; i++) {
        dory_jit_atomic_pair_values values = {.desired_low = UINT64_MAX, .desired_high = UINT64_MAX};
        const int status = dory_jit_atomic_compare_exchange_pair_from_context(context, s.memory, 0, 16, &values);
        if (status != DORY_JIT_ATOMIC_RESOLUTION_SUCCESS || values.observed_high != 1) bad++;
    }
    atomic_store_explicit(&s.stop, 1, memory_order_release);
    pthread_join(writer, NULL);
    printf("{\"casIterations\":500000,\"ordinaryStores\":%llu,\"overwrittenStores\":%llu,\"badResults\":%llu,\"finalMemory\":%llu}\n", s.count, s.overwritten, bad, ((uint64_t *)s.memory)[0]);
    dory_jit_tlb_destroy(tlb);
    free(s.memory);
    return s.overwritten != 0 || bad != 0;
}
