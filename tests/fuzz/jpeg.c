/* Optional libFuzzer target for the actual resumable C adapter, using plain JPEG
 * inputs so saved crashes can be decoded or minimized without a recipe format. */
#include "jpeg_stb.h"
#include <assert.h>
#include <stdlib.h>
#include <string.h>

enum { DONE = 0, PROGRESS = 1, OOM = 5, MEMORY = 8 * 1024 * 1024 };
typedef struct { void *ptr; size_t size; } Allocation;
typedef struct {
    Allocation slots[16];
    size_t live, calls, fail_at;
    unsigned char fill;
} Allocator;
typedef struct { int status; djvu_jpeg_info info; unsigned char *rgb; } Result;

static void *allocate(void *user, size_t size) {
    Allocator *a = user;
    assert(size != 0);
    if (a->calls++ == a->fail_at || size > MEMORY - a->live) return NULL;
    for (size_t i = 0; i < 16; i++) if (!a->slots[i].ptr) {
        void *ptr = malloc(size);
        assert(ptr);
        memset(ptr, a->fill, size);
        a->slots[i] = (Allocation){ptr, size};
        a->live += size;
        return ptr;
    }
    abort();
}

static void release(void *user, void *ptr, size_t size) {
    Allocator *a = user;
    for (size_t i = 0; i < 16; i++) if (a->slots[i].ptr == ptr && ptr) {
        assert(a->slots[i].size == size);
        a->slots[i].ptr = NULL;
        a->live -= size;
        free(ptr);
        return;
    }
    abort();
}

static Result decode(void *state, const uint8_t *data, size_t size,
                     djvu_jpeg_limits limits, size_t work, size_t stop,
                     size_t fail_at, unsigned char fill) {
    Allocator a = {.fail_at = fail_at, .fill = fill};
    Result r = {0};
    r.status = djvu_jpeg_init(state, data, size, &a, allocate, release, limits, &r.info);
    if (r.status == DONE) {
        size_t pixels = (size_t)r.info.width * r.info.height;
        assert(r.info.width && r.info.height && pixels <= limits.pixels);
        r.rgb = malloc(pixels * 3);
        assert(r.rgb);
        memset(r.rgb, fill, pixels * 3);
        assert(djvu_jpeg_step(state, 0, r.rgb) == PROGRESS);
        r.status = PROGRESS;
        // Each advance consumes a marker, a block or at least one RGB pixel,
        // apart from at most four allocations and four resampler initializations.
        size_t bound = limits.markers + limits.blocks + limits.pixels + 16;
        size_t used = 0;
        while (r.status == PROGRESS && used < stop) {
            size_t next = work < stop - used ? work : stop - used;
            r.status = djvu_jpeg_step(state, next, r.rgb);
            used += next;
            assert(r.status != PROGRESS || used <= bound);
        }
        if (r.status == DONE) assert(djvu_jpeg_step(state, work, r.rgb) == DONE);
    }
    assert(r.status >= DONE && r.status <= OOM);
    djvu_jpeg_deinit(state); // Also required after failed init or a partial step.
    assert(a.live == 0);
    return r;
}

int LLVMFuzzerTestOneInput(const uint8_t *data, size_t size) {
    if (size > 32768) return 0;
    uint32_t control = 2166136261u;
    for (size_t i = 0; i < size; i++) control = (control ^ data[i]) * 16777619u;
    void *state = malloc(djvu_jpeg_size());
    assert(state);
    djvu_jpeg_limits limits = {.pixels = 256 * 1024, .markers = 8192, .scans = 64, .blocks = 32768};
    Result first = decode(state, data, size, limits, 4096, SIZE_MAX, SIZE_MAX, 0xa5);
    Result second = decode(state, data, size, limits, 1 + control % 31, SIZE_MAX, SIZE_MAX, 0x5a);
    assert(first.status == second.status);
    if (first.status == DONE) {
        assert(first.info.width == second.info.width && first.info.height == second.info.height);
        // Different work portions and initial memory contents must not change a
        // completed image. This also exposes reads of unwritten coefficients.
        assert(memcmp(first.rgb, second.rgb, (size_t)first.info.width * first.info.height * 3) == 0);
    }
    free(first.rgb);
    free(second.rgb);

    // Keep an unrestricted decode above; vary failures, limits and early teardown
    // independently, without preventing mutations from reaching the RGB phase.
    switch ((control >> 8) % 5) {
    case 0: limits.pixels = 1 + ((control >> 16) & 255); break;
    case 1: limits.markers = 1 + ((control >> 16) & 31); break;
    case 2: limits.scans = 1 + ((control >> 16) & 7); break;
    case 3: limits.blocks = 1 + ((control >> 16) & 255); break;
    }
    size_t stop = control & 1 ? SIZE_MAX : (control >> 16) & 255;
    Result partial = decode(state, data, size, limits, 1, stop, (control >> 12) % 16, 0x3c);
    free(partial.rgb);
    free(state);
    return 0;
}
