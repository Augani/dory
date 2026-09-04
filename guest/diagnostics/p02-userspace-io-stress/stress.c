/* Guest-only raw virtio block and Ethernet engineering checks. Never run on host. */
#define _GNU_SOURCE 1
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/utsname.h>
#include <time.h>
#include <unistd.h>

#ifndef DORY_STRESS_SOURCE_SHA256
#error Build through the adjacent Makefile to bind source identity.
#endif

#if defined(__linux__) && defined(__x86_64__)
#include <arpa/inet.h>
#include <linux/fs.h>
#include <linux/if_packet.h>
#include <net/if.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/resource.h>
#include <sys/socket.h>

enum { FRAME_BYTES = 1024, DATA_BYTES = 980, REGION_BYTES = 128 * 1024,
       BLOCK_ROUNDS = 8, MIN_FRAMES = 4096, MAX_FRAMES = 16384, MAX_IRRELEVANT = 64 };
static const uint64_t disk_bytes = UINT64_C(32) * 1024 * 1024;
static const off_t region_offset = 1024 * 1024;
static const unsigned char guest_mac[6] = {0x02, 0xd0, 0x52, 0x00, 0x00, 0x01};
static const unsigned char peer_mac[6] = {0x02, 0xd0, 0x52, 0x00, 0x00, 0x02};
static char run_id[37];
static unsigned char uuid_bytes[16];
static int64_t last_clock, overall_deadline;
static const char *failure = "incomplete_or_invalid";
static uint32_t frames;
static int64_t network_elapsed;

static bool fail(const char *reason) { failure = reason; return false; }

static int hex(char c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    return -1;
}

static bool parse_uuid(const char *value)
{
    if (strlen(value) != 36) return false;
    size_t n = 0;
    for (size_t i = 0; i < 36;) {
        if (i == 8 || i == 13 || i == 18 || i == 23) {
            if (value[i++] != '-') return false;
        } else {
            int a = hex(value[i++]), b = hex(value[i++]);
            if (a < 0 || b < 0 || n == sizeof(uuid_bytes)) return false;
            uuid_bytes[n++] = (unsigned char)((a << 4) | b);
        }
    }
    memcpy(run_id, value, sizeof(run_id));
    return n == sizeof(uuid_bytes);
}

static bool guest_guard(void)
{
    struct utsname platform;
    if (uname(&platform) != 0 || strcmp(platform.sysname, "Linux") != 0 ||
        strcmp(platform.machine, "x86_64") != 0 || getpid() == 1) return false;
    int fd = open("/proc/cmdline", O_RDONLY | O_CLOEXEC);
    if (fd < 0) return false;
    char data[8193];
    size_t size = 0;
    bool ok = true;
    while (size < sizeof(data)) {
        ssize_t count = read(fd, data + size, sizeof(data) - size);
        if (count < 0 && errno == EINTR) continue;
        if (count < 0) { ok = false; break; }
        if (count == 0) break;
        size += (size_t)count;
    }
    if (close(fd) != 0) ok = false;
    if (!ok || size == sizeof(data) || memchr(data, 0, size) != NULL) return false;
    data[size] = 0;
    char *save = NULL;
    unsigned matches = 0;
    for (char *token = strtok_r(data, " \t\r\n", &save); token; token = strtok_r(NULL, " \t\r\n", &save)) {
        const char key[] = "dory.pvh_run_id=";
        if (strncmp(token, key, sizeof(key) - 1) != 0) continue;
        if (++matches != 1 || !parse_uuid(token + sizeof(key) - 1)) return false;
    }
    return matches == 1;
}

static bool now_ns(int64_t *value)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0 || now.tv_sec < 0 ||
        now.tv_sec > INT64_MAX / INT64_C(1000000000) - 60 ||
        now.tv_nsec < 0 || now.tv_nsec >= 1000000000L) return fail("monotonic_clock_invalid");
    *value = (int64_t)now.tv_sec * INT64_C(1000000000) + now.tv_nsec;
    if (*value < last_clock) return fail("monotonic_clock_regressed");
    last_clock = *value;
    return true;
}

static bool budget(int64_t deadline)
{
    int64_t now;
    return now_ns(&now) && ((now < deadline && now < overall_deadline) || fail("deadline_exhausted"));
}

static bool emit(const char *name, bool passed)
{
    return printf("DORY_P02_RESULT {\"schemaVersion\":1,\"kind\":\"userspace-result\","
        "\"runUUID\":\"%s\",\"name\":\"%s\",\"status\":\"%s\",\"detail\":\"%s\","
        "\"sourceSHA256\":\"%s\",\"frames\":%" PRIu32 ",\"frameBytes\":1024,"
        "\"networkBytes\":%" PRIu64 ",\"elapsedNanoseconds\":%" PRId64 ","
        "\"blockRounds\":8,\"blockOffset\":1048576,\"blockBytes\":131072}\n",
        run_id, name, passed ? "pass" : "fail", passed ? "validated_within_fixed_limits" : failure,
        DORY_STRESS_SOURCE_SHA256, frames, (uint64_t)frames * FRAME_BYTES, network_elapsed) > 0 && fflush(stdout) == 0;
}

static int open_block(int access)
{
    int fd = open("/dev/vda", access | O_CLOEXEC | O_NOFOLLOW | O_EXCL);
    if (fd < 0) { (void)fail("block_open_failed"); return -1; }
    struct stat st;
    uint64_t size = 0;
    if (fstat(fd, &st) != 0 || !S_ISBLK(st.st_mode) || ioctl(fd, BLKGETSIZE64, &size) != 0 || size != disk_bytes) {
        (void)close(fd);
        (void)fail("block_identity_or_size_differs");
        return -1;
    }
    return fd;
}

static bool block_transfer(int fd, unsigned char *bytes, bool write_access, int64_t deadline)
{
    size_t completed = 0;
    while (completed < REGION_BYTES) {
        if (!budget(deadline)) return false;
        ssize_t count = write_access ?
            pwrite(fd, bytes + completed, REGION_BYTES - completed, region_offset + (off_t)completed) :
            pread(fd, bytes + completed, REGION_BYTES - completed, region_offset + (off_t)completed);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return fail("block_transfer_failed");
        completed += (size_t)count;
    }
    return true;
}

static bool block_stage(void)
{
    int64_t start;
    if (!now_ns(&start)) return false;
    int64_t deadline = start + INT64_C(30000000000);
    unsigned char *expected = malloc(REGION_BYTES), *observed = malloc(REGION_BYTES);
    if (!expected || !observed) { free(expected); free(observed); return fail("allocation_failed"); }
    for (size_t i = 0; i < REGION_BYTES; ++i) expected[i] = (unsigned char)(i * 37u + (i >> 8));
    bool ok = true;
    for (unsigned round = 0; ok && round < BLOCK_ROUNDS; ++round) {
        if (!budget(deadline)) { ok = false; break; }
        int fd = open_block(O_RDWR);
        if (fd < 0) { ok = false; break; }
        ok = block_transfer(fd, expected, true, deadline);
        if (ok && fsync(fd) != 0) ok = fail("block_fsync_failed");
        if (close(fd) != 0) ok = fail("block_close_failed");
        if (!ok || !budget(deadline)) { ok = false; break; }
        fd = open_block(O_RDONLY);
        if (fd < 0) { ok = false; break; }
        memset(observed, 0, REGION_BYTES);
        ok = block_transfer(fd, observed, false, deadline);
        if (close(fd) != 0) ok = fail("block_reopened_close_failed");
        if (ok && memcmp(expected, observed, REGION_BYTES) != 0) ok = fail("block_reopened_bytes_differ");
    }
    free(expected);
    free(observed);
    return ok && budget(deadline);
}

static bool wait_socket(int fd, short events, int64_t deadline)
{
    for (;;) {
        if (!budget(deadline)) return false;
        struct pollfd item = {fd, events, 0};
        int rc = poll(&item, 1, 10);
        if (rc < 0 && errno == EINTR) continue;
        if (rc < 0 || (item.revents & (POLLERR | POLLHUP | POLLNVAL))) return fail("packet_poll_failed");
        if (rc > 0 && (item.revents & events)) return true;
    }
}

static void frame_bytes(unsigned char *frame, uint32_t sequence, bool reply)
{
    memcpy(frame, reply ? guest_mac : peer_mac, 6);
    memcpy(frame + 6, reply ? peer_mac : guest_mac, 6);
    frame[12] = 0x88; frame[13] = 0xb5;
    memcpy(frame + 14, "DORYIO01", 8);
    memcpy(frame + 22, uuid_bytes, 16);
    frame[38] = (unsigned char)(sequence >> 24); frame[39] = (unsigned char)(sequence >> 16);
    frame[40] = (unsigned char)(sequence >> 8); frame[41] = (unsigned char)sequence;
    frame[42] = (unsigned char)(DATA_BYTES >> 8); frame[43] = (unsigned char)DATA_BYTES;
    for (unsigned i = 0; i < DATA_BYTES; ++i)
        frame[44 + i] = (unsigned char)(sequence * 17u + i * 37u + (i >> 8));
}

static bool paced_until(int64_t target, int64_t deadline)
{
    for (;;) {
        int64_t now;
        if (!budget(deadline) || !now_ns(&now)) return false;
        if (now >= target) return true;
        int64_t duration = target - now;
        struct timespec pause = {(time_t)(duration / INT64_C(1000000000)), (long)(duration % INT64_C(1000000000))};
        if (nanosleep(&pause, NULL) != 0 && errno != EINTR) return fail("packet_pacing_sleep_failed");
    }
}

static bool network_stage(void)
{
    int fd = socket(AF_PACKET, SOCK_RAW | SOCK_CLOEXEC | SOCK_NONBLOCK, htons(0x88b5));
    if (fd < 0) return fail("packet_socket_failed");
    bool ok = true;
    struct ifreq interface;
    memset(&interface, 0, sizeof(interface));
    memcpy(interface.ifr_name, "eth0", 5);
    if (ioctl(fd, SIOCGIFINDEX, &interface) != 0) ok = fail("interface_index_failed");
    int index = interface.ifr_ifindex;
    if (ok && (ioctl(fd, SIOCGIFHWADDR, &interface) != 0 ||
               memcmp(interface.ifr_hwaddr.sa_data, guest_mac, 6) != 0)) ok = fail("interface_mac_differs");
    if (ok && ioctl(fd, SIOCGIFFLAGS, &interface) != 0) ok = fail("interface_flags_failed");
    interface.ifr_flags |= IFF_UP;
    if (ok && ioctl(fd, SIOCSIFFLAGS, &interface) != 0) ok = fail("interface_up_failed");
    int ignore_outgoing = 1;
    if (ok && setsockopt(fd, SOL_PACKET, PACKET_IGNORE_OUTGOING, &ignore_outgoing, sizeof(ignore_outgoing)) != 0)
        ok = fail("packet_ignore_outgoing_failed");
    struct sockaddr_ll address;
    memset(&address, 0, sizeof(address));
    address.sll_family = AF_PACKET;
    address.sll_protocol = htons(0x88b5);
    address.sll_ifindex = index;
    address.sll_halen = 6;
    memcpy(address.sll_addr, peer_mac, 6);
    if (ok && bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0) ok = fail("packet_bind_failed");
    int64_t start = 0;
    if (ok) ok = now_ns(&start);
    int64_t deadline = start + INT64_C(30000000000), next_send = start, first_send = 0;
    unsigned irrelevant = 0;
    while (ok) {
        int64_t now;
        if (!budget(deadline) || !now_ns(&now)) { ok = false; break; }
        if (frames >= MIN_FRAMES && network_elapsed >= INT64_C(5000000000)) break;
        if (frames == MAX_FRAMES) { ok = fail("packet_frame_budget_exhausted"); break; }
        if (!paced_until(next_send, deadline)) { ok = false; break; }
        unsigned char request[FRAME_BYTES], expected[FRAME_BYTES], response[FRAME_BYTES + 1];
        frame_bytes(request, frames, false);
        frame_bytes(expected, frames, true);
        ssize_t sent;
        for (;;) {
            if (!budget(deadline) || !now_ns(&now)) { ok = false; break; }
            sent = sendto(fd, request, sizeof(request), 0, (struct sockaddr *)&address, sizeof(address));
            if (sent < 0 && errno == EINTR) continue;
            if (sent < 0 && (errno == EAGAIN || errno == EWOULDBLOCK)) {
                if (!wait_socket(fd, POLLOUT, deadline)) { ok = false; break; }
                continue;
            }
            if (sent != FRAME_BYTES) ok = fail("packet_send_failed");
            else if (frames == 0) first_send = now;
            break;
        }
        if (!ok || !now_ns(&now)) { ok = false; break; }
        next_send = now + INT64_C(1250000);
        bool acknowledged = false;
        while (ok && !acknowledged) {
            if (!wait_socket(fd, POLLIN, deadline)) { ok = false; break; }
            struct sockaddr_ll origin;
            memset(&origin, 0, sizeof(origin));
            socklen_t length = sizeof(origin);
            ssize_t received = recvfrom(fd, response, sizeof(response), MSG_TRUNC, (struct sockaddr *)&origin, &length);
            if (received < 0 && (errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK)) continue;
            if (received < 0) { ok = fail("packet_receive_failed"); break; }
            if (length < sizeof(origin) || origin.sll_ifindex != index || origin.sll_pkttype != PACKET_HOST ||
                received < 14 || response[12] != 0x88 || response[13] != 0xb5 ||
                memcmp(response, guest_mac, 6) != 0 || memcmp(response + 6, peer_mac, 6) != 0) {
                if (++irrelevant > MAX_IRRELEVANT) ok = fail("packet_irrelevant_budget_exhausted");
                continue;
            }
            if (received != FRAME_BYTES || memcmp(response, expected, FRAME_BYTES) != 0) {
                ok = fail("packet_reply_content_differs");
                break;
            }
            acknowledged = true;
        }
        if (ok && acknowledged) {
            if (!now_ns(&now)) { ok = false; break; }
            ++frames;
            network_elapsed = now - first_send;
        }
    }
    if (close(fd) != 0) ok = fail("packet_close_failed");
    return ok && frames >= MIN_FRAMES && frames <= MAX_FRAMES &&
           network_elapsed >= INT64_C(5000000000) && budget(deadline);
}

int main(int argc, char **argv)
{
    if (argc != 2 || strcmp(argv[1], "--run") != 0 || !guest_guard()) {
        fputs("Requires supervised Linux x86_64 guest, canonical dory.pvh_run_id and --run\n", stderr);
        return 2;
    }
    int64_t started;
    if (!now_ns(&started)) return 2;
    overall_deadline = started + INT64_C(60000000000);
    const struct rlimit core = {0, 0}, descriptors = {32, 32}, cpu = {60, 60}, output = {32768, 32768};
    if (setrlimit(RLIMIT_CORE, &core) != 0 || setrlimit(RLIMIT_NOFILE, &descriptors) != 0 ||
        setrlimit(RLIMIT_CPU, &cpu) != 0 || setrlimit(RLIMIT_FSIZE, &output) != 0) return 2;
    bool passed = block_stage();
    if (!emit("io.block_flush_reopen", passed) || !passed) return 1;
    passed = network_stage();
    if (!emit("io.ethernet_frame_roundtrip", passed) || !passed || !budget(overall_deadline)) return 1;
    if (printf("{\"schemaVersion\":1,\"doryPVHBoot\":\"userspace-ready\",\"runID\":\"%s\","
               "\"workloadsPassed\":true,\"sourceSHA256\":\"%s\",\"workloads\":["
               "\"io.block_flush_reopen\",\"io.ethernet_frame_roundtrip\"],"
               "\"ioNetwork\":{\"frames\":%" PRIu32 ",\"bytes\":%" PRIu64 ",\"elapsedNanoseconds\":%" PRId64 "}}\n",
               run_id, DORY_STRESS_SOURCE_SHA256, frames, (uint64_t)frames * FRAME_BYTES,
               network_elapsed) < 0 || fflush(stdout) != 0) return 1;
    return 0;
}
#else
int main(void)
{
    fputs("This workload requires a Linux x86_64 guest; never execute it on host.\n", stderr);
    return 2;
}
#endif
