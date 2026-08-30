#include <libkern/OSCacheControl.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#if defined(__aarch64__)

struct dory_jit_emission {
    void *destination;
    size_t capacity;
};

static int dory_emit_probe(void *opaque_context) {
    static const uint32_t instructions[] = {
        0x52800540u, /* mov w0, #42 */
        0xd65f03c0u, /* ret */
    };
    struct dory_jit_emission *context = opaque_context;
    if (context == NULL || context->destination == NULL ||
        context->capacity < sizeof(instructions)) {
        return 1;
    }
    memcpy(context->destination, instructions, sizeof(instructions));
    sys_icache_invalidate(context->destination, sizeof(instructions));
    return 0;
}

PTHREAD_JIT_WRITE_ALLOW_CALLBACKS_NP(dory_emit_probe);

typedef int (*dory_probe_function)(void);

int main(void) {
    const long page_size_value = sysconf(_SC_PAGESIZE);
    if (page_size_value <= 0) {
        fputs("dory JIT probe: invalid host page size\n", stderr);
        return 1;
    }
    const size_t page_size = (size_t)page_size_value;
    const size_t mapping_size = page_size;
    void *mapping = mmap(
        NULL,
        mapping_size,
        PROT_READ | PROT_WRITE | PROT_EXEC,
        MAP_PRIVATE | MAP_ANON | MAP_JIT,
        -1,
        0
    );
    if (mapping == MAP_FAILED) {
        perror("dory JIT probe: mmap(MAP_JIT)");
        return 1;
    }

    void *code = mapping;

    struct dory_jit_emission context = {
        .destination = code,
        .capacity = page_size,
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
    if (munmap(mapping, mapping_size) != 0) {
        perror("dory JIT probe: munmap");
        return 1;
    }

    printf(
        "{\"schemaVersion\":1,\"status\":\"PASS\",\"hostArchitecture\":\"arm64\","
        "\"mapJITRegions\":1,\"guardPages\":0,\"codePages\":1,"
        "\"writeAPI\":\"pthread_jit_write_with_callback_np\","
        "\"instructionCachePublication\":\"sys_icache_invalidate\","
        "\"generatedResult\":42}\n"
    );
    return 0;
}

#else

int main(void) {
    fputs("dory JIT probe: unsupportedHostArchitecture (requires Apple silicon)\n", stderr);
    return 2;
}

#endif
