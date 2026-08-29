#include "DoryVirglRendererShim.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#if defined(DORY_VIRGL_RENDERER_DUAL_METAL)
#include <epoxy/egl.h>
#include <epoxy/gl.h>
#endif

enum {
    DORY_VIRGL_RENDERER_CALLBACKS_VERSION = 4,
    DORY_VIRGL_RENDERER_LOG_LEVEL_ERROR = 3,
    DORY_VIRGL_CREATE_OBJECT_SUBTYPE_ABSENT = 0,
    DORY_VIRGL_CREATE_OBJECT_SUBTYPE_PRESENT = 1,
    DORY_VIRGL_CREATE_OBJECT_SUBTYPE_AMBIGUOUS = 2,
    DORY_VIRGL_FAILED_COMMAND_LOCATION_ABSENT = 0,
    DORY_VIRGL_FAILED_COMMAND_LOCATION_PRESENT = 1,
    DORY_VIRGL_FAILED_COMMAND_LOCATION_AMBIGUOUS = 2,
    DORY_VIRGL_CREATE_OBJECT_CANDIDATE_COUNT_MAX = 255,
    DORY_VIRGL_CREATE_OBJECT_SUBTYPE_MAX = 11,
    DORY_VIRGL_OBJECT_SURFACE = 8,
    DORY_VIRGL_SURFACE_FAILURE_REASON_NONE = 0,
    DORY_VIRGL_SURFACE_FAILURE_REASON_MAX = 7,
    DORY_VIRGL_PRECURSOR_NONE = 0,
    DORY_VIRGL_PRECURSOR_SHADER_COMPILE_FAILED = 1,
    DORY_VIRGL_PRECURSOR_TGSI_ASSIGNMENT_FAILED = 2,
    DORY_VIRGL_PRECURSOR_GEOMETRY_SHADER_UNSUPPORTED = 3,
    DORY_VIRGL_PRECURSOR_TESSELLATION_SHADER_UNSUPPORTED = 4,
    DORY_VIRGL_PRECURSOR_COMPUTE_SHADER_UNSUPPORTED = 5,
    DORY_VIRGL_PRECURSOR_INVALID_EXPECTED_TOKEN_COUNT = 6,
    DORY_VIRGL_PRECURSOR_EXPECTED_LONG_CONTINUATION = 7,
    DORY_VIRGL_PRECURSOR_INVALID_CONTINUATION_HANDLE = 8,
    DORY_VIRGL_PRECURSOR_CONTINUATION_WITHOUT_ORIGINAL = 9,
    DORY_VIRGL_PRECURSOR_MISMATCHED_CONTINUATION = 10,
    DORY_VIRGL_PRECURSOR_OVERSIZED_CONTINUATION = 11,
};

typedef void (*DoryVirglRendererLogCallback)(
    int32_t log_level,
    const char *message,
    void *user_data
);
typedef void (*DoryVirglRendererFreeDataCallback)(void *user_data);

/*
 * App Sandbox permits POSIX shared-memory names only inside an app group. This short macOS-only
 * group is dedicated to the renderer worker and deliberately differs from Dory's data-sharing
 * group. virglrenderer's anonymous-file helper reads this fixed integration value when it creates
 * timeline and blob SHM; an inherited value must never select a broader group.
 */
static const char dory_renderer_app_sandbox_group[] =
    "864H636QW4.dory-renderer";

#if defined(DORY_VIRGL_RENDERER_STATIC_LINKED)
extern int32_t virgl_renderer_init(
    void *,
    int32_t,
    DoryVirglRendererCallbacks *
);
extern void virgl_renderer_cleanup(void *);
extern void virgl_renderer_get_cap_set(
    uint32_t,
    uint32_t *,
    uint32_t *
);
extern void virgl_renderer_fill_caps(
    uint32_t,
    uint32_t,
    void *
);
extern int32_t virgl_renderer_context_create_with_flags(
    uint32_t,
    uint32_t,
    uint32_t,
    const char *
);
extern void virgl_renderer_context_destroy(uint32_t);
extern void virgl_renderer_ctx_attach_resource(
    int32_t,
    int32_t
);
extern void virgl_renderer_ctx_detach_resource(
    int32_t,
    int32_t
);
extern int32_t virgl_renderer_submit_cmd2(
    void *,
    int32_t,
    int32_t,
    uint64_t *,
    uint32_t
);
extern int32_t virgl_renderer_resource_create_blob(
    const DoryVirglRendererBlobCreateArguments *
);
extern int32_t virgl_renderer_resource_create(
    DoryVirglRendererResource3DCreateArguments *,
    struct iovec *,
    uint32_t
);
extern int32_t virgl_renderer_resource_attach_iov(
    int32_t,
    struct iovec *,
    int32_t
);
extern void virgl_renderer_resource_detach_iov(
    int32_t,
    struct iovec **,
    int32_t *
);
extern void virgl_renderer_resource_unref(uint32_t);
extern int32_t virgl_renderer_resource_get_map_info(
    uint32_t,
    uint32_t *
);
extern int32_t virgl_renderer_resource_export_blob(
    uint32_t,
    uint32_t *,
    int *
);
extern int32_t virgl_renderer_resource_get_info(
    int32_t,
    DoryVirglRendererResourceInfo *
);
extern int32_t virgl_renderer_create_handle_for_scanout(
    uint32_t,
    uint32_t,
    uint32_t,
    uint32_t,
    uint32_t,
    uint32_t,
    uint32_t,
    void **
);
extern void virgl_renderer_release_handle_for_scanout(int32_t, void *);
extern int32_t virgl_renderer_transfer_write_iov(
    uint32_t,
    uint32_t,
    int32_t,
    uint32_t,
    uint32_t,
    DoryVirglRendererBox *,
    uint64_t,
    struct iovec *,
    uint32_t
);
extern int32_t virgl_renderer_transfer_read_iov(
    uint32_t,
    uint32_t,
    uint32_t,
    uint32_t,
    uint32_t,
    DoryVirglRendererBox *,
    uint64_t,
    struct iovec *,
    int32_t
);
extern int32_t virgl_renderer_context_create_fence(
    uint32_t,
    uint32_t,
    uint32_t,
    uint64_t
);
extern int32_t virgl_renderer_create_fence(int32_t, uint32_t);
extern int32_t virgl_renderer_get_poll_fd(void);
extern void virgl_renderer_poll(void);
extern void virgl_set_log_callback(
    DoryVirglRendererLogCallback,
    void *,
    DoryVirglRendererFreeDataCallback
);
#endif

typedef struct DoryVirglRendererFunctions {
    int32_t (*initialize)(void *, int32_t, DoryVirglRendererCallbacks *);
    void (*cleanup)(void *);
    void (*get_cap_set)(uint32_t, uint32_t *, uint32_t *);
    void (*fill_caps)(uint32_t, uint32_t, void *);
    int32_t (*context_create)(uint32_t, uint32_t, uint32_t, const char *);
    void (*context_destroy)(uint32_t);
    void (*context_attach_resource)(int32_t, int32_t);
    void (*context_detach_resource)(int32_t, int32_t);
    int32_t (*submit_cmd2)(void *, int32_t, int32_t, uint64_t *, uint32_t);
    int32_t (*blob_create)(const DoryVirglRendererBlobCreateArguments *);
    int32_t (*resource_create)(
        DoryVirglRendererResource3DCreateArguments *,
        struct iovec *,
        uint32_t
    );
    int32_t (*resource_attach_iov)(int32_t, struct iovec *, int32_t);
    void (*resource_detach_iov)(int32_t, struct iovec **, int32_t *);
    void (*resource_unref)(uint32_t);
    int32_t (*resource_get_map_info)(uint32_t, uint32_t *);
    int32_t (*resource_export_blob)(uint32_t, uint32_t *, int *);
    int32_t (*resource_get_info)(int32_t, DoryVirglRendererResourceInfo *);
    int32_t (*create_handle_for_scanout)(
        uint32_t,
        uint32_t,
        uint32_t,
        uint32_t,
        uint32_t,
        uint32_t,
        uint32_t,
        void **
    );
    void (*release_handle_for_scanout)(int32_t, void *);
    int32_t (*transfer_write_iov)(
        uint32_t,
        uint32_t,
        int32_t,
        uint32_t,
        uint32_t,
        DoryVirglRendererBox *,
        uint64_t,
        struct iovec *,
        uint32_t
    );
    int32_t (*transfer_read_iov)(
        uint32_t,
        uint32_t,
        uint32_t,
        uint32_t,
        uint32_t,
        DoryVirglRendererBox *,
        uint64_t,
        struct iovec *,
        int32_t
    );
    int32_t (*context_create_fence)(uint32_t, uint32_t, uint32_t, uint64_t);
    int32_t (*create_fence)(int32_t, uint32_t);
    int32_t (*get_poll_fd)(void);
    void (*poll)(void);
    void (*set_log_callback)(
        DoryVirglRendererLogCallback,
        void *,
        DoryVirglRendererFreeDataCallback
    );
} DoryVirglRendererFunctions;

typedef struct DoryVirglRendererFenceCompletion {
    uint32_t context_id;
    uint32_t ring_index;
    uint64_t fence_id;
    /* Nonzero only while a global fence is waiting for virglrenderer's 32-bit callback. */
    uint32_t renderer_fence_id;
    int read_descriptor;
    int write_descriptor;
    struct DoryVirglRendererFenceCompletion *next;
} DoryVirglRendererFenceCompletion;

struct DoryVirglRendererSession {
    DoryVirglRendererFunctions functions;
    DoryVirglRendererCallbacks callbacks;
    pthread_mutex_t fence_lock;
    DoryVirglRendererFenceCompletion *fence_head;
    DoryVirglRendererFenceCompletion *fence_tail;
    uint32_t next_global_renderer_fence_id;
    pthread_mutex_t submit_diagnostic_lock;
    uint32_t active_submit_context_id;
    DoryVirglRendererSubmitDiagnostic submit_diagnostic;
    bool fence_lock_initialized;
    bool submit_diagnostic_lock_initialized;
    bool submit_in_progress;
    bool log_callback_installed;
    bool renderer_initialized;
    bool owns_process_slot;
#if defined(DORY_VIRGL_RENDERER_DUAL_METAL)
    pthread_mutex_t angle_context_lock;
    bool angle_context_lock_initialized;
    EGLDisplay angle_display;
    EGLConfig angle_config;
    EGLContext angle_share_context;
#endif
};

enum { DORY_VIRGL_RENDERER_CONTEXT_COMMAND_COUNT = 64 };

/* Pinned `vrend_debug.c` command_names table. The callback stores only the matched ordinal. */
static const char *const dory_virgl_context_command_names[
    DORY_VIRGL_RENDERER_CONTEXT_COMMAND_COUNT
] = {
    "NOP",
    "CREATE_OBJECT",
    "BIND_OBJECT",
    "DESTROY_OBJECT",
    "SET_VIEWPORT_STATE",
    "SET_FRAMEBUFFER_STATE",
    "SET_VERTEX_BUFFERS",
    "CLEAR",
    "DRAW_VBO",
    "RESOURCE_INLINE_WRITE",
    "SET_SAMPLER_VIEWS",
    "SET_INDEX_BUFFER",
    "SET_CONSTANT_BUFFER",
    "SET_STENCIL_REF",
    "SET_BLEND_COLOR",
    "SET_SCISSOR_STATE",
    "BLIT",
    "RESOURCE_COPY_REGION",
    "BIND_SAMPLER_STATES",
    "BEGIN_QUERY",
    "END_QUERY",
    "GET_QUERY_RESULT",
    "SET_POLYGON_STIPPLE",
    "SET_CLIP_STATE",
    "SET_SAMPLE_MASK",
    "SET_STREAMOUT_TARGETS",
    "SET_RENDER_CONDITION",
    "SET_UNIFORM_BUFFER",
    "SET_SUB_CTX",
    "CREATE_SUB_CTX",
    "DESTROY_SUB_CTX",
    "BIND_SHADER",
    "SET_TESS_STATE",
    "SET_MIN_SAMPLES",
    "SET_SHADER_BUFFERS",
    "SET_SHADER_IMAGES",
    "MEMORY_BARRIER",
    "LAUNCH_GRID",
    "SET_FRAMEBUFFER_STATE_NO_ATTACH",
    "TEXTURE_BARRIER",
    "SET_ATOMIC_BUFFERS",
    "SET_DEBUG_FLAGS",
    "GET_QUERY_RESULT_QBO",
    "TRANSFER3D",
    "END_TRANSFERS",
    "COPY_TRANSFER3D",
    "SET_TWEAKS",
    "CLEAR_TEXTURE",
    "PIPE_RESOURCE_CREATE",
    "PIPE_RESOURCE_SET_TYPE",
    "GET_MEMORY_INFO",
    "SEND_STRING_MARKER",
    "LINK_SHADER",
    "CREATE_VIDEO_CODEC",
    "DESTROY_VIDEO_CODEC",
    "CREATE_VIDEO_BUFFER",
    "DESTROY_VIDEO_BUFFER",
    "BEGIN_FRAME",
    "DECODE_MACROBLOCK",
    "DECODE_BITSTREAM",
    "ENCODE_BITSTREAM",
    "END_FRAME",
    "CLEAR_SURFACE",
    "GET_PIPE_RESOURCE_LAYOUT",
};

static bool dory_parse_uint32(const char **cursor, uint32_t *value)
{
    const char *current = *cursor;
    if (*current < '0' || *current > '9')
        return false;
    uint64_t parsed = 0;
    do {
        parsed = parsed * 10U + (uint64_t)(*current - '0');
        if (parsed > UINT32_MAX)
            return false;
        current++;
    } while (*current >= '0' && *current <= '9');
    *cursor = current;
    *value = (uint32_t)parsed;
    return true;
}

static bool dory_parse_canonical_uint32(const char **cursor, uint32_t *value)
{
    const char *start = *cursor;
    if (!dory_parse_uint32(cursor, value))
        return false;
    return start[0] != '0' || *cursor == start + 1;
}

static bool dory_parse_int32(const char **cursor, int32_t *value)
{
    const char *current = *cursor;
    const bool negative = *current == '-';
    if (negative)
        current++;
    if (*current < '0' || *current > '9')
        return false;
    uint64_t parsed = 0;
    const uint64_t limit = negative ? (uint64_t)INT32_MAX + 1U : (uint64_t)INT32_MAX;
    do {
        parsed = parsed * 10U + (uint64_t)(*current - '0');
        if (parsed > limit)
            return false;
        current++;
    } while (*current >= '0' && *current <= '9');
    *cursor = current;
    *value = negative
        ? (parsed == (uint64_t)INT32_MAX + 1U ? INT32_MIN : -(int32_t)parsed)
        : (int32_t)parsed;
    return true;
}

static bool dory_parse_canonical_int32(const char **cursor, int32_t *value)
{
    const char *start = *cursor;
    if (!dory_parse_int32(cursor, value))
        return false;
    const char *digits = start[0] == '-' ? start + 1 : start;
    if (digits[0] == '0' && *cursor != digits + 1)
        return false;
    return start[0] != '-' || *value != 0;
}

static bool dory_match_context_command(
    const char *name,
    size_t length,
    uint32_t *command_id
)
{
    for (uint32_t index = 0;
         index < DORY_VIRGL_RENDERER_CONTEXT_COMMAND_COUNT;
         index++) {
        const char *candidate = dory_virgl_context_command_names[index];
        if (strlen(candidate) == length && memcmp(candidate, name, length) == 0) {
            *command_id = index;
            return true;
        }
    }
    return false;
}

int32_t DoryVirglRendererClassifySubmitDiagnosticMessage(
    const char *message,
    uint32_t expected_context_id,
    DoryVirglRendererSubmitDiagnostic *diagnostic
)
{
    if (message == NULL || expected_context_id == 0 || diagnostic == NULL)
        return -EINVAL;
    *diagnostic = (DoryVirglRendererSubmitDiagnostic){0};

    /* No general renderer log is accepted. Bound the read before matching the complete grammar. */
    const size_t message_length = strnlen(message, 161);
    if (message_length == 161)
        return 0;
    static const char prefix[] = "context ";
    static const char dispatch[] = " failed to dispatch ";
    const char *cursor = message;
    if (strncmp(cursor, prefix, sizeof(prefix) - 1U) != 0)
        return 0;
    cursor += sizeof(prefix) - 1U;

    uint32_t context_id = 0;
    if (!dory_parse_uint32(&cursor, &context_id) ||
        context_id != expected_context_id ||
        strncmp(cursor, dispatch, sizeof(dispatch) - 1U) != 0)
        return 0;
    cursor += sizeof(dispatch) - 1U;

    const char *command_start = cursor;
    while ((*cursor >= 'A' && *cursor <= 'Z') ||
           (*cursor >= '0' && *cursor <= '9') ||
           *cursor == '_')
        cursor++;
    const size_t command_length = (size_t)(cursor - command_start);
    if (command_length == 0 || cursor[0] != ':' || cursor[1] != ' ')
        return 0;
    cursor += 2;

    int32_t status = 0;
    if (!dory_parse_int32(&cursor, &status) || cursor[0] != '\n' || cursor[1] != '\0')
        return 0;
    uint32_t command_id = 0;
    if (!dory_match_context_command(command_start, command_length, &command_id))
        return 0;

    diagnostic->valid = 1;
    diagnostic->context_id = context_id;
    diagnostic->command_id = command_id;
    diagnostic->status = status;
    return 1;
}

int32_t DoryVirglRendererClassifyExactSubmitDiagnosticMessage(
    const char *message,
    uint32_t expected_context_id,
    DoryVirglRendererSubmitDiagnostic *diagnostic
)
{
    if (message == NULL || expected_context_id == 0 || diagnostic == NULL)
        return -EINVAL;
    *diagnostic = (DoryVirglRendererSubmitDiagnostic){0};

    static const char prefix[] = "vrend-dispatch-error context=";
    if (strncmp(message, prefix, sizeof(prefix) - 1U) != 0)
        return 0;
    diagnostic->failed_command_location_disposition =
        DORY_VIRGL_FAILED_COMMAND_LOCATION_AMBIGUOUS;

    /* The exact generated line is shorter than 161 bytes even at all integer extrema. */
    if (strnlen(message, 161) == 161)
        return -EINVAL;
    const char *cursor = message + sizeof(prefix) - 1U;
    static const char command_literal[] = " command=";
    static const char offset_literal[] = " dword-offset=";
    static const char ordinal_literal[] = " command-ordinal=";
    static const char status_literal[] = " status=";
    static const char surface_reason_literal[] = " surface-reason=";

    uint32_t context_id = 0;
    uint32_t command_id = 0;
    uint32_t dword_offset = 0;
    uint32_t command_ordinal = 0;
    uint32_t surface_failure_reason = 0;
    int32_t status = 0;
    if (!dory_parse_canonical_uint32(&cursor, &context_id) ||
        context_id != expected_context_id ||
        strncmp(cursor, command_literal, sizeof(command_literal) - 1U) != 0)
        return -EINVAL;
    cursor += sizeof(command_literal) - 1U;
    if (!dory_parse_canonical_uint32(&cursor, &command_id) ||
        command_id >= DORY_VIRGL_RENDERER_CONTEXT_COMMAND_COUNT ||
        strncmp(cursor, offset_literal, sizeof(offset_literal) - 1U) != 0)
        return -EINVAL;
    cursor += sizeof(offset_literal) - 1U;
    if (!dory_parse_canonical_uint32(&cursor, &dword_offset) ||
        strncmp(cursor, ordinal_literal, sizeof(ordinal_literal) - 1U) != 0)
        return -EINVAL;
    cursor += sizeof(ordinal_literal) - 1U;
    if (!dory_parse_canonical_uint32(&cursor, &command_ordinal) ||
        strncmp(cursor, status_literal, sizeof(status_literal) - 1U) != 0)
        return -EINVAL;
    cursor += sizeof(status_literal) - 1U;
    if (!dory_parse_canonical_int32(&cursor, &status) ||
        strncmp(
            cursor,
            surface_reason_literal,
            sizeof(surface_reason_literal) - 1U
        ) != 0)
        return -EINVAL;
    cursor += sizeof(surface_reason_literal) - 1U;
    if (!dory_parse_canonical_uint32(&cursor, &surface_failure_reason) ||
        surface_failure_reason > DORY_VIRGL_SURFACE_FAILURE_REASON_MAX ||
        cursor[0] != '\n' || cursor[1] != '\0')
        return -EINVAL;

    diagnostic->valid = 1;
    diagnostic->context_id = context_id;
    diagnostic->command_id = command_id;
    diagnostic->status = status;
    diagnostic->failed_command_location_disposition =
        DORY_VIRGL_FAILED_COMMAND_LOCATION_PRESENT;
    diagnostic->failed_command_dword_offset = dword_offset;
    diagnostic->failed_command_ordinal = command_ordinal;
    diagnostic->surface_failure_reason = surface_failure_reason;
    return 1;
}

int32_t DoryVirglRendererCorrelateCreateObjectSubtype(
    const void *command_bytes,
    uint32_t dword_count,
    DoryVirglRendererSubmitDiagnostic *diagnostic
)
{
    if (command_bytes == NULL || dword_count == 0 || diagnostic == NULL)
        return -EINVAL;
    diagnostic->create_object_subtype_disposition =
        DORY_VIRGL_CREATE_OBJECT_SUBTYPE_ABSENT;
    diagnostic->create_object_subtype = 0;
    diagnostic->create_object_candidate_count = 0;
    diagnostic->create_object_subtype_mask = 0;

    const uint32_t location_disposition =
        diagnostic->failed_command_location_disposition;
    const uint32_t expected_offset = diagnostic->failed_command_dword_offset;
    const uint32_t expected_ordinal = diagnostic->failed_command_ordinal;
    if (location_disposition == DORY_VIRGL_FAILED_COMMAND_LOCATION_ABSENT)
        diagnostic->surface_failure_reason = DORY_VIRGL_SURFACE_FAILURE_REASON_NONE;
    if (location_disposition != DORY_VIRGL_FAILED_COMMAND_LOCATION_ABSENT &&
        location_disposition != DORY_VIRGL_FAILED_COMMAND_LOCATION_PRESENT) {
        const uint32_t precursor = diagnostic->precursor_category;
        *diagnostic = (DoryVirglRendererSubmitDiagnostic){0};
        diagnostic->failed_command_location_disposition =
            DORY_VIRGL_FAILED_COMMAND_LOCATION_AMBIGUOUS;
        diagnostic->precursor_category = precursor;
        return 0;
    }

    uint64_t offset = 0;
    uint32_t header_ordinal = 0;
    uint32_t match_count = 0;
    uint32_t subtype_mask = 0;
    bool invalid_subtype = false;
    while (offset < dword_count) {
        uint32_t header = 0;
        memcpy(
            &header,
            (const uint8_t *)command_bytes + offset * sizeof(uint32_t),
            sizeof(header)
        );
        const uint32_t command_id = header & 0xffU;
        const uint32_t object_type = (header >> 8U) & 0xffU;
        const uint32_t payload_dwords = header >> 16U;
        const uint64_t next = offset + (uint64_t)payload_dwords + 1U;
        if (command_id >= DORY_VIRGL_RENDERER_CONTEXT_COMMAND_COUNT ||
            next > dword_count) {
            if (location_disposition == DORY_VIRGL_FAILED_COMMAND_LOCATION_PRESENT) {
                const uint32_t precursor = diagnostic->precursor_category;
                *diagnostic = (DoryVirglRendererSubmitDiagnostic){0};
                diagnostic->failed_command_location_disposition =
                    DORY_VIRGL_FAILED_COMMAND_LOCATION_AMBIGUOUS;
                diagnostic->precursor_category = precursor;
            }
            return 0;
        }

        if (location_disposition == DORY_VIRGL_FAILED_COMMAND_LOCATION_PRESENT) {
            if (offset == expected_offset || header_ordinal == expected_ordinal) {
                if (offset != expected_offset || header_ordinal != expected_ordinal ||
                    diagnostic->valid != 1 || command_id != diagnostic->command_id ||
                    (command_id == 1U &&
                     object_type > DORY_VIRGL_CREATE_OBJECT_SUBTYPE_MAX)) {
                    const uint32_t precursor = diagnostic->precursor_category;
                    *diagnostic = (DoryVirglRendererSubmitDiagnostic){0};
                    diagnostic->failed_command_location_disposition =
                        DORY_VIRGL_FAILED_COMMAND_LOCATION_AMBIGUOUS;
                    diagnostic->precursor_category = precursor;
                    return 0;
                }
                if (command_id == 1U) {
                    diagnostic->create_object_subtype_disposition =
                        DORY_VIRGL_CREATE_OBJECT_SUBTYPE_PRESENT;
                    diagnostic->create_object_subtype = object_type;
                    diagnostic->create_object_candidate_count = 1;
                    diagnostic->create_object_subtype_mask = 1U << object_type;
                }
                if (command_id != 1U ||
                    object_type != DORY_VIRGL_OBJECT_SURFACE ||
                    diagnostic->status != EINVAL ||
                    diagnostic->surface_failure_reason >
                        DORY_VIRGL_SURFACE_FAILURE_REASON_MAX)
                    diagnostic->surface_failure_reason =
                        DORY_VIRGL_SURFACE_FAILURE_REASON_NONE;
                return 0;
            }
            if (offset > expected_offset || header_ordinal > expected_ordinal) {
                const uint32_t precursor = diagnostic->precursor_category;
                *diagnostic = (DoryVirglRendererSubmitDiagnostic){0};
                diagnostic->failed_command_location_disposition =
                    DORY_VIRGL_FAILED_COMMAND_LOCATION_AMBIGUOUS;
                diagnostic->precursor_category = precursor;
                return 0;
            }
        }

        if (command_id == 1U) {
            if (match_count < DORY_VIRGL_CREATE_OBJECT_CANDIDATE_COUNT_MAX)
                match_count++;
            if (object_type <= DORY_VIRGL_CREATE_OBJECT_SUBTYPE_MAX) {
                subtype_mask |= 1U << object_type;
            } else {
                invalid_subtype = true;
            }
        }
        offset = next;
        header_ordinal++;
    }

    if (location_disposition == DORY_VIRGL_FAILED_COMMAND_LOCATION_PRESENT) {
        const uint32_t precursor = diagnostic->precursor_category;
        *diagnostic = (DoryVirglRendererSubmitDiagnostic){0};
        diagnostic->failed_command_location_disposition =
            DORY_VIRGL_FAILED_COMMAND_LOCATION_AMBIGUOUS;
        diagnostic->precursor_category = precursor;
        return 0;
    }

    diagnostic->failed_command_dword_offset = 0;
    diagnostic->failed_command_ordinal = 0;
    diagnostic->surface_failure_reason = DORY_VIRGL_SURFACE_FAILURE_REASON_NONE;
    diagnostic->create_object_candidate_count = match_count;
    diagnostic->create_object_subtype_mask = invalid_subtype ? 0 : subtype_mask;
    return 0;
}

int32_t DoryVirglRendererClassifyCreateObjectSubtype(
    const void *command_bytes,
    uint32_t dword_count,
    DoryVirglRendererSubmitDiagnostic *diagnostic
)
{
    if (diagnostic == NULL)
        return -EINVAL;
    diagnostic->failed_command_location_disposition =
        DORY_VIRGL_FAILED_COMMAND_LOCATION_ABSENT;
    diagnostic->failed_command_dword_offset = 0;
    diagnostic->failed_command_ordinal = 0;
    return DoryVirglRendererCorrelateCreateObjectSubtype(
        command_bytes,
        dword_count,
        diagnostic
    );
}

uint32_t DoryVirglRendererClassifySubmitPrecursorMessage(const char *message)
{
    if (message == NULL)
        return DORY_VIRGL_PRECURSOR_NONE;
#define DORY_PREFIX_CATEGORY(prefix, category) \
    if (strncmp(message, prefix, sizeof(prefix) - 1U) == 0) \
        return category
    DORY_PREFIX_CATEGORY(
        "Shader failed to compile\n",
        DORY_VIRGL_PRECURSOR_SHADER_COMPILE_FAILED
    );
    DORY_PREFIX_CATEGORY(
        "Error assigning TGSI\n",
        DORY_VIRGL_PRECURSOR_TGSI_ASSIGNMENT_FAILED
    );
    DORY_PREFIX_CATEGORY(
        "Geometry shader not supported\n",
        DORY_VIRGL_PRECURSOR_GEOMETRY_SHADER_UNSUPPORTED
    );
    DORY_PREFIX_CATEGORY(
        "Tesselation shaders not supported\n",
        DORY_VIRGL_PRECURSOR_TESSELLATION_SHADER_UNSUPPORTED
    );
    DORY_PREFIX_CATEGORY(
        "Compute shaders not supported\n",
        DORY_VIRGL_PRECURSOR_COMPUTE_SHADER_UNSUPPORTED
    );
    DORY_PREFIX_CATEGORY(
        "Invalid expected token count\n",
        DORY_VIRGL_PRECURSOR_INVALID_EXPECTED_TOKEN_COUNT
    );
    DORY_PREFIX_CATEGORY(
        "Expected long shader continuation, got new shader\n",
        DORY_VIRGL_PRECURSOR_EXPECTED_LONG_CONTINUATION
    );
    DORY_PREFIX_CATEGORY(
        "Long shader continuation handle invalid\n",
        DORY_VIRGL_PRECURSOR_INVALID_CONTINUATION_HANDLE
    );
    DORY_PREFIX_CATEGORY(
        "Got continuation without original long shader ",
        DORY_VIRGL_PRECURSOR_CONTINUATION_WITHOUT_ORIGINAL
    );
    DORY_PREFIX_CATEGORY(
        "Got mismatched shader continuation ",
        DORY_VIRGL_PRECURSOR_MISMATCHED_CONTINUATION
    );
    DORY_PREFIX_CATEGORY(
        "Got too large shader continuation ",
        DORY_VIRGL_PRECURSOR_OVERSIZED_CONTINUATION
    );
#undef DORY_PREFIX_CATEGORY
    return DORY_VIRGL_PRECURSOR_NONE;
}

static void dory_renderer_log_callback(
    int32_t log_level,
    const char *message,
    void *user_data
)
{
    DoryVirglRendererSession *session = user_data;
    if (log_level != DORY_VIRGL_RENDERER_LOG_LEVEL_ERROR ||
        session == NULL || !session->submit_diagnostic_lock_initialized)
        return;

    pthread_mutex_lock(&session->submit_diagnostic_lock);
    const bool active = session->submit_in_progress;
    const uint32_t expected_context_id = session->active_submit_context_id;
    pthread_mutex_unlock(&session->submit_diagnostic_lock);
    if (!active)
        return;

    const uint32_t precursor =
        DoryVirglRendererClassifySubmitPrecursorMessage(message);
    DoryVirglRendererSubmitDiagnostic classified = {0};
    const int32_t exact_classification =
        DoryVirglRendererClassifyExactSubmitDiagnosticMessage(
            message,
            expected_context_id,
            &classified
        );
    const int32_t legacy_classification = exact_classification == 0
        ? DoryVirglRendererClassifySubmitDiagnosticMessage(
            message,
            expected_context_id,
            &classified
        )
        : 0;
    if (precursor == DORY_VIRGL_PRECURSOR_NONE &&
        exact_classification == 0 && legacy_classification != 1)
        return;

    pthread_mutex_lock(&session->submit_diagnostic_lock);
    if (session->submit_in_progress &&
        session->active_submit_context_id == expected_context_id &&
        precursor != DORY_VIRGL_PRECURSOR_NONE &&
        session->submit_diagnostic.precursor_category == DORY_VIRGL_PRECURSOR_NONE)
        session->submit_diagnostic.precursor_category = precursor;
    if (session->submit_in_progress &&
        session->active_submit_context_id == expected_context_id &&
        exact_classification != 0 &&
        session->submit_diagnostic.failed_command_location_disposition ==
            DORY_VIRGL_FAILED_COMMAND_LOCATION_ABSENT) {
        classified.precursor_category = session->submit_diagnostic.precursor_category;
        session->submit_diagnostic = classified;
    } else if (session->submit_in_progress &&
        session->active_submit_context_id == expected_context_id &&
        legacy_classification == 1 &&
        session->submit_diagnostic.valid == 0 &&
        session->submit_diagnostic.failed_command_location_disposition ==
            DORY_VIRGL_FAILED_COMMAND_LOCATION_ABSENT) {
        classified.precursor_category = session->submit_diagnostic.precursor_category;
        session->submit_diagnostic = classified;
    }
    pthread_mutex_unlock(&session->submit_diagnostic_lock);
}

#if defined(DORY_VIRGL_RENDERER_DUAL_METAL)
typedef struct DoryVirglRendererANGLEContext {
    EGLDisplay display;
    EGLContext context;
    EGLSurface surface;
} DoryVirglRendererANGLEContext;

static int32_t dory_initialize_angle(DoryVirglRendererSession *session)
{
    const PFNEGLGETPLATFORMDISPLAYEXTPROC get_platform_display =
        (PFNEGLGETPLATFORMDISPLAYEXTPROC)eglGetProcAddress("eglGetPlatformDisplayEXT");
    if (get_platform_display == NULL)
        return -ENOTSUP;

    const EGLint display_attributes[] = {
        EGL_PLATFORM_ANGLE_TYPE_ANGLE,
        EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE,
        EGL_PLATFORM_ANGLE_DEVICE_TYPE_ANGLE,
        EGL_PLATFORM_ANGLE_DEVICE_TYPE_HARDWARE_ANGLE,
        EGL_NONE,
    };
    session->angle_display = get_platform_display(
        EGL_PLATFORM_ANGLE_ANGLE,
        (void *)(uintptr_t)EGL_DEFAULT_DISPLAY,
        display_attributes
    );
    if (session->angle_display == EGL_NO_DISPLAY)
        return -ENODEV;

    EGLint major = 0;
    EGLint minor = 0;
    if (eglInitialize(session->angle_display, &major, &minor) != EGL_TRUE)
        return -EIO;
    if (eglBindAPI(EGL_OPENGL_ES_API) != EGL_TRUE)
        return -EIO;

    const EGLint config_attributes[] = {
        EGL_SURFACE_TYPE, EGL_PBUFFER_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT_KHR,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 8,
        EGL_NONE,
    };
    EGLint config_count = 0;
    if (eglChooseConfig(
            session->angle_display,
            config_attributes,
            &session->angle_config,
            1,
            &config_count
        ) != EGL_TRUE || config_count != 1)
        return -ENOTSUP;
    const EGLint context_attributes[] = {
        EGL_CONTEXT_CLIENT_VERSION, 3,
        EGL_NONE,
    };
    session->angle_share_context = eglCreateContext(
        session->angle_display,
        session->angle_config,
        EGL_NO_CONTEXT,
        context_attributes
    );
    if (session->angle_share_context == EGL_NO_CONTEXT)
        return -EIO;
    return 0;
}

static void dory_terminate_angle(DoryVirglRendererSession *session)
{
    if (session->angle_display != EGL_NO_DISPLAY) {
        (void)eglMakeCurrent(
            session->angle_display,
            EGL_NO_SURFACE,
            EGL_NO_SURFACE,
            EGL_NO_CONTEXT
        );
        if (session->angle_share_context != EGL_NO_CONTEXT) {
            (void)eglDestroyContext(
                session->angle_display,
                session->angle_share_context
            );
            session->angle_share_context = EGL_NO_CONTEXT;
        }
        (void)eglTerminate(session->angle_display);
        session->angle_display = EGL_NO_DISPLAY;
        session->angle_config = NULL;
    }
    if (session->angle_context_lock_initialized) {
        pthread_mutex_destroy(&session->angle_context_lock);
        session->angle_context_lock_initialized = false;
    }
}

static DoryVirglRendererGLContext dory_create_gl_context(
    void *cookie,
    int32_t scanout_index,
    DoryVirglRendererGLContextParameters *parameters
)
{
    (void)scanout_index;
    DoryVirglRendererSession *session = cookie;
    if (session == NULL || parameters == NULL ||
        session->angle_display == EGL_NO_DISPLAY)
        return NULL;

    DoryVirglRendererANGLEContext *owned = calloc(1, sizeof(*owned));
    if (owned == NULL)
        return NULL;

    pthread_mutex_lock(&session->angle_context_lock);
    /*
     * Keep one process-lifetime root instead of making the first vrend context the share-group
     * owner. Virgl may destroy and recreate its primary context while sync/blit contexts remain;
     * every callback context therefore shares with this root regardless of creation order.
     */
    const EGLContext share = session->angle_share_context;
    const EGLint context_attributes[] = {
        EGL_CONTEXT_CLIENT_VERSION, 3,
        EGL_NONE,
    };
    owned->context = eglCreateContext(
        session->angle_display,
        session->angle_config,
        share,
        context_attributes
    );
    const EGLint surface_attributes[] = {
        EGL_WIDTH, 1,
        EGL_HEIGHT, 1,
        EGL_NONE,
    };
    owned->surface = owned->context == EGL_NO_CONTEXT
        ? EGL_NO_SURFACE
        : eglCreatePbufferSurface(
            session->angle_display,
            session->angle_config,
            surface_attributes
        );
    pthread_mutex_unlock(&session->angle_context_lock);

    if (owned->context == EGL_NO_CONTEXT || owned->surface == EGL_NO_SURFACE) {
        if (owned->surface != EGL_NO_SURFACE)
            (void)eglDestroySurface(session->angle_display, owned->surface);
        if (owned->context != EGL_NO_CONTEXT)
            (void)eglDestroyContext(session->angle_display, owned->context);
        free(owned);
        return NULL;
    }
    owned->display = session->angle_display;
    return owned;
}

static void dory_destroy_gl_context(void *cookie, DoryVirglRendererGLContext context)
{
    DoryVirglRendererSession *session = cookie;
    DoryVirglRendererANGLEContext *owned = context;
    if (session == NULL || owned == NULL)
        return;
    pthread_mutex_lock(&session->angle_context_lock);
    (void)eglDestroySurface(owned->display, owned->surface);
    (void)eglDestroyContext(owned->display, owned->context);
    pthread_mutex_unlock(&session->angle_context_lock);
    free(owned);
}

static int32_t dory_make_current(
    void *cookie,
    int32_t scanout_index,
    DoryVirglRendererGLContext context
)
{
    (void)scanout_index;
    DoryVirglRendererSession *session = cookie;
    if (session == NULL || session->angle_display == EGL_NO_DISPLAY)
        return -EINVAL;
    if (context == NULL) {
        return eglMakeCurrent(
            session->angle_display,
            EGL_NO_SURFACE,
            EGL_NO_SURFACE,
            EGL_NO_CONTEXT
        ) == EGL_TRUE ? 0 : -EIO;
    }
    DoryVirglRendererANGLEContext *owned = context;
    return eglMakeCurrent(
        owned->display,
        owned->surface,
        owned->surface,
        owned->context
    ) == EGL_TRUE ? 0 : -EIO;
}

static void *dory_get_egl_display(void *cookie)
{
    DoryVirglRendererSession *session = cookie;
    if (session == NULL || session->angle_display == EGL_NO_DISPLAY)
        return NULL;
    return session->angle_display;
}

static GLuint dory_compile_self_test_shader(GLenum type, const char *source)
{
    GLuint shader = glCreateShader(type);
    if (shader == 0)
        return 0;
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    GLint compiled = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (compiled != GL_TRUE) {
        glDeleteShader(shader);
        return 0;
    }
    return shader;
}

/*
 * This is deliberately an execution test, not a string-only ANGLE probe.  The historical Dory
 * failure initialized an OpenGL context successfully but then rejected GNOME's first uniform-block
 * shader.  A production worker therefore proves the exact path GNOME needs before it may return a
 * VirGL2 capset: Metal ANGLE, GLES 3, UBO-backed shader compilation/link, instanced drawing, FBO
 * rendering, GPU completion, and deterministic readback.
 */
static int32_t dory_run_angle_execution_self_test(DoryVirglRendererSession *session)
{
    const EGLint surface_attributes[] = {
        EGL_WIDTH, 4,
        EGL_HEIGHT, 4,
        EGL_NONE,
    };
    EGLSurface surface = eglCreatePbufferSurface(
        session->angle_display,
        session->angle_config,
        surface_attributes
    );
    if (surface == EGL_NO_SURFACE)
        return -EIO;

    const EGLint context_attributes[] = {
        EGL_CONTEXT_CLIENT_VERSION, 3,
        EGL_NONE,
    };
    EGLContext context = eglCreateContext(
        session->angle_display,
        session->angle_config,
        session->angle_share_context,
        context_attributes
    );
    if (context == EGL_NO_CONTEXT) {
        (void)eglDestroySurface(session->angle_display, surface);
        return -EIO;
    }

    int32_t result = -EIO;
    GLuint vertex_shader = 0;
    GLuint fragment_shader = 0;
    GLuint program = 0;
    GLuint uniform_buffer = 0;
    GLuint texture = 0;
    GLuint framebuffer = 0;
    GLuint vertex_array = 0;
    GLsync execution_fence = NULL;
    if (eglMakeCurrent(
            session->angle_display,
            surface,
            surface,
            context
        ) != EGL_TRUE)
        goto cleanup;

    GLint major = 0;
    GLint minor = 0;
    GLint uniform_bindings = 0;
    GLint vertex_attributes = 0;
    GLint draw_buffers = 0;
    glGetIntegerv(GL_MAJOR_VERSION, &major);
    glGetIntegerv(GL_MINOR_VERSION, &minor);
    glGetIntegerv(GL_MAX_UNIFORM_BUFFER_BINDINGS, &uniform_bindings);
    glGetIntegerv(GL_MAX_VERTEX_ATTRIBS, &vertex_attributes);
    glGetIntegerv(GL_MAX_DRAW_BUFFERS, &draw_buffers);
    const char *renderer = (const char *)glGetString(GL_RENDERER);
    if (major < 3 || uniform_bindings < 1 || vertex_attributes < 8 || draw_buffers < 1 ||
        renderer == NULL || strstr(renderer, "ANGLE") == NULL ||
        strstr(renderer, "Metal") == NULL ||
        glGetError() != GL_NO_ERROR) {
        result = -ENOTSUP;
        goto cleanup;
    }
    (void)minor;

    static const char vertex_source[] =
        "#version 300 es\n"
        "const vec2 p[3] = vec2[3](vec2(-1.0,-1.0), vec2(3.0,-1.0), "
        "vec2(-1.0,3.0));\n"
        "void main() { gl_Position = vec4(p[gl_VertexID], 0.0, 1.0); }\n";
    static const char fragment_source[] =
        "#version 300 es\n"
        "precision highp float;\n"
        "layout(std140) uniform DoryColorBlock { vec4 color; };\n"
        "out vec4 doryColor;\n"
        "void main() { doryColor = color; }\n";
    vertex_shader = dory_compile_self_test_shader(GL_VERTEX_SHADER, vertex_source);
    fragment_shader = dory_compile_self_test_shader(GL_FRAGMENT_SHADER, fragment_source);
    if (vertex_shader == 0 || fragment_shader == 0)
        goto cleanup;

    program = glCreateProgram();
    if (program == 0)
        goto cleanup;
    glAttachShader(program, vertex_shader);
    glAttachShader(program, fragment_shader);
    glLinkProgram(program);
    GLint linked = GL_FALSE;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (linked != GL_TRUE)
        goto cleanup;

    const GLuint block_index = glGetUniformBlockIndex(program, "DoryColorBlock");
    if (block_index == GL_INVALID_INDEX)
        goto cleanup;
    glUniformBlockBinding(program, block_index, 0);
    static const GLfloat expected_color[4] = {0.25f, 0.5f, 0.75f, 1.0f};
    glGenBuffers(1, &uniform_buffer);
    glBindBuffer(GL_UNIFORM_BUFFER, uniform_buffer);
    glBufferData(GL_UNIFORM_BUFFER, sizeof(expected_color), expected_color, GL_STATIC_DRAW);
    glBindBufferBase(GL_UNIFORM_BUFFER, 0, uniform_buffer);

    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexStorage2D(GL_TEXTURE_2D, 1, GL_RGBA8, 4, 4);
    glGenFramebuffers(1, &framebuffer);
    glBindFramebuffer(GL_FRAMEBUFFER, framebuffer);
    glFramebufferTexture2D(
        GL_FRAMEBUFFER,
        GL_COLOR_ATTACHMENT0,
        GL_TEXTURE_2D,
        texture,
        0
    );
    if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE)
        goto cleanup;

    glViewport(0, 0, 4, 4);
    glGenVertexArrays(1, &vertex_array);
    glBindVertexArray(vertex_array);
    glUseProgram(program);
    glDrawArraysInstanced(GL_TRIANGLES, 0, 3, 1);
    execution_fence = glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0);
    if (execution_fence == NULL)
        goto cleanup;
    glFlush();
    const GLenum wait_result = glClientWaitSync(
        execution_fence,
        GL_SYNC_FLUSH_COMMANDS_BIT,
        1000000000ULL
    );
    if (wait_result != GL_ALREADY_SIGNALED && wait_result != GL_CONDITION_SATISFIED)
        goto cleanup;
    glFinish();
    GLubyte pixel[4] = {0, 0, 0, 0};
    glReadPixels(2, 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, pixel);
    if (glGetError() != GL_NO_ERROR)
        goto cleanup;
    const int expected[4] = {64, 128, 191, 255};
    for (size_t component = 0; component < 4; component++) {
        const int difference = (int)pixel[component] - expected[component];
        if (difference < -2 || difference > 2)
            goto cleanup;
    }
    result = 0;

cleanup:
    if (execution_fence != NULL)
        glDeleteSync(execution_fence);
    if (vertex_array != 0)
        glDeleteVertexArrays(1, &vertex_array);
    if (framebuffer != 0)
        glDeleteFramebuffers(1, &framebuffer);
    if (texture != 0)
        glDeleteTextures(1, &texture);
    if (uniform_buffer != 0)
        glDeleteBuffers(1, &uniform_buffer);
    if (program != 0)
        glDeleteProgram(program);
    if (fragment_shader != 0)
        glDeleteShader(fragment_shader);
    if (vertex_shader != 0)
        glDeleteShader(vertex_shader);
    (void)eglMakeCurrent(
        session->angle_display,
        EGL_NO_SURFACE,
        EGL_NO_SURFACE,
        EGL_NO_CONTEXT
    );
    (void)eglDestroyContext(session->angle_display, context);
    (void)eglDestroySurface(session->angle_display, surface);
    return result;
}
#endif

static pthread_mutex_t dory_session_lock = PTHREAD_MUTEX_INITIALIZER;
static bool dory_session_active;

static void dory_write_fence(void *cookie, uint32_t fence);

static int32_t dory_make_completion_pipe(int descriptors[2])
{
    descriptors[0] = -1;
    descriptors[1] = -1;
    if (pipe(descriptors) != 0)
        return errno ? -errno : -EMFILE;

    for (size_t index = 0; index < 2; index++) {
        const int flags = fcntl(descriptors[index], F_GETFD);
        if (flags < 0 || fcntl(descriptors[index], F_SETFD, flags | FD_CLOEXEC) != 0) {
            const int saved_errno = errno;
            close(descriptors[0]);
            close(descriptors[1]);
            descriptors[0] = -1;
            descriptors[1] = -1;
            return saved_errno ? -saved_errno : -EMFILE;
        }
    }
    return 0;
}

static void dory_remove_fence_completion_locked(
    DoryVirglRendererSession *session,
    DoryVirglRendererFenceCompletion *target
)
{
    DoryVirglRendererFenceCompletion *previous = NULL;
    DoryVirglRendererFenceCompletion *completion = session->fence_head;
    while (completion != NULL && completion != target) {
        previous = completion;
        completion = completion->next;
    }
    if (completion == NULL)
        return;
    if (previous == NULL)
        session->fence_head = completion->next;
    else
        previous->next = completion->next;
    if (session->fence_tail == completion)
        session->fence_tail = previous;
    if (completion->read_descriptor >= 0)
        close(completion->read_descriptor);
    if (completion->write_descriptor >= 0)
        close(completion->write_descriptor);
    free(completion);
}

static int32_t dory_allocate_global_renderer_fence_id_locked(
    DoryVirglRendererSession *session,
    uint32_t *out_renderer_fence_id
)
{
    if (out_renderer_fence_id == NULL)
        return -EINVAL;

    size_t live_global_fences = 0;
    for (DoryVirglRendererFenceCompletion *completion = session->fence_head;
         completion != NULL;
         completion = completion->next) {
        if (completion->context_id == 0 && completion->renderer_fence_id != 0)
            live_global_fences++;
    }
    if (live_global_fences >= UINT32_MAX - 1U)
        return -ENOSPC;

    uint32_t candidate = session->next_global_renderer_fence_id;
    if (candidate == 0)
        candidate = 1;

    /* Among N live ids, at least one of the next N+1 nonzero candidates is free. This keeps the
     * allocator bounded even after wrap and never aliases an outstanding renderer callback. */
    for (size_t attempt = 0; attempt <= live_global_fences; attempt++) {
        bool collision = false;
        for (DoryVirglRendererFenceCompletion *completion = session->fence_head;
             completion != NULL;
             completion = completion->next) {
            if (completion->context_id == 0 &&
                completion->renderer_fence_id == candidate) {
                collision = true;
                break;
            }
        }
        if (!collision) {
            *out_renderer_fence_id = candidate;
            session->next_global_renderer_fence_id = candidate + 1U;
            if (session->next_global_renderer_fence_id == 0)
                session->next_global_renderer_fence_id = 1;
            return 0;
        }
        candidate++;
        if (candidate == 0)
            candidate = 1;
    }
    return -ENOSPC;
}

static void dory_write_fence(void *cookie, uint32_t renderer_fence_id)
{
    DoryVirglRendererSession *session = cookie;
    if (session == NULL || !session->fence_lock_initialized || renderer_fence_id == 0)
        return;

    pthread_mutex_lock(&session->fence_lock);
    DoryVirglRendererFenceCompletion *target = session->fence_head;
    while (target != NULL &&
           (target->context_id != 0 ||
            target->renderer_fence_id != renderer_fence_id)) {
        target = target->next;
    }
    if (target == NULL) {
        pthread_mutex_unlock(&session->fence_lock);
        return;
    }

    /* VirGL's ctx0 timeline may coalesce retirement. Signal every earlier admitted global fence
     * through the callback target by registration order; guest ids are deliberately not compared
     * numerically because they are independent 64-bit protocol identities and may wrap. */
    DoryVirglRendererFenceCompletion *previous = NULL;
    DoryVirglRendererFenceCompletion *completion = session->fence_head;
    while (completion != NULL) {
        DoryVirglRendererFenceCompletion *next = completion->next;
        if (completion->context_id == 0 && completion->renderer_fence_id != 0) {
            if (completion->write_descriptor >= 0) {
                close(completion->write_descriptor);
                completion->write_descriptor = -1;
            }
            /* The callback mapping is no longer outstanding, even if export races behind it. */
            completion->renderer_fence_id = 0;
        }

        const bool reached_target = completion == target;
        if (completion->read_descriptor < 0 && completion->write_descriptor < 0) {
            if (previous == NULL)
                session->fence_head = next;
            else
                previous->next = next;
            if (session->fence_tail == completion)
                session->fence_tail = previous;
            free(completion);
        } else {
            previous = completion;
        }
        if (reached_target)
            break;
        completion = next;
    }
    pthread_mutex_unlock(&session->fence_lock);
}

static void dory_write_context_fence(
    void *cookie,
    uint32_t context_id,
    uint32_t ring_index,
    uint64_t fence_id
)
{
    DoryVirglRendererSession *session = cookie;
    if (session == NULL || !session->fence_lock_initialized)
        return;

    pthread_mutex_lock(&session->fence_lock);

    /*
     * An inner render-server fence may coalesce timeline notifications. Confirm this callback is
     * one we admitted, then signal every completion registered before it on the same context/ring.
     * Registration order, rather than numeric fence ordering, remains correct across id wraparound.
     */
    DoryVirglRendererFenceCompletion *target = session->fence_head;
    while (target != NULL &&
           (target->context_id != context_id ||
            target->ring_index != ring_index ||
            target->fence_id != fence_id)) {
        target = target->next;
    }
    if (target == NULL) {
        pthread_mutex_unlock(&session->fence_lock);
        return;
    }

    DoryVirglRendererFenceCompletion *previous = NULL;
    DoryVirglRendererFenceCompletion *completion = session->fence_head;
    while (completion != NULL) {
        DoryVirglRendererFenceCompletion *next = completion->next;
        if (completion->context_id == context_id &&
            completion->ring_index == ring_index &&
            completion->write_descriptor >= 0) {
            /* EOF is a one-shot pollable completion edge and cannot block the renderer callback. */
            close(completion->write_descriptor);
            completion->write_descriptor = -1;
        }

        const bool reached_target = completion == target;
        if (completion->read_descriptor < 0 && completion->write_descriptor < 0) {
            if (previous == NULL)
                session->fence_head = next;
            else
                previous->next = next;
            if (session->fence_tail == completion)
                session->fence_tail = previous;
            free(completion);
        } else {
            previous = completion;
        }
        if (reached_target)
            break;
        completion = next;
    }

    pthread_mutex_unlock(&session->fence_lock);
}

static int32_t dory_register_fence_completion(
    DoryVirglRendererSession *session,
    uint32_t context_id,
    uint32_t ring_index,
    uint64_t fence_id,
    bool allocate_global_renderer_id,
    uint32_t *out_renderer_fence_id
)
{
    DoryVirglRendererFenceCompletion *completion = calloc(1, sizeof(*completion));
    if (completion == NULL)
        return -ENOMEM;

    int descriptors[2];
    int32_t result = dory_make_completion_pipe(descriptors);
    if (result != 0) {
        free(completion);
        return result;
    }
    completion->context_id = context_id;
    completion->ring_index = ring_index;
    completion->fence_id = fence_id;
    completion->read_descriptor = descriptors[0];
    completion->write_descriptor = descriptors[1];

    pthread_mutex_lock(&session->fence_lock);
    for (DoryVirglRendererFenceCompletion *existing = session->fence_head;
         existing != NULL;
         existing = existing->next) {
        /* The public one-shot handoff consumes by fence_id, so live ids are process-unique. */
        if (existing->fence_id == fence_id) {
            pthread_mutex_unlock(&session->fence_lock);
            close(completion->read_descriptor);
            close(completion->write_descriptor);
            free(completion);
            return -EEXIST;
        }
    }
    if (allocate_global_renderer_id) {
        result = dory_allocate_global_renderer_fence_id_locked(
            session,
            &completion->renderer_fence_id
        );
        if (result != 0) {
            pthread_mutex_unlock(&session->fence_lock);
            close(completion->read_descriptor);
            close(completion->write_descriptor);
            free(completion);
            return result;
        }
        *out_renderer_fence_id = completion->renderer_fence_id;
    }
    if (session->fence_tail == NULL)
        session->fence_head = completion;
    else
        session->fence_tail->next = completion;
    session->fence_tail = completion;
    pthread_mutex_unlock(&session->fence_lock);
    return 0;
}

static void dory_cancel_fence_completion(
    DoryVirglRendererSession *session,
    uint32_t context_id,
    uint32_t ring_index,
    uint64_t fence_id
)
{
    pthread_mutex_lock(&session->fence_lock);
    DoryVirglRendererFenceCompletion *completion = session->fence_head;
    while (completion != NULL) {
        if (completion->context_id == context_id &&
            completion->ring_index == ring_index &&
            completion->fence_id == fence_id) {
            dory_remove_fence_completion_locked(session, completion);
            break;
        }
        completion = completion->next;
    }
    pthread_mutex_unlock(&session->fence_lock);
}

static void dory_remove_context_fence_completions(
    DoryVirglRendererSession *session,
    uint32_t context_id
)
{
    if (!session->fence_lock_initialized)
        return;
    pthread_mutex_lock(&session->fence_lock);
    DoryVirglRendererFenceCompletion *completion = session->fence_head;
    while (completion != NULL) {
        DoryVirglRendererFenceCompletion *next = completion->next;
        if (completion->context_id == context_id)
            dory_remove_fence_completion_locked(session, completion);
        completion = next;
    }
    pthread_mutex_unlock(&session->fence_lock);
}

static void dory_destroy_fence_registry(DoryVirglRendererSession *session)
{
    if (!session->fence_lock_initialized)
        return;
    pthread_mutex_lock(&session->fence_lock);
    while (session->fence_head != NULL)
        dory_remove_fence_completion_locked(session, session->fence_head);
    pthread_mutex_unlock(&session->fence_lock);
    pthread_mutex_destroy(&session->fence_lock);
    session->fence_lock_initialized = false;
}

static int32_t dory_claim_process_slot(DoryVirglRendererSession *session)
{
    int32_t result = 0;
    pthread_mutex_lock(&dory_session_lock);
    if (dory_session_active) {
        result = -EBUSY;
    } else {
        dory_session_active = true;
        session->owns_process_slot = true;
    }
    pthread_mutex_unlock(&dory_session_lock);
    return result;
}

static void dory_release_process_slot(DoryVirglRendererSession *session)
{
    if (!session->owns_process_slot)
        return;
    pthread_mutex_lock(&dory_session_lock);
    dory_session_active = false;
    session->owns_process_slot = false;
    pthread_mutex_unlock(&dory_session_lock);
}

static int32_t dory_bind_static_functions(DoryVirglRendererSession *session)
{
#if defined(DORY_VIRGL_RENDERER_STATIC_LINKED)
    session->functions = (DoryVirglRendererFunctions){
        .initialize = virgl_renderer_init,
        .cleanup = virgl_renderer_cleanup,
        .get_cap_set = virgl_renderer_get_cap_set,
        .fill_caps = virgl_renderer_fill_caps,
        .context_create = virgl_renderer_context_create_with_flags,
        .context_destroy = virgl_renderer_context_destroy,
        .context_attach_resource = virgl_renderer_ctx_attach_resource,
        .context_detach_resource = virgl_renderer_ctx_detach_resource,
        .submit_cmd2 = virgl_renderer_submit_cmd2,
        .blob_create = virgl_renderer_resource_create_blob,
        .resource_create = virgl_renderer_resource_create,
        .resource_attach_iov = virgl_renderer_resource_attach_iov,
        .resource_detach_iov = virgl_renderer_resource_detach_iov,
        .resource_unref = virgl_renderer_resource_unref,
        .resource_get_map_info = virgl_renderer_resource_get_map_info,
        .resource_export_blob = virgl_renderer_resource_export_blob,
        .resource_get_info = virgl_renderer_resource_get_info,
        .create_handle_for_scanout = virgl_renderer_create_handle_for_scanout,
        .release_handle_for_scanout = virgl_renderer_release_handle_for_scanout,
        .transfer_write_iov = virgl_renderer_transfer_write_iov,
        .transfer_read_iov = virgl_renderer_transfer_read_iov,
        .context_create_fence = virgl_renderer_context_create_fence,
        .create_fence = virgl_renderer_create_fence,
        .get_poll_fd = virgl_renderer_get_poll_fd,
        .poll = virgl_renderer_poll,
        .set_log_callback = virgl_set_log_callback,
    };
    return 0;
#else
    (void)session;
    return -ENOSYS;
#endif
}

static void dory_destroy_partial_session(DoryVirglRendererSession *session)
{
    if (session == NULL)
        return;
    if (session->log_callback_installed) {
        session->functions.set_log_callback(NULL, NULL, NULL);
        session->log_callback_installed = false;
    }
    if (session->renderer_initialized) {
        session->functions.cleanup(session);
        session->renderer_initialized = false;
    }
#if defined(DORY_VIRGL_RENDERER_DUAL_METAL)
    dory_terminate_angle(session);
#endif
    dory_destroy_fence_registry(session);
    if (session->submit_diagnostic_lock_initialized) {
        pthread_mutex_destroy(&session->submit_diagnostic_lock);
        session->submit_diagnostic_lock_initialized = false;
    }
    dory_release_process_slot(session);
    free(session);
}

int32_t DoryVirglRendererSessionCreate(DoryVirglRendererSession **out_session)
{
    if (out_session == NULL || *out_session != NULL)
        return -EINVAL;

    if (setenv(
            "APP_SANDBOX_GROUP_ID",
            dory_renderer_app_sandbox_group,
            1
        ) != 0)
        return errno ? -errno : -EINVAL;

    DoryVirglRendererSession *session = calloc(1, sizeof(*session));
    if (session == NULL)
        return -ENOMEM;

    int32_t result = pthread_mutex_init(&session->fence_lock, NULL);
    if (result != 0) {
        free(session);
        return -result;
    }
    session->fence_lock_initialized = true;
    result = pthread_mutex_init(&session->submit_diagnostic_lock, NULL);
    if (result != 0) {
        dory_destroy_partial_session(session);
        return -result;
    }
    session->submit_diagnostic_lock_initialized = true;

    /* virglrenderer and its external EGL winsys are process-global. Claim before constructing
     * either ANGLE or renderer state so two concurrent bootstrap attempts cannot briefly create
     * independent share groups and then race for the foreign singleton. */
    result = dory_claim_process_slot(session);
    if (result != 0) {
        dory_destroy_partial_session(session);
        return result;
    }

#if defined(DORY_VIRGL_RENDERER_DUAL_METAL)
    result = pthread_mutex_init(&session->angle_context_lock, NULL);
    if (result != 0) {
        dory_destroy_partial_session(session);
        return -result;
    }
    session->angle_context_lock_initialized = true;
    session->angle_display = EGL_NO_DISPLAY;
    result = dory_initialize_angle(session);
    if (result != 0) {
        dory_destroy_partial_session(session);
        return result;
    }
    result = dory_run_angle_execution_self_test(session);
    if (result != 0) {
        dory_destroy_partial_session(session);
        return result;
    }
#endif

    result = dory_bind_static_functions(session);
    if (result != 0) {
        dory_destroy_partial_session(session);
        return result;
    }
    session->functions.set_log_callback(dory_renderer_log_callback, session, NULL);
    session->log_callback_installed = true;

    session->callbacks = (DoryVirglRendererCallbacks){
        .version = DORY_VIRGL_RENDERER_CALLBACKS_VERSION,
        .write_fence = dory_write_fence,
#if defined(DORY_VIRGL_RENDERER_DUAL_METAL)
        .create_gl_context = dory_create_gl_context,
        .destroy_gl_context = dory_destroy_gl_context,
        .make_current = dory_make_current,
#else
        .create_gl_context = NULL,
        .destroy_gl_context = NULL,
        .make_current = NULL,
#endif
        .get_drm_fd = NULL,
        .write_context_fence = dory_write_context_fence,
        .get_server_fd = NULL,
#if defined(DORY_VIRGL_RENDERER_DUAL_METAL)
        .get_egl_display = dory_get_egl_display,
#else
        .get_egl_display = NULL,
#endif
    };
    result = session->functions.initialize(
        session,
#if defined(DORY_VIRGL_RENDERER_DUAL_METAL)
        DORY_VIRGL_RENDERER_DUAL_METAL_INITIALIZATION_FLAGS,
#else
        DORY_VIRGL_RENDERER_VENUS_ONLY_INITIALIZATION_FLAGS,
#endif
        &session->callbacks
    );
    if (result != 0) {
        dory_destroy_partial_session(session);
        return result;
    }
    session->renderer_initialized = true;
    *out_session = session;
    return 0;
}

void DoryVirglRendererSessionDestroy(DoryVirglRendererSession *session)
{
    dory_destroy_partial_session(session);
}

int32_t DoryVirglRendererGetCapset(
    DoryVirglRendererSession *session,
    uint32_t capset_id,
    uint32_t *maximum_version,
    void *bytes,
    size_t capacity,
    size_t *actual_size
)
{
    if (session == NULL || maximum_version == NULL || actual_size == NULL)
        return -EINVAL;
    uint32_t version = 0;
    uint32_t size = 0;
    session->functions.get_cap_set(capset_id, &version, &size);
    *maximum_version = version;
    *actual_size = size;
    if (size == 0)
        return -ENOTSUP;
    if (bytes == NULL)
        return capacity == 0 ? 0 : -EINVAL;
    if (capacity < size)
        return -EMSGSIZE;
    session->functions.fill_caps(capset_id, version, bytes);
    return 0;
}

int32_t DoryVirglRendererContextCreate(
    DoryVirglRendererSession *session,
    uint32_t context_id,
    uint32_t flags,
    const char *name,
    size_t name_length
)
{
    if (session == NULL || context_id == 0 || name == NULL ||
        name_length == 0 || name_length > UINT32_MAX)
        return -EINVAL;
    const int32_t result = session->functions.context_create(
        context_id,
        flags,
        (uint32_t)name_length,
        name
    );
    return result;
}

void DoryVirglRendererContextDestroy(
    DoryVirglRendererSession *session,
    uint32_t context_id
)
{
    if (session == NULL || context_id == 0)
        return;
    session->functions.context_destroy(context_id);
    dory_remove_context_fence_completions(session, context_id);
}

void DoryVirglRendererContextAttachResource(
    DoryVirglRendererSession *session,
    uint32_t context_id,
    uint32_t resource_id
)
{
    if (session == NULL || context_id == 0 || resource_id == 0)
        return;
    session->functions.context_attach_resource((int32_t)context_id, (int32_t)resource_id);
}

void DoryVirglRendererContextDetachResource(
    DoryVirglRendererSession *session,
    uint32_t context_id,
    uint32_t resource_id
)
{
    if (session == NULL || context_id == 0 || resource_id == 0)
        return;
    session->functions.context_detach_resource((int32_t)context_id, (int32_t)resource_id);
}

int32_t DoryVirglRendererSubmit(
    DoryVirglRendererSession *session,
    uint32_t context_id,
    const void *command_bytes,
    uint32_t dword_count,
    DoryVirglRendererSubmitDiagnostic *diagnostic
)
{
    if (diagnostic != NULL)
        *diagnostic = (DoryVirglRendererSubmitDiagnostic){0};
    if (session == NULL || context_id == 0 || command_bytes == NULL ||
        diagnostic == NULL ||
        dword_count == 0 || dword_count > INT32_MAX ||
        ((uintptr_t)command_bytes & 7U) != 0)
        return -EINVAL;

    pthread_mutex_lock(&session->submit_diagnostic_lock);
    if (session->submit_in_progress) {
        pthread_mutex_unlock(&session->submit_diagnostic_lock);
        return -EBUSY;
    }
    session->active_submit_context_id = context_id;
    session->submit_diagnostic = (DoryVirglRendererSubmitDiagnostic){0};
    session->submit_in_progress = true;
    pthread_mutex_unlock(&session->submit_diagnostic_lock);

    const int32_t result = session->functions.submit_cmd2(
        (void *)command_bytes,
        (int32_t)context_id,
        (int32_t)dword_count,
        NULL,
        0
    );

    pthread_mutex_lock(&session->submit_diagnostic_lock);
    session->submit_in_progress = false;
    session->active_submit_context_id = 0;
    if (session->submit_diagnostic.valid != 0 ||
        session->submit_diagnostic.precursor_category != DORY_VIRGL_PRECURSOR_NONE ||
        session->submit_diagnostic.failed_command_location_disposition !=
            DORY_VIRGL_FAILED_COMMAND_LOCATION_ABSENT) {
        *diagnostic = session->submit_diagnostic;
        if (diagnostic->failed_command_location_disposition ==
                DORY_VIRGL_FAILED_COMMAND_LOCATION_PRESENT &&
            diagnostic->status != result) {
            diagnostic->failed_command_location_disposition =
                DORY_VIRGL_FAILED_COMMAND_LOCATION_AMBIGUOUS;
            diagnostic->failed_command_dword_offset = 0;
            diagnostic->failed_command_ordinal = 0;
        }
        if (diagnostic->failed_command_location_disposition !=
                DORY_VIRGL_FAILED_COMMAND_LOCATION_ABSENT ||
            (diagnostic->valid != 0 && diagnostic->command_id == 1U)) {
            (void)DoryVirglRendererCorrelateCreateObjectSubtype(
                command_bytes,
                dword_count,
                diagnostic
            );
        }
    }
    session->submit_diagnostic = (DoryVirglRendererSubmitDiagnostic){0};
    pthread_mutex_unlock(&session->submit_diagnostic_lock);
    return result;
}

int32_t DoryVirglRendererBlobCreate(
    DoryVirglRendererSession *session,
    const DoryVirglRendererBlobCreateArguments *arguments
)
{
    if (session == NULL || arguments == NULL || arguments->resource_handle == 0 ||
        (arguments->iovecs == NULL) != (arguments->iovec_count == 0))
        return -EINVAL;
    const int32_t result = session->functions.blob_create(arguments);
    return result;
}

int32_t DoryVirglRendererResource3DCreate(
    DoryVirglRendererSession *session,
    const DoryVirglRendererResource3DCreateArguments *arguments
)
{
    if (session == NULL || arguments == NULL || arguments->handle == 0 ||
        arguments->format == 0 || arguments->width == 0 ||
        arguments->height == 0 || arguments->depth == 0 ||
        arguments->array_size == 0)
        return -EINVAL;
    DoryVirglRendererResource3DCreateArguments mutable_arguments = *arguments;
    return session->functions.resource_create(&mutable_arguments, NULL, 0);
}

int32_t DoryVirglRendererResourceAttachBacking(
    DoryVirglRendererSession *session,
    uint32_t resource_id,
    const struct iovec *iovecs,
    uint32_t iovec_count
)
{
    if (session == NULL || resource_id == 0 || iovecs == NULL ||
        iovec_count == 0 || iovec_count > INT32_MAX)
        return -EINVAL;
    const int32_t result = session->functions.resource_attach_iov(
        (int32_t)resource_id,
        (struct iovec *)iovecs,
        (int32_t)iovec_count
    );
    return result;
}

void DoryVirglRendererResourceDetachBacking(
    DoryVirglRendererSession *session,
    uint32_t resource_id
)
{
    if (session == NULL || resource_id == 0)
        return;
    session->functions.resource_detach_iov((int32_t)resource_id, NULL, NULL);
}

void DoryVirglRendererResourceUnref(
    DoryVirglRendererSession *session,
    uint32_t resource_id
)
{
    if (session == NULL || resource_id == 0)
        return;
    session->functions.resource_unref(resource_id);
}

int32_t DoryVirglRendererResourceGetMapInfo(
    DoryVirglRendererSession *session,
    uint32_t resource_id,
    uint32_t *map_info
)
{
    if (session == NULL || resource_id == 0 || map_info == NULL)
        return -EINVAL;
    return session->functions.resource_get_map_info(resource_id, map_info);
}

int32_t DoryVirglRendererResourceExportBlob(
    DoryVirglRendererSession *session,
    uint32_t resource_id,
    uint32_t *fd_type,
    int32_t *owned_file_descriptor
)
{
    if (session == NULL || resource_id == 0 || fd_type == NULL ||
        owned_file_descriptor == NULL)
        return -EINVAL;
    *fd_type = 0;
    *owned_file_descriptor = -1;
    return session->functions.resource_export_blob(
        resource_id,
        fd_type,
        owned_file_descriptor
    );
}

int32_t DoryVirglRendererResourceGetInfo(
    DoryVirglRendererSession *session,
    uint32_t resource_id,
    DoryVirglRendererResourceInfo *info
)
{
    if (session == NULL || resource_id == 0 || info == NULL)
        return -EINVAL;
    memset(info, 0, sizeof(*info));
    return session->functions.resource_get_info((int32_t)resource_id, info);
}

int32_t DoryVirglRendererResourceAcquireScanoutMetalTexture(
    DoryVirglRendererSession *session,
    uint32_t resource_id,
    uint32_t width,
    uint32_t height,
    uint32_t virgl_format,
    uint32_t stride,
    uint32_t offset,
    void **retained_texture
)
{
    if (session == NULL || resource_id == 0 || width == 0 || height == 0 ||
        stride == 0 || retained_texture == NULL)
        return -EINVAL;
    *retained_texture = NULL;
    void *handle = NULL;
    const int32_t type = session->functions.create_handle_for_scanout(
        resource_id,
        width,
        height,
        virgl_format,
        0,
        stride,
        offset,
        &handle
    );
    if (type != DORY_VIRGL_RENDERER_NATIVE_HANDLE_METAL_TEXTURE || handle == NULL) {
        if (type != 0 && handle != NULL)
            session->functions.release_handle_for_scanout(type, handle);
        return -ENOTSUP;
    }
    *retained_texture = handle;
    return 0;
}

int32_t DoryVirglRendererTransferToHost(
    DoryVirglRendererSession *session,
    uint32_t resource_id,
    uint32_t context_id,
    uint32_t level,
    uint32_t stride,
    uint32_t layer_stride,
    const DoryVirglRendererBox *box,
    uint64_t offset,
    const struct iovec *iovecs,
    uint32_t iovec_count
)
{
    if (session == NULL || resource_id == 0 || box == NULL ||
        (iovecs == NULL) != (iovec_count == 0))
        return -EINVAL;
    const int32_t result = session->functions.transfer_write_iov(
        resource_id,
        context_id,
        (int32_t)level,
        stride,
        layer_stride,
        (DoryVirglRendererBox *)box,
        offset,
        (struct iovec *)iovecs,
        iovec_count
    );
    return result;
}

int32_t DoryVirglRendererTransferFromHost(
    DoryVirglRendererSession *session,
    uint32_t resource_id,
    uint32_t context_id,
    uint32_t level,
    uint32_t stride,
    uint32_t layer_stride,
    const DoryVirglRendererBox *box,
    uint64_t offset,
    const struct iovec *iovecs,
    uint32_t iovec_count
)
{
    if (session == NULL || resource_id == 0 || box == NULL ||
        (iovecs == NULL) != (iovec_count == 0) || iovec_count > INT32_MAX)
        return -EINVAL;
    const int32_t result = session->functions.transfer_read_iov(
        resource_id,
        context_id,
        level,
        stride,
        layer_stride,
        (DoryVirglRendererBox *)box,
        offset,
        (struct iovec *)iovecs,
        (int32_t)iovec_count
    );
    return result;
}

int32_t DoryVirglRendererCreateContextFence(
    DoryVirglRendererSession *session,
    uint32_t context_id,
    uint32_t flags,
    uint32_t ring_index,
    uint64_t fence_id
)
{
    if (session == NULL || context_id == 0 || fence_id == 0)
        return -EINVAL;
    int32_t result = dory_register_fence_completion(
        session,
        context_id,
        ring_index,
        fence_id,
        false,
        NULL
    );
    if (result != 0)
        return result;
    result = session->functions.context_create_fence(
        context_id,
        flags,
        ring_index,
        fence_id
    );
    if (result != 0)
        dory_cancel_fence_completion(session, context_id, ring_index, fence_id);
    return result;
}

int32_t DoryVirglRendererCreateGlobalFence(
    DoryVirglRendererSession *session,
    uint64_t fence_id
)
{
    if (session == NULL || fence_id == 0 || session->functions.create_fence == NULL)
        return -EINVAL;
    uint32_t renderer_fence_id = 0;
    int32_t result = dory_register_fence_completion(
        session,
        0,
        0,
        fence_id,
        true,
        &renderer_fence_id
    );
    if (result != 0)
        return result;
    result = session->functions.create_fence((int32_t)renderer_fence_id, 0);
    if (result != 0)
        dory_cancel_fence_completion(session, 0, 0, fence_id);
    return result;
}

int32_t DoryVirglRendererGetFenceFileDescriptor(
    DoryVirglRendererSession *session,
    uint64_t fence_id
)
{
    if (session == NULL || fence_id == 0)
        return -1;
    pthread_mutex_lock(&session->fence_lock);
    DoryVirglRendererFenceCompletion *completion = session->fence_head;
    while (completion != NULL && completion->fence_id != fence_id)
        completion = completion->next;
    if (completion == NULL || completion->read_descriptor < 0) {
        pthread_mutex_unlock(&session->fence_lock);
        return -1;
    }

    const int descriptor = completion->read_descriptor;
    completion->read_descriptor = -1;
    if (completion->write_descriptor < 0)
        dory_remove_fence_completion_locked(session, completion);
    pthread_mutex_unlock(&session->fence_lock);
    return descriptor;
}

int32_t DoryVirglRendererGetPollFileDescriptor(DoryVirglRendererSession *session)
{
    if (session == NULL || session->functions.get_poll_fd == NULL)
        return -1;
    return session->functions.get_poll_fd();
}

void DoryVirglRendererPoll(DoryVirglRendererSession *session)
{
    if (session == NULL)
        return;
    session->functions.poll();
}
