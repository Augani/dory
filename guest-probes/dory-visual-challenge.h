#ifndef DORY_VISUAL_CHALLENGE_H
#define DORY_VISUAL_CHALLENGE_H

#include <stddef.h>
#include <stdint.h>
#include <inttypes.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <time.h>
#include <unistd.h>

#define DORY_VISUAL_CHALLENGE_COLUMNS 12u
#define DORY_VISUAL_CHALLENGE_ROWS 10u
#define DORY_VISUAL_CHALLENGE_PAYLOAD_BITS 80u

struct dory_visual_color {
    uint8_t red;
    uint8_t green;
    uint8_t blue;
    uint8_t alpha;
};

static const struct dory_visual_color dory_visual_border = {6, 10, 20, 255};
static const struct dory_visual_color dory_visual_top_left = {244, 67, 54, 255};
static const struct dory_visual_color dory_visual_top_right = {76, 175, 80, 255};
static const struct dory_visual_color dory_visual_bottom_left = {33, 150, 243, 255};
static const struct dory_visual_color dory_visual_bottom_right = {255, 235, 59, 255};
static const struct dory_visual_color dory_visual_zero = {24, 52, 92, 255};
static const struct dory_visual_color dory_visual_one = {64, 224, 196, 255};

static uint64_t dory_visual_fnv1a(const void *bytes, size_t count, uint64_t hash)
{
    const uint8_t *cursor = bytes;
    for (size_t index = 0; index < count; index++) {
        hash ^= cursor[index];
        hash *= UINT64_C(1099511628211);
    }
    return hash;
}

static uint64_t dory_visual_challenge_hash(const char *nonce, uint32_t frame_marker)
{
    uint64_t hash = dory_visual_fnv1a(
        nonce, strlen(nonce), UINT64_C(14695981039346656037));
    uint8_t little_endian_frame[4] = {
        (uint8_t)frame_marker,
        (uint8_t)(frame_marker >> 8),
        (uint8_t)(frame_marker >> 16),
        (uint8_t)(frame_marker >> 24),
    };
    return dory_visual_fnv1a(little_endian_frame, sizeof(little_endian_frame), hash);
}

static struct dory_visual_color dory_visual_cell_color(
    uint32_t column, uint32_t row, uint64_t challenge_hash, uint16_t frame_marker)
{
    if (column == 0 && row == 0)
        return dory_visual_top_left;
    if (column + 1 == DORY_VISUAL_CHALLENGE_COLUMNS && row == 0)
        return dory_visual_top_right;
    if (column == 0 && row + 1 == DORY_VISUAL_CHALLENGE_ROWS)
        return dory_visual_bottom_left;
    if (column + 1 == DORY_VISUAL_CHALLENGE_COLUMNS &&
        row + 1 == DORY_VISUAL_CHALLENGE_ROWS)
        return dory_visual_bottom_right;
    if (column == 0 || row == 0 ||
        column + 1 == DORY_VISUAL_CHALLENGE_COLUMNS ||
        row + 1 == DORY_VISUAL_CHALLENGE_ROWS)
        return dory_visual_border;

    uint32_t bit_index = (row - 1) * 10u + (column - 1);
    uint32_t bit = bit_index < 64u
        ? (uint32_t)((challenge_hash >> bit_index) & UINT64_C(1))
        : (uint32_t)((frame_marker >> (bit_index - 64u)) & 1u);
    return bit ? dory_visual_one : dory_visual_zero;
}

static uint32_t dory_visual_cell_size(uint32_t width, uint32_t height)
{
    uint32_t size = width / 80u;
    uint32_t vertical = height / 50u;
    if (vertical < size)
        size = vertical;
    if (size < 8u)
        size = 8u;
    if (size > 20u)
        size = 20u;
    return size;
}

static int dory_visual_publish_presented(
    const char *path, const char *nonce, uint32_t frame_marker)
{
    if (!path)
        return 0;
    if (path[0] != '/' || !nonce || !*nonce || frame_marker == 0 ||
        frame_marker > UINT16_MAX) {
        errno = EINVAL;
        return -1;
    }
    static const char suffix[] = ".tmp.XXXXXX";
    const size_t path_length = strlen(path);
    if (path_length > PATH_MAX - sizeof(suffix)) {
        errno = ENAMETOOLONG;
        return -1;
    }
    char temporary[PATH_MAX];
    memcpy(temporary, path, path_length);
    memcpy(temporary + path_length, suffix, sizeof(suffix));
    int descriptor = mkstemp(temporary);
    if (descriptor < 0)
        return -1;
    if (fcntl(descriptor, F_SETFD, FD_CLOEXEC) != 0) {
        const int saved_errno = errno;
        (void)close(descriptor);
        (void)unlink(temporary);
        errno = saved_errno;
        return -1;
    }
    char marker[96];
    const int marker_length = snprintf(
        marker, sizeof(marker),
        "dory-visual-presented:fnv1a64:%016" PRIx64 ":%u\n",
        dory_visual_challenge_hash(nonce, frame_marker), frame_marker);
    if (marker_length <= 0 || marker_length >= (int)sizeof(marker)) {
        (void)close(descriptor);
        (void)unlink(temporary);
        errno = EOVERFLOW;
        return -1;
    }
    size_t cursor = 0;
    while (cursor < (size_t)marker_length) {
        const ssize_t written = write(
            descriptor, marker + cursor, (size_t)marker_length - cursor);
        if (written < 0 && errno == EINTR)
            continue;
        if (written <= 0) {
            const int saved_errno = errno ? errno : EIO;
            (void)close(descriptor);
            (void)unlink(temporary);
            errno = saved_errno;
            return -1;
        }
        cursor += (size_t)written;
    }
    const int close_result = close(descriptor);
    if (close_result != 0) {
        const int saved_errno = errno ? errno : EIO;
        (void)unlink(temporary);
        errno = saved_errno;
        return -1;
    }
    /* link() publishes all bytes in one step and refuses an existing/stale marker.
     * rename() would overwrite it, weakening the one-run path authority. */
    if (link(temporary, path) != 0) {
        const int saved_errno = errno;
        (void)unlink(temporary);
        errno = saved_errno;
        return -1;
    }
    (void)unlink(temporary);
    return 0;
}

static int dory_visual_parse_hold_milliseconds(const char *value, uint32_t *milliseconds)
{
    if (!value || !*value || !milliseconds)
        return -1;
    errno = 0;
    char *end = NULL;
    unsigned long parsed = strtoul(value, &end, 10);
    if (errno != 0 || end == value || *end != '\0' || parsed > 30000u)
        return -1;
    *milliseconds = (uint32_t)parsed;
    return 0;
}

static int dory_visual_hold_milliseconds(uint32_t milliseconds)
{
    struct timespec remaining = {
        .tv_sec = milliseconds / 1000u,
        .tv_nsec = (long)(milliseconds % 1000u) * 1000000L,
    };
    while (nanosleep(&remaining, &remaining) != 0) {
        if (errno != EINTR)
            return -1;
    }
    return 0;
}

#endif
