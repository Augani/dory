#if !defined(__arm64__)
#error "Dory Phase 0A native workload requires Apple silicon"
#endif

.text
.p2align 2
.globl _dory_phase0a_native_counter_loop
_dory_phase0a_native_counter_loop:
    mov x1, #0
1:
    add x1, x1, #1
    subs x0, x0, #1
    b.ne 1b
    mov x0, x1
    ret
