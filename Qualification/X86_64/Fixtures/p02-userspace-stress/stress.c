/* Bounded guest-only P02 engineering workload. Never run this binary on the host. */
#define _GNU_SOURCE 1
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#ifndef DORY_STRESS_SOURCE_SHA256
#error Build through the adjacent Makefile to bind the source digest.
#endif

enum {
    PAYLOAD_BYTES = 128 * 1024,
    FILE_LIMIT = 256 * 1024,
    ALLOCATION_ROUNDS = 32,
    PROTECTION_ROUNDS = 4,
    EXEC_ROUNDS = 8,
    FILE_ROUNDS = 8,
    COMPRESSION_ROUNDS = 3,
    PACKAGE_ROUNDS = 2,
    CHILD_LIMIT = 64,
    FD_LIMIT = 32,
    DEADLINE_SECONDS = 120
};

static const char busybox_path[] = "/bin/busybox";
/* Exact Alpine 3.24.1 initramfs members; independently verified by the preparer. */
static const char busybox_sha[] =
    "01a989eb4d1d04b0d146c790ac536abd88f374ec74a2e110c58910b840d42045";
/* SHA-256 of byte[i] = (i * 37 + (i >> 8)) modulo 256, for 131072 bytes. */
static const char payload_sha[] =
    "dbb71d178d43f63f39dd9b0fb5fc30fb366ada39e3b8763e41338b892c098cd6";
static const char *const workloads[] = {
    "stress.allocation_free", "stress.mmap_protection", "stress.process_exec_wait",
    "stress.filesystem_roundtrip", "stress.compression_checksum",
    "stress.package_unpack", "stress.monotonic_clock"
};
static char run_id[37];
static char directory[] = "/run/dory-p02-stress-XXXXXX";
static int64_t deadline_ns;
static int64_t last_clock_ns;
static unsigned child_count;
static bool directory_created;
static bool inside_directory;

static bool uuid_is_canonical(const char *s)
{
    if (strlen(s) != 36) return false;
    for (size_t i = 0; i < 36; ++i) {
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (s[i] != '-') return false;
        } else if (!((s[i] >= '0' && s[i] <= '9') ||
                     (s[i] >= 'a' && s[i] <= 'f'))) return false;
    }
    return true;
}

static bool guest_guard(void)
{
#if !defined(__linux__) || !defined(__x86_64__)
    return false;
#endif
    struct utsname host;
    if (uname(&host) != 0 || strcmp(host.sysname, "Linux") != 0 ||
        strcmp(host.machine, "x86_64") != 0) return false;
    int fd = open("/proc/cmdline", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return false;
    char command_line[8193];
    size_t used = 0;
    bool valid = true;
    while (used < sizeof(command_line)) {
        ssize_t n = read(fd, command_line + used, sizeof(command_line) - used);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { valid = false; break; }
        if (n == 0) break;
        used += (size_t)n;
    }
    if (close(fd) != 0) valid = false;
    if (!valid || used == sizeof(command_line) ||
        memchr(command_line, '\0', used) != NULL) return false;
    command_line[used] = '\0';
    unsigned matches = 0;
    char *cursor = NULL;
    for (char *token = strtok_r(command_line, " \t\r\n", &cursor); token;
         token = strtok_r(NULL, " \t\r\n", &cursor)) {
        const char key[] = "dory.pvh_run_id=";
        if (strncmp(token, key, sizeof(key) - 1) != 0) continue;
        if (++matches != 1 || !uuid_is_canonical(token + sizeof(key) - 1)) return false;
        memcpy(run_id, token + sizeof(key) - 1, sizeof(run_id));
    }
    return matches == 1;
}

static bool monotonic_now(int64_t *value)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0 || now.tv_sec < 0 ||
        now.tv_sec > INT64_MAX / INT64_C(1000000000) - DEADLINE_SECONDS ||
        now.tv_nsec < 0 || now.tv_nsec >= 1000000000L) return false;
    *value = (int64_t)now.tv_sec * INT64_C(1000000000) + now.tv_nsec;
    if (*value < last_clock_ns) return false;
    last_clock_ns = *value;
    return true;
}

static bool within_budget(void)
{
    int64_t now;
    return monotonic_now(&now) && now < deadline_ns;
}

/* No string field can originate from an unescaped guest file or command. */
static bool result(const char *name, bool passed, unsigned iterations)
{
    return printf("DORY_P02_RESULT {\"schemaVersion\":1,\"kind\":\"userspace-result\","
                  "\"runUUID\":\"%s\",\"name\":\"%s\",\"status\":\"%s\","
                  "\"detail\":\"%s\",\"iterations\":%u,\"sourceSHA256\":\"%s\"}\n",
                  run_id, name, passed ? "pass" : "fail",
                  passed ? "validated_within_fixed_limits" : "incomplete_or_invalid",
                  iterations, DORY_STRESS_SOURCE_SHA256) > 0 && fflush(stdout) == 0;
}

static bool write_all(int fd, const void *bytes, size_t count)
{
    const unsigned char *p = bytes;
    while (count != 0) {
        if (!within_budget()) return false;
        ssize_t n = write(fd, p, count);
        if (n < 0 && errno == EINTR) continue;
        if (n <= 0) return false;
        p += (size_t)n;
        count -= (size_t)n;
    }
    return true;
}

static bool read_file(const char *path, unsigned char *bytes, size_t capacity, size_t *size)
{
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return false;
    struct stat st;
    bool ok = fstat(fd, &st) == 0 && S_ISREG(st.st_mode) && st.st_size >= 0 &&
              (uint64_t)st.st_size <= capacity;
    size_t used = 0;
    while (ok && used < capacity) {
        if (!within_budget()) { ok = false; break; }
        ssize_t n = read(fd, bytes + used, capacity - used);
        if (n < 0 && errno == EINTR) continue;
        if (n < 0) { ok = false; break; }
        if (n == 0) break;
        used += (size_t)n;
    }
    unsigned char extra;
    if (ok && (used != (size_t)st.st_size || read(fd, &extra, 1) != 0)) ok = false;
    if (close(fd) != 0) ok = false;
    *size = used;
    return ok;
}

static bool limit_resources(void)
{
    const struct rlimit core = {0, 0};
    const struct rlimit files = {FILE_LIMIT, FILE_LIMIT};
    const struct rlimit descriptors = {FD_LIMIT, FD_LIMIT};
    const struct rlimit cpu = {DEADLINE_SECONDS, DEADLINE_SECONDS};
    return setrlimit(RLIMIT_CORE, &core) == 0 &&
           setrlimit(RLIMIT_FSIZE, &files) == 0 &&
           setrlimit(RLIMIT_NOFILE, &descriptors) == 0 &&
           setrlimit(RLIMIT_CPU, &cpu) == 0;
}

static void kill_and_reap(pid_t child)
{
    /* Only the one child created by this program, never a process group. */
    (void)kill(child, SIGKILL);
    while (waitpid(child, NULL, 0) < 0 && errno == EINTR) {}
}

static bool wait_child(pid_t child, int expected_exit, int expected_signal)
{
    for (;;) {
        int status = 0;
        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child) {
            if (!within_budget()) return false;
            if (expected_signal != 0)
                return WIFSIGNALED(status) && WTERMSIG(status) == expected_signal;
            return WIFEXITED(status) && WEXITSTATUS(status) == expected_exit;
        }
        if (waited < 0 && errno != EINTR) return false;
        if (!within_budget()) { kill_and_reap(child); return false; }
        struct timespec pause = {0, 1000000L};
        if (nanosleep(&pause, NULL) != 0 && errno != EINTR) {
            kill_and_reap(child);
            return false;
        }
    }
}

static bool spawn(const char *executable, char *const argv[], const char *output,
                  int expected_exit)
{
    if (!within_budget() || child_count >= CHILD_LIMIT) return false;
    int fd = open(output, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
    if (fd < 0) return false;
    pid_t child = fork();
    if (child == 0) {
        if (dup2(fd, STDOUT_FILENO) < 0 || dup2(fd, STDERR_FILENO) < 0) _exit(125);
        (void)close(fd);
        /* The caller's dynamic-loader and shell environment is never inherited. */
        char *const environment[] = {"PATH=/bin", "LC_ALL=C", "TZ=UTC", NULL};
        execve(executable, argv, environment);
        _exit(126);
    }
    bool closed = close(fd) == 0;
    if (child < 0) return false;
    ++child_count;
    bool ok = wait_child(child, expected_exit, 0);
    return closed && ok;
}

static bool remove_file(const char *path)
{
    return unlink(path) == 0 || errno == ENOENT;
}

static bool empty_output(const char *path)
{
    unsigned char bytes[1];
    size_t size;
    return read_file(path, bytes, sizeof(bytes), &size) && size == 0 && remove_file(path);
}

static bool checksum(const char *path, const char *expected)
{
    char *const args[] = {"busybox", "sha256sum", (char *)path, NULL};
    if (!spawn(busybox_path, args, "tool.out", 0)) return false;
    unsigned char output[192];
    size_t size;
    char wanted[192];
    int length = snprintf(wanted, sizeof(wanted), "%s  %s\n", expected, path);
    return length > 0 && (size_t)length < sizeof(wanted) &&
           read_file("tool.out", output, sizeof(output), &size) &&
           size == (size_t)length && memcmp(output, wanted, size) == 0 &&
           remove_file("tool.out");
}

static unsigned char pattern(size_t index, unsigned round)
{
    return (unsigned char)(index * 37u + (index >> 8) + round * 19u);
}

static bool allocation_stage(void)
{
    for (unsigned round = 0; round < ALLOCATION_ROUNDS; ++round) {
        if (!within_budget()) return false;
        size_t initial = 4096u + (round % 16u) * 16384u;
        size_t expanded = initial * 2u + 17u;
        unsigned char *p = malloc(initial);
        if (!p) return false;
        for (size_t i = 0; i < initial; ++i) p[i] = pattern(i, round);
        unsigned char *grown = realloc(p, expanded);
        if (!grown) { free(p); return false; }
        p = grown;
        bool ok = true;
        for (size_t i = 0; i < initial; ++i) if (p[i] != pattern(i, round)) ok = false;
        for (size_t i = initial; i < expanded; ++i) p[i] = pattern(i, round);
        for (size_t i = 0; i < expanded; ++i) if (p[i] != pattern(i, round)) ok = false;
        free(p);
        /* Volatile reads keep the check observable to an optimizing compiler. */
        volatile unsigned char *zero = calloc(initial, 1);
        if (!zero) return false;
        for (size_t i = 0; i < initial; ++i) if (zero[i] != 0) ok = false;
        free((void *)zero);
        if (!ok) return false;
    }
    return within_budget();
}

static bool protection_child(volatile unsigned char *page, bool write_access)
{
    if (!within_budget() || child_count >= CHILD_LIMIT) return false;
    pid_t child = fork();
    if (child == 0) {
        struct sigaction action;
        memset(&action, 0, sizeof(action));
        action.sa_handler = SIG_DFL;
        sigemptyset(&action.sa_mask);
        sigset_t unblocked;
        sigemptyset(&unblocked);
        sigaddset(&unblocked, SIGSEGV);
        if (sigaction(SIGSEGV, &action, NULL) != 0 ||
            sigprocmask(SIG_UNBLOCK, &unblocked, NULL) != 0) _exit(125);
        if (write_access) *page = 0x5a;
        else { volatile unsigned char value = *page; (void)value; }
        _exit(124); /* Returning from the forbidden access is a failure. */
    }
    if (child < 0) return false;
    ++child_count;
    return wait_child(child, 0, SIGSEGV);
}

static bool protection_stage(void)
{
    long page_size = sysconf(_SC_PAGESIZE);
    if (page_size < 4096 || page_size > 65536 ||
        ((unsigned long)page_size & ((unsigned long)page_size - 1)) != 0) return false;
    size_t size = (size_t)page_size * 4u;
    for (unsigned round = 0; round < PROTECTION_ROUNDS; ++round) {
        if (!within_budget()) return false;
        unsigned char *p = mmap(NULL, size, PROT_READ | PROT_WRITE,
                                MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
        if (p == MAP_FAILED) return false;
        for (size_t i = 0; i < size; ++i) p[i] = pattern(i, round);
        bool ok = mprotect(p + page_size, (size_t)page_size, PROT_READ) == 0 &&
                  protection_child(p + page_size, true) &&
                  mprotect(p + 2 * page_size, (size_t)page_size, PROT_NONE) == 0 &&
                  protection_child(p + 2 * page_size, false);
        if (mprotect(p, size, PROT_READ | PROT_WRITE) != 0) ok = false;
        if (ok) for (size_t i = 0; i < size; ++i) if (p[i] != pattern(i, round)) ok = false;
        if (munmap(p, size) != 0) ok = false;
        if (!ok) return false;
    }
    return within_budget();
}

static bool process_stage(void)
{
    for (unsigned i = 0; i < EXEC_ROUNDS; ++i) {
        char ordinal[2] = {(char)('0' + i), '\0'};
        char *const args[] = {"p02-userspace-stress", "--exec-child", run_id, ordinal, NULL};
        if (!spawn("/proc/self/exe", args, "child.out", 23)) return false;
        char expected[96];
        int length = snprintf(expected, sizeof(expected), "DORY_STRESS_CHILD %s %u\n", run_id, i);
        unsigned char output[96];
        size_t size;
        if (length <= 0 || !read_file("child.out", output, sizeof(output), &size) ||
            size != (size_t)length || memcmp(output, expected, size) != 0 ||
            !remove_file("child.out")) return false;
    }
    return within_budget();
}

static bool validate_payload(const char *path)
{
    unsigned char *bytes = malloc(PAYLOAD_BYTES);
    if (!bytes) return false;
    size_t size;
    bool ok = read_file(path, bytes, PAYLOAD_BYTES, &size) && size == PAYLOAD_BYTES;
    if (ok) for (size_t i = 0; i < size; ++i) if (bytes[i] != pattern(i, 0)) ok = false;
    free(bytes);
    return ok;
}

static bool file_stage(void)
{
    unsigned char *bytes = malloc(PAYLOAD_BYTES);
    if (!bytes) return false;
    for (size_t i = 0; i < PAYLOAD_BYTES; ++i) bytes[i] = pattern(i, 0);
    bool ok = true;
    for (unsigned round = 0; ok && round < FILE_ROUNDS; ++round) {
        int fd = open("payload", O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0600);
        if (fd < 0) { ok = false; break; }
        ok = write_all(fd, bytes, PAYLOAD_BYTES) && fsync(fd) == 0;
        if (close(fd) != 0) ok = false;
        if (ok) ok = validate_payload("payload");
        if (ok && round + 1 < FILE_ROUNDS) ok = remove_file("payload");
    }
    free(bytes);
    return ok && checksum("payload", payload_sha) && within_budget();
}

static bool compressed_file(const char *input, const char *output, bool decompress)
{
    char *const args[] = {"busybox", "gzip", decompress ? "-dc" : "-c", (char *)input, NULL};
    return spawn(busybox_path, args, output, 0);
}

static bool compression_stage(void)
{
    for (unsigned round = 0; round < COMPRESSION_ROUNDS; ++round) {
        if (!compressed_file("payload", "payload.gz", false)) return false;
        struct stat st;
        if (lstat("payload.gz", &st) != 0 || !S_ISREG(st.st_mode) || st.st_size <= 18 ||
            st.st_size >= PAYLOAD_BYTES) return false;
        if (!compressed_file("payload.gz", "roundtrip", true) ||
            !validate_payload("roundtrip") || !checksum("roundtrip", payload_sha) ||
            !remove_file("payload.gz") || !remove_file("roundtrip")) return false;
    }
    return within_budget();
}

static bool octal(const unsigned char *bytes, size_t count, uint64_t *value)
{
    bool digit = false, ended = false;
    *value = 0;
    for (size_t i = 0; i < count; ++i) {
        if (bytes[i] == 0 || bytes[i] == ' ') { if (digit) ended = true; continue; }
        if (ended || bytes[i] < '0' || bytes[i] > '7' || *value > (UINT64_MAX >> 3)) return false;
        digit = true;
        *value = (*value << 3) | (uint64_t)(bytes[i] - '0');
    }
    return digit;
}

static bool all_zero(const unsigned char *p, size_t count)
{
    for (size_t i = 0; i < count; ++i) if (p[i] != 0) return false;
    return true;
}

/* Accept only our one ordinary file, before allowing tar to write any member. */
static bool validate_tar(const unsigned char *bytes, size_t size)
{
    if (size < 512u + PAYLOAD_BYTES + 1024u || size % 512u != 0 ||
        memcmp(bytes, "payload", 7) != 0 || !all_zero(bytes + 7, 100 - 7) ||
        (bytes[156] != '0' && bytes[156] != 0) ||
        !all_zero(bytes + 157, 100) || !all_zero(bytes + 345, 155)) return false;
    uint64_t file_size, stored_sum;
    if (!octal(bytes + 124, 12, &file_size) || file_size != PAYLOAD_BYTES ||
        !octal(bytes + 148, 8, &stored_sum)) return false;
    uint64_t sum = 0;
    for (size_t i = 0; i < 512; ++i) sum += (i >= 148 && i < 156) ? ' ' : bytes[i];
    if (sum != stored_sum) return false;
    for (size_t i = 0; i < PAYLOAD_BYTES; ++i) if (bytes[512 + i] != pattern(i, 0)) return false;
    return all_zero(bytes + 512 + PAYLOAD_BYTES, size - 512 - PAYLOAD_BYTES);
}

static bool package_stage(void)
{
    unsigned char *original = malloc(FILE_LIMIT);
    unsigned char *expanded = malloc(FILE_LIMIT);
    if (!original || !expanded) { free(original); free(expanded); return false; }
    bool ok = true;
    for (unsigned round = 0; ok && round < PACKAGE_ROUNDS; ++round) {
        char *const create[] = {"busybox", "tar", "-cf", "package.tar", "payload", NULL};
        ok = spawn(busybox_path, create, "tool.out", 0) && empty_output("tool.out");
        size_t original_size = 0, expanded_size = 0;
        if (ok) ok = read_file("package.tar", original, FILE_LIMIT, &original_size) &&
                     validate_tar(original, original_size) &&
                     compressed_file("package.tar", "package.tar.gz", false) &&
                     compressed_file("package.tar.gz", "unpacked.tar", true) &&
                     read_file("unpacked.tar", expanded, FILE_LIMIT, &expanded_size) &&
                     expanded_size == original_size &&
                     memcmp(original, expanded, original_size) == 0 &&
                     validate_tar(expanded, expanded_size) && mkdir("unpacked", 0700) == 0;
        char *const extract[] = {"busybox", "tar", "-xf", "unpacked.tar", "-C", "unpacked", NULL};
        if (ok) ok = spawn(busybox_path, extract, "tool.out", 0) && empty_output("tool.out") &&
                     validate_payload("unpacked/payload") && checksum("unpacked/payload", payload_sha);
        if (ok) ok = remove_file("unpacked/payload") && rmdir("unpacked") == 0 &&
                     remove_file("package.tar") && remove_file("package.tar.gz") &&
                     remove_file("unpacked.tar");
    }
    free(original);
    free(expanded);
    return ok && within_budget();
}

static bool clock_stage(void)
{
    for (unsigned round = 0; round < 4; ++round) {
        int64_t before, after;
        if (!within_budget() || !monotonic_now(&before)) return false;
        struct timespec remaining = {0, 20000000L};
        while (nanosleep(&remaining, &remaining) != 0) {
            if (errno != EINTR || !within_budget()) return false;
        }
        if (!monotonic_now(&after) || after - before < 20000000 || !within_budget()) return false;
    }
    return true;
}

static bool cleanup(void)
{
    bool ok = true;
    if (inside_directory) {
        const char *const files[] = {"tool.out", "child.out", "payload", "payload.gz",
            "roundtrip", "package.tar", "package.tar.gz", "unpacked.tar", "unpacked/payload"};
        for (size_t i = 0; i < sizeof(files) / sizeof(files[0]); ++i)
            if (!remove_file(files[i])) ok = false;
        if (rmdir("unpacked") != 0 && errno != ENOENT) ok = false;
        if (chdir("/") != 0) ok = false;
        inside_directory = false;
    }
    if (directory_created && rmdir(directory) != 0) ok = false;
    directory_created = false;
    return ok;
}

int main(int argc, char **argv)
{
    /* Read-only checks precede limits, signals, children, or filesystem changes. */
    if (!guest_guard()) {
        fputs("p02-userspace-stress: requires Linux x86_64 and one canonical guest run UUID\n", stderr);
        return 2;
    }
    if (argc == 4 && strcmp(argv[1], "--exec-child") == 0) {
        if (strcmp(argv[2], run_id) != 0 || strlen(argv[3]) != 1 ||
            argv[3][0] < '0' || argv[3][0] >= '0' + EXEC_ROUNDS) return 2;
        if (printf("DORY_STRESS_CHILD %s %s\n", run_id, argv[3]) < 0 || fflush(stdout) != 0) return 2;
        return 23;
    }
    if (argc != 2 || strcmp(argv[1], "--run") != 0 || getpid() == 1) {
        fputs("usage: p02-userspace-stress --run (supervised guest child, never PID 1)\n", stderr);
        return 2;
    }
    int64_t started;
    if (!monotonic_now(&started)) return 2;
    deadline_ns = started + INT64_C(1000000000) * DEADLINE_SECONDS;
    if (!limit_resources()) return 2;
    umask(077);
    if (!mkdtemp(directory)) return 2;
    directory_created = true;
    if (chdir(directory) != 0) { (void)cleanup(); return 2; }
    inside_directory = true;
    struct stat bb;
    bool setup = lstat(busybox_path, &bb) == 0 && S_ISREG(bb.st_mode) &&
                 bb.st_size > 0 && bb.st_size <= 2 * 1024 * 1024 &&
                 checksum(busybox_path, busybox_sha);
    if (!setup) {
        (void)result("stress.fixture_identity", false, 0);
        (void)cleanup();
        return 1;
    }
    bool (*const stages[])(void) = {allocation_stage, protection_stage, process_stage,
        file_stage, compression_stage, package_stage, clock_stage};
    const unsigned rounds[] = {ALLOCATION_ROUNDS, PROTECTION_ROUNDS, EXEC_ROUNDS,
        FILE_ROUNDS, COMPRESSION_ROUNDS, PACKAGE_ROUNDS, 4};
    const size_t count = sizeof(stages) / sizeof(stages[0]);
    for (size_t i = 0; i < count; ++i) {
        bool passed = within_budget() && stages[i]() && within_budget();
        if (!result(workloads[i], passed, passed ? rounds[i] : 0) || !passed) {
            (void)cleanup();
            return 1;
        }
    }
    if (!cleanup() || !within_budget()) {
        (void)result("stress.cleanup_and_budget", false, 0);
        return 1;
    }
    if (printf("{\"schemaVersion\":1,\"doryPVHBoot\":\"userspace-ready\",\"runID\":\"%s\","
               "\"workloadsPassed\":true,\"sourceSHA256\":\"%s\",\"workloads\":[",
               run_id, DORY_STRESS_SOURCE_SHA256) < 0) return 1;
    for (size_t i = 0; i < count; ++i)
        if (printf("%s\"%s\"", i ? "," : "", workloads[i]) < 0) return 1;
    if (printf("]}\n") < 0 || fflush(stdout) != 0) return 1;
    return 0; /* The supervising init must separately request and verify poweroff. */
}
