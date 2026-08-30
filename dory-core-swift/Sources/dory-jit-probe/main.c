#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <sched.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/wait.h>
#include <unistd.h>

#if defined(__aarch64__)

struct dory_jit_emission {
    void *destination;
    size_t capacity;
    uint16_t result;
    uint64_t generation;
};

static uintptr_t dory_code_start;
static uintptr_t dory_code_end;
static _Atomic uint64_t dory_published_generation;

static int dory_emit_probe(void *opaque_context) {
    struct dory_jit_emission *context = opaque_context;
    if (context == NULL || context->destination == NULL ||
        context->capacity < 2 * sizeof(uint32_t) || context->generation == 0) {
        return 1;
    }
    const uintptr_t destination = (uintptr_t)context->destination;
    if ((destination & (sizeof(uint32_t) - 1)) != 0 ||
        destination < dory_code_start || destination >= dory_code_end ||
        context->capacity > dory_code_end - destination ||
        2 * sizeof(uint32_t) > dory_code_end - destination) {
        return 1;
    }
    const uint64_t prior_generation = atomic_load_explicit(
        &dory_published_generation,
        memory_order_relaxed
    );
    if (context->generation <= prior_generation) {
        return 1;
    }
    const uint32_t instructions[] = {
        0x52800000u | ((uint32_t)context->result << 5), /* mov w0, #result */
        0xd65f03c0u, /* ret */
    };
    memcpy(context->destination, instructions, sizeof(instructions));
    sys_icache_invalidate(context->destination, sizeof(instructions));
    atomic_store_explicit(
        &dory_published_generation,
        context->generation,
        memory_order_release
    );
    return 0;
}

PTHREAD_JIT_WRITE_ALLOW_CALLBACKS_NP(dory_emit_probe);

typedef int (*dory_probe_function)(void);

struct dory_jit_stress {
    dory_probe_function function;
    _Atomic bool visible;
    _Atomic bool stop;
    _Atomic uint32_t hazards;
    _Atomic uint32_t expected_result;
    _Atomic uint64_t executions;
    _Atomic uint64_t failures;
    _Atomic int last_actual;
    _Atomic uint32_t last_expected;
};

static void dory_child_fault_handler(int signal_number) {
    _exit(128 + signal_number);
}

static void *dory_stress_reader(void *opaque_context) {
    struct dory_jit_stress *stress = opaque_context;
    while (!atomic_load_explicit(&stress->stop, memory_order_acquire)) {
        if (!atomic_load_explicit(&stress->visible, memory_order_seq_cst)) {
            sched_yield();
            continue;
        }
        atomic_fetch_add_explicit(&stress->hazards, 1, memory_order_seq_cst);
        if (!atomic_load_explicit(&stress->visible, memory_order_seq_cst)) {
            atomic_fetch_sub_explicit(&stress->hazards, 1, memory_order_seq_cst);
            continue;
        }
        const uint32_t expected = atomic_load_explicit(
            &stress->expected_result,
            memory_order_acquire
        );
        const int actual = stress->function();
        if (actual != (int)expected) {
            atomic_store_explicit(&stress->last_actual, actual, memory_order_relaxed);
            atomic_store_explicit(&stress->last_expected, expected, memory_order_relaxed);
            atomic_fetch_add_explicit(&stress->failures, 1, memory_order_relaxed);
        }
        atomic_fetch_add_explicit(&stress->executions, 1, memory_order_relaxed);
        atomic_fetch_sub_explicit(&stress->hazards, 1, memory_order_seq_cst);
    }
    return NULL;
}

static int dory_expect_child_signal(void (*operation)(void *), void *context) {
    const pid_t child = fork();
    if (child < 0) {
        return -1;
    }
    if (child == 0) {
        signal(SIGBUS, dory_child_fault_handler);
        signal(SIGSEGV, dory_child_fault_handler);
        operation(context);
        _exit(0);
    }
    int child_status = 0;
    if (waitpid(child, &child_status, 0) != child) {
        return -1;
    }
    if (WIFEXITED(child_status)) {
        const int exit_code = WEXITSTATUS(child_status);
        if (exit_code == 128 + SIGBUS || exit_code == 128 + SIGSEGV) {
            return exit_code - 128;
        }
    }
    if (!WIFSIGNALED(child_status)) { return 0; }
    const int signal_number = WTERMSIG(child_status);
    return signal_number == SIGBUS || signal_number == SIGSEGV ? signal_number : 0;
}

static void dory_attempt_direct_write(void *context) {
    volatile uint32_t *code = context;
    *code = 0xd4200000u;
}

static void dory_attempt_read(void *context) {
    volatile uint8_t value = *(volatile uint8_t *)context;
    (void)value;
}

int main(void) {
    const long page_size_value = sysconf(_SC_PAGESIZE);
    if (page_size_value <= 0) {
        fputs("dory JIT probe: invalid host page size\n", stderr);
        return 1;
    }
    const size_t page_size = (size_t)page_size_value;
    const size_t mapping_size = 3 * page_size;
    void *mapping = mmap(
        NULL,
        mapping_size,
        PROT_NONE,
        MAP_PRIVATE | MAP_ANON,
        -1,
        0
    );
    if (mapping == MAP_FAILED) {
        perror("dory JIT probe: mmap guard reservation");
        return 1;
    }

    void *code = (uint8_t *)mapping + page_size;
    if (munmap(code, page_size) != 0) {
        perror("dory JIT probe: release code reservation");
        munmap(mapping, mapping_size);
        return 1;
    }
    void *jit_mapping = mmap(
        code,
        page_size,
        PROT_READ | PROT_WRITE | PROT_EXEC,
        MAP_PRIVATE | MAP_ANON | MAP_JIT,
        -1,
        0
    );
    if (jit_mapping == MAP_FAILED) {
        perror("dory JIT probe: mmap MAP_JIT code page");
        munmap(mapping, mapping_size);
        return 1;
    }
    if (jit_mapping != code) {
        fputs("dory JIT probe: MAP_JIT did not honor the guarded address\n", stderr);
        munmap(jit_mapping, page_size);
        munmap(mapping, mapping_size);
        return 1;
    }
    dory_code_start = (uintptr_t)code;
    dory_code_end = dory_code_start + page_size;
    atomic_init(&dory_published_generation, 0);

    if (!pthread_jit_write_protect_supported_np()) {
        fputs("dory JIT probe: per-thread JIT write protection is unavailable\n", stderr);
        munmap(mapping, mapping_size);
        return 1;
    }
    struct dory_jit_emission context = {
        .destination = code,
        .capacity = page_size,
        .result = 42,
        .generation = 1,
    };
    const int write_result = pthread_jit_write_with_callback_np(
        dory_emit_probe,
        &context
    );
    if (write_result != 0) {
        fprintf(stderr, "dory JIT probe: allowlisted callback rejected input (%d)\n", write_result);
        munmap(mapping, mapping_size);
        return 1;
    }

    struct dory_jit_emission hostile_contexts[] = {
        {.destination = NULL, .capacity = page_size, .result = 1, .generation = 2},
        {.destination = code, .capacity = sizeof(uint32_t), .result = 1, .generation = 2},
        {.destination = mapping, .capacity = page_size, .result = 1, .generation = 2},
        {.destination = (uint8_t *)code + 1, .capacity = page_size - 1, .result = 1, .generation = 2},
        {.destination = code, .capacity = page_size, .result = 1, .generation = 0},
    };
    size_t hostile_rejections = 0;
    if (pthread_jit_write_with_callback_np(dory_emit_probe, NULL) != 0) {
        hostile_rejections += 1;
    }
    for (size_t index = 0;
         index < sizeof(hostile_contexts) / sizeof(hostile_contexts[0]);
         index += 1) {
        if (pthread_jit_write_with_callback_np(
                dory_emit_probe,
                &hostile_contexts[index]
            ) != 0) {
            hostile_rejections += 1;
        }
    }
    if (hostile_rejections != 6 ||
        atomic_load_explicit(&dory_published_generation, memory_order_acquire) != 1) {
        fputs("dory JIT probe: hostile callback input was not rejected\n", stderr);
        munmap(mapping, mapping_size);
        return 1;
    }

    union {
        void *pointer;
        dory_probe_function function;
    } callable = {.pointer = code};
    const int result = callable.function();
    if (result != 42) {
        fprintf(stderr, "dory JIT probe: generated code returned %d\n", result);
        munmap(mapping, mapping_size);
        return 1;
    }

    struct dory_jit_stress stress = {
        .function = callable.function,
    };
    atomic_init(&stress.visible, true);
    atomic_init(&stress.stop, false);
    atomic_init(&stress.hazards, 0);
    atomic_init(&stress.expected_result, 42);
    atomic_init(&stress.executions, 0);
    atomic_init(&stress.failures, 0);
    atomic_init(&stress.last_actual, 0);
    atomic_init(&stress.last_expected, 0);
    enum { dory_reader_count = 4, dory_reuse_iterations = 1000 };
    pthread_t readers[dory_reader_count];
    size_t readers_started = 0;
    for (; readers_started < dory_reader_count; readers_started += 1) {
        if (pthread_create(
                &readers[readers_started],
                NULL,
                dory_stress_reader,
                &stress
            ) != 0) {
            break;
        }
    }
    if (readers_started != dory_reader_count) {
        atomic_store_explicit(&stress.stop, true, memory_order_release);
        for (size_t index = 0; index < readers_started; index += 1) {
            pthread_join(readers[index], NULL);
        }
        fputs("dory JIT probe: could not start reuse readers\n", stderr);
        munmap(mapping, mapping_size);
        return 1;
    }
    for (size_t attempt = 0;
         attempt < 100000 &&
             atomic_load_explicit(&stress.executions, memory_order_relaxed) == 0;
         attempt += 1) {
        sched_yield();
    }
    if (atomic_load_explicit(&stress.executions, memory_order_relaxed) == 0) {
        atomic_store_explicit(&stress.stop, true, memory_order_release);
        for (size_t index = 0; index < dory_reader_count; index += 1) {
            pthread_join(readers[index], NULL);
        }
        fputs("dory JIT probe: reuse readers made no progress\n", stderr);
        munmap(mapping, mapping_size);
        return 1;
    }
    for (uint64_t generation = 2;
         generation <= dory_reuse_iterations + 1;
         generation += 1) {
        atomic_store_explicit(&stress.visible, false, memory_order_seq_cst);
        while (atomic_load_explicit(&stress.hazards, memory_order_seq_cst) != 0) {
            sched_yield();
        }
        const uint16_t next_result = generation % 2 == 0 ? 43 : 42;
        struct dory_jit_emission next = {
            .destination = code,
            .capacity = page_size,
            .result = next_result,
            .generation = generation,
        };
        if (pthread_jit_write_with_callback_np(dory_emit_probe, &next) != 0) {
            atomic_store_explicit(&stress.stop, true, memory_order_release);
            for (size_t index = 0; index < dory_reader_count; index += 1) {
                pthread_join(readers[index], NULL);
            }
            fputs("dory JIT probe: bounded slot reuse failed\n", stderr);
            munmap(mapping, mapping_size);
            return 1;
        }
        atomic_store_explicit(
            &stress.expected_result,
            next_result,
            memory_order_release
        );
        atomic_store_explicit(&stress.visible, true, memory_order_seq_cst);
    }
    atomic_store_explicit(&stress.visible, false, memory_order_seq_cst);
    while (atomic_load_explicit(&stress.hazards, memory_order_seq_cst) != 0) {
        sched_yield();
    }
    atomic_store_explicit(&stress.stop, true, memory_order_release);
    for (size_t index = 0; index < dory_reader_count; index += 1) {
        pthread_join(readers[index], NULL);
    }
    const uint64_t reader_executions = atomic_load_explicit(
        &stress.executions,
        memory_order_relaxed
    );
    const uint64_t reader_failures = atomic_load_explicit(
        &stress.failures,
        memory_order_relaxed
    );
    if (reader_executions == 0 || reader_failures != 0) {
        fprintf(
            stderr,
            "dory JIT probe: concurrent reuse observed stale code "
            "(actual %d, expected %u, failures %llu)\n",
            atomic_load_explicit(&stress.last_actual, memory_order_relaxed),
            atomic_load_explicit(&stress.last_expected, memory_order_relaxed),
            (unsigned long long)reader_failures
        );
        munmap(mapping, mapping_size);
        return 1;
    }

    const int write_signal = dory_expect_child_signal(dory_attempt_direct_write, code);
    const int leading_guard_signal = dory_expect_child_signal(dory_attempt_read, mapping);
    const int trailing_guard_signal = dory_expect_child_signal(
        dory_attempt_read,
        (uint8_t *)code + page_size
    );
    const int post_crash_result = callable.function();
    const int expected_final_result = (dory_reuse_iterations + 1) % 2 == 0 ? 43 : 42;
    if (write_signal <= 0 || leading_guard_signal <= 0 || trailing_guard_signal <= 0 ||
        post_crash_result != expected_final_result) {
        fputs("dory JIT probe: W^X, guard, or crash recovery assertion failed\n", stderr);
        munmap(mapping, mapping_size);
        return 1;
    }
    if (munmap(mapping, mapping_size) != 0) {
        perror("dory JIT probe: munmap");
        return 1;
    }

    printf(
        "{\"schemaVersion\":2,\"status\":\"PASS\",\"hostArchitecture\":\"arm64\","
        "\"mapJITRegions\":1,\"guardPages\":2,\"codePages\":1,"
        "\"writeAPI\":\"pthread_jit_write_with_callback_np\","
        "\"instructionCachePublication\":\"sys_icache_invalidate\","
        "\"hostileCallbackRejections\":%zu,\"reuseIterations\":%d,"
        "\"readerThreads\":%d,\"readerExecutions\":%llu,\"readerFailures\":%llu,"
        "\"writeProtectionSignal\":%d,\"leadingGuardSignal\":%d,"
        "\"trailingGuardSignal\":%d,\"postCrashResult\":%d}\n",
        hostile_rejections,
        dory_reuse_iterations,
        dory_reader_count,
        (unsigned long long)reader_executions,
        (unsigned long long)reader_failures,
        write_signal,
        leading_guard_signal,
        trailing_guard_signal,
        post_crash_result
    );
    return 0;
}

#else

int main(void) {
    fputs("dory JIT probe: unsupportedHostArchitecture (requires Apple silicon)\n", stderr);
    return 2;
}

#endif
