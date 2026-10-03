/* Owned ARM Linux scratch-page witness. It never claims a host retry count: the signed helper
 * supplies that separately. A PASS requires this process to receive SIGBUS on the nominated
 * address and subsequently read the unchanged page after host permission restoration. */
#define _GNU_SOURCE
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <setjmp.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>
#ifdef __linux__
#include <sched.h>
#include <sys/resource.h>
#include <sys/utsname.h>
/* Linux v6.8 UAPI: include/uapi/asm-generic/mman-common.h. */
#ifndef MADV_COLLAPSE
#define MADV_COLLAPSE 25
#endif
#endif

#define HOST_PAGE_BYTES 16384u
#define HUGE_BYTES (2u * 1024u * 1024u)

static int valid_challenge(const char *value) {
    if (strlen(value) != 36) return 0;
    int nonzero = 0;
    for (size_t i = 0; i < 36; ++i) {
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (value[i] != '-') return 0;
        } else {
            if (!((value[i] >= '0' && value[i] <= '9') || (value[i] >= 'a' && value[i] <= 'f'))) return 0;
            nonzero |= value[i] != '0';
        }
    }
    return nonzero;
}

static void pattern(unsigned char unit[64], const char *challenge) {
    memset(unit, '\n', 64);
    const char prefix[] = "dory-mapped-page-v1:";
    memcpy(unit, prefix, sizeof(prefix) - 1);
    memcpy(unit + sizeof(prefix) - 1, challenge, 36);
}

static int incomplete(const char *reason) {
    fprintf(stderr, "mapped-page-retry: %s (errno=%d)\n", reason, errno);
    return 78;
}

#ifdef __linux__
static sigjmp_buf recovery;
static volatile sig_atomic_t signal_seen;
static volatile sig_atomic_t signal_code;
static volatile uintptr_t signal_address;
static volatile uintptr_t nominated_address;

static void fault_handler(int signum, siginfo_t *info, void *context) {
    (void)context;
    if (signum != SIGBUS || (uintptr_t)info->si_addr != nominated_address) _exit(87);
    signal_seen = signum;
    signal_code = info->si_code;
    signal_address = (uintptr_t)info->si_addr;
    siglongjmp(recovery, 1);
}

static uint64_t milliseconds(void) {
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) return UINT64_MAX;
    return (uint64_t)now.tv_sec * 1000u + (uint64_t)now.tv_nsec / 1000000u;
}

static int write_record(int directory, const char *name, const char *record) {
    int fd = openat(directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) return -1;
    size_t length = strlen(record), offset = 0;
    int interruptions = 0;
    while (offset < length) {
        ssize_t count = write(fd, record + offset, length - offset);
        if (count < 0 && errno == EINTR && interruptions++ < 8) continue;
        if (count <= 0) { close(fd); return -1; }
        offset += (size_t)count;
    }
    int result = fsync(fd);
    close(fd);
    return result == 0 ? fsync(directory) : -1;
}

static int physical_page(unsigned char *mapping, uint64_t *physical) {
    char path[64];
    snprintf(path, sizeof(path), "/proc/%ld/pagemap", (long)getpid());
    int fd = open(path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW);
    if (fd < 0) return -1;
    uint64_t first = 0;
    /* Every 4 KiB page must be resident, exclusive and physically contiguous. mlock and
     * a private collapsed huge mapping reduce migration; recheck immediately before access. */
    for (size_t offset = 0; offset < HUGE_BYTES; offset += 4096) {
        uint64_t entry = 0;
        off_t index = (off_t)(((uintptr_t)mapping + offset) / 4096u * sizeof(entry));
        if (pread(fd, &entry, sizeof(entry), index) != (ssize_t)sizeof(entry)
            || !(entry & (UINT64_C(1) << 63)) || (entry & (UINT64_C(1) << 62))
            || !(entry & (UINT64_C(1) << 56))) { close(fd); return -1; }
        uint64_t frame = entry & ((UINT64_C(1) << 55) - 1);
        if (!frame) { close(fd); return -1; }
        if (offset == 0) first = frame;
        if (frame != first + offset / 4096u) { close(fd); return -1; }
    }
    close(fd);
    *physical = first * 4096u;
    return *physical % HOST_PAGE_BYTES == 0 ? 0 : -1;
}

static int run_probe(const char *challenge) {
    struct utsname system;
    if (uname(&system) != 0 || strcmp(system.machine, "aarch64") != 0 || sysconf(_SC_PAGESIZE) != 4096)
        return incomplete("requires the ARM64 Ubuntu guest's 4 KiB page ABI");
    char boot[37] = {0};
    int boot_fd = open("/proc/sys/kernel/random/boot_id", O_RDONLY | O_NOFOLLOW | O_CLOEXEC);
    if (boot_fd < 0 || read(boot_fd, boot, 36) != 36 || !valid_challenge(boot)) {
        if (boot_fd >= 0) close(boot_fd);
        return incomplete("boot identity unavailable");
    }
    close(boot_fd);
    cpu_set_t affinity;
    CPU_ZERO(&affinity); CPU_SET(0, &affinity);
    if (sched_setaffinity(0, sizeof(affinity), &affinity) != 0) return incomplete("cannot bind scratch owner to vCPU 0");
    unsigned char *reservation = mmap(NULL, 2 * HUGE_BYTES, PROT_READ | PROT_WRITE,
                                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (reservation == MAP_FAILED) return incomplete("scratch allocation failed");
    uintptr_t aligned = ((uintptr_t)reservation + HUGE_BYTES - 1) & ~(uintptr_t)(HUGE_BYTES - 1);
    size_t prefix = aligned - (uintptr_t)reservation;
    size_t suffix = 2 * HUGE_BYTES - prefix - HUGE_BYTES;
    if ((prefix && munmap(reservation, prefix) != 0)
        || (suffix && munmap((void *)(aligned + HUGE_BYTES), suffix) != 0))
        return incomplete("cannot isolate aligned scratch mapping");
    unsigned char *mapping = (unsigned char *)aligned;
    unsigned char unit[64]; pattern(unit, challenge);
    if (madvise(mapping, HUGE_BYTES, MADV_HUGEPAGE) != 0
        || madvise(mapping, HUGE_BYTES, MADV_UNMERGEABLE) != 0
        || madvise(mapping, HUGE_BYTES, MADV_DONTFORK) != 0) return incomplete("scratch advice failed");
    for (size_t i = 0; i < HUGE_BYTES; i += sizeof(unit)) memcpy(mapping + i, unit, sizeof(unit));
    if (madvise(mapping, HUGE_BYTES, MADV_COLLAPSE) != 0) return incomplete("private huge-page collapse failed");
    struct rlimit limit;
    if (getrlimit(RLIMIT_MEMLOCK, &limit) != 0) return incomplete("cannot inspect memory-lock limit");
    if (limit.rlim_cur < HUGE_BYTES) {
        limit.rlim_cur = HUGE_BYTES;
        if (setrlimit(RLIMIT_MEMLOCK, &limit) != 0) return incomplete("cannot raise bounded memory-lock limit");
    }
    if (mlock(mapping, HUGE_BYTES) != 0) return incomplete("cannot retain resident scratch mapping");
    uint64_t physical = 0;
    if (physical_page(mapping, &physical) != 0) return incomplete("scratch physical ownership is not provable");
    struct sigaction action;
    memset(&action, 0, sizeof(action)); sigemptyset(&action.sa_mask);
    action.sa_sigaction = fault_handler; action.sa_flags = SA_SIGINFO;
    if (sigaction(SIGBUS, &action, NULL) != 0) return incomplete("cannot install guest-fault witness");
    nominated_address = (uintptr_t)mapping;
    char path[96]; snprintf(path, sizeof(path), "/run/dory-mapped-page-%s", challenge);
    if (mkdir(path, 0700) != 0) return incomplete("scratch receipt directory already exists or is unavailable");
    int directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    struct stat info;
    if (directory < 0 || fstat(directory, &info) != 0 || info.st_uid != geteuid()
        || (info.st_mode & 0777) != 0700) return incomplete("scratch receipt authority rejected");
    char record[1536];
    snprintf(record, sizeof(record), "{\"kind\":\"dev.dory.mapped-page-retry-guest-ready@1\","
             "\"challenge\":\"%s\",\"bootID\":\"%s\",\"processID\":%ld,\"virtualCPU\":0,"
             "\"guestPhysicalAddress\":%" PRIu64 ",\"virtualAddress\":%" PRIuPTR ","
             "\"scratchBytes\":%u,\"hostPageBytes\":%u}\n",
             challenge, boot, (long)getpid(), physical, (uintptr_t)mapping, HUGE_BYTES, HOST_PAGE_BYTES);
    if (write_record(directory, "ready.json", record) != 0) return incomplete("ready receipt was not durable");
    uint64_t deadline = milliseconds() + 60000u;
    while (milliseconds() < deadline) {
        int trigger = openat(directory, "trigger", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK);
        if (trigger >= 0) {
            char value[37] = {0};
            int valid = fstat(trigger, &info) == 0 && S_ISREG(info.st_mode) && info.st_uid == geteuid()
                && info.st_nlink == 1 && info.st_size == 36 && (info.st_mode & 077) == 0
                && read(trigger, value, 36) == 36 && strcmp(value, challenge) == 0;
            close(trigger);
            if (!valid) return incomplete("trigger does not match the owned challenge");
            break;
        }
        if (errno != ENOENT) return incomplete("trigger lookup failed");
        struct timespec delay = {0, 20000000}; nanosleep(&delay, NULL);
    }
    if (milliseconds() >= deadline) return incomplete("host did not arm and trigger the fault in time");
    uint64_t current_physical = 0;
    if (physical_page(mapping, &current_physical) != 0 || current_physical != physical)
        return incomplete("scratch pages migrated before the nominated access");
    if (sigsetjmp(recovery, 1) == 0) {
        volatile unsigned char observed = *(volatile unsigned char *)mapping;
        (void)observed;
    }
    if (signal_seen != SIGBUS || signal_address != (uintptr_t)mapping)
        return incomplete("nominated read did not produce the guest-visible fault");
    for (size_t i = 0; i < HOST_PAGE_BYTES; ++i)
        if (((volatile unsigned char *)mapping)[i] != unit[i % sizeof(unit)])
            return incomplete("restored scratch bytes changed");
    snprintf(record, sizeof(record), "{\"kind\":\"dev.dory.mapped-page-retry-guest-result@1\","
             "\"status\":\"PASS\",\"challenge\":\"%s\",\"bootID\":\"%s\",\"processID\":%ld,"
             "\"virtualCPU\":0,\"guestPhysicalAddress\":%" PRIu64 ",\"virtualAddress\":%" PRIuPTR ","
             "\"signal\":%d,\"signalCode\":%d,\"signalAddress\":%" PRIuPTR ","
             "\"guestFaultObserved\":true,\"unchangedPageReadable\":true}\n",
             challenge, boot, (long)getpid(), physical, (uintptr_t)mapping,
             (int)signal_seen, (int)signal_code, (uintptr_t)signal_address);
    int result = write_record(directory, "result.json", record);
    close(directory); munlock(mapping, HUGE_BYTES); munmap(mapping, HUGE_BYTES);
    return result == 0 ? 0 : incomplete("fault result was not durable");
}
#endif

int main(int argc, char **argv) {
    if (argc != 3 || !valid_challenge(argv[2])) return incomplete("usage: mapped-page-retry --challenge|--pattern CANONICAL-UUID");
    if (strcmp(argv[1], "--pattern") == 0) {
        unsigned char unit[64]; pattern(unit, argv[2]);
        for (size_t i = 0; i < HOST_PAGE_BYTES / sizeof(unit); ++i)
            if (fwrite(unit, sizeof(unit), 1, stdout) != 1) return 1;
        return 0;
    }
    if (strcmp(argv[1], "--challenge") != 0) return incomplete("unknown mode");
#ifdef __linux__
    return run_probe(argv[2]);
#else
    return incomplete("fault witness requires ARM Linux; pattern output is portable");
#endif
}
