/* JPEG adapter derived in part from stb_image, MIT; see THIRD_PARTY_NOTICES.txt.
 * The pinned private routines handle coding/IDCT/resampling. This adapter owns
 * buffers, scan validation and resumable scheduling. No global allocator state.
 */
#include "jpeg_stb.h"
#define STBI_ONLY_JPEG
#define STBI_NO_STDIO
#define STBI_NO_SIMD
#define STBI_NO_LINEAR
#define STBI_NO_HDR
#define STBI_NO_THREAD_LOCALS
#define STBI_NO_FAILURE_STRINGS
#define STBI_MAX_DIMENSIONS 65535
#define STBI_ASSERT(x) do { if (!(x)) __builtin_trap(); } while (0)
/* Disable whole-image allocation; the adapter owns all buffers. */
#define STBI_MALLOC(n) ((void)(n), (void *)0)
#define STBI_REALLOC_SIZED(p,o,n) ((void)(p), (void)(o), (void)(n), (void *)0)
#define STBI_FREE(p) ((void)(p))
#define STB_IMAGE_STATIC
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"

enum { DONE, PROGRESS, BAD, UNSUPPORTED, LIMIT, OOM };
enum { ALLOCATE, MARKER, ENTROPY, IDCT, RESAMPLE_INIT, RGB, COMPLETE };
typedef struct {
    stbi__context input;
    stbi__jpeg jpeg;
    void *user;
    djvu_jpeg_alloc alloc;
    djvu_jpeg_free release;
    djvu_jpeg_limits limits;
    size_t markers, scans, blocks;
    int phase, component, block, mcu, mcu_blocks, mcu_width, mcu_count, restart;
    unsigned int tables_q, tables_dc, tables_ac, decoded;
    signed char levels[4][64];
    stbi__uint16 quant[4][64]; // Latch each component's table on its first scan.
    stbi__resample resample[4];
    stbi_uc *rows[4];
    unsigned int row, column;
} Decoder;

size_t djvu_jpeg_size(void) { return sizeof(Decoder); }

static int marker(Decoder *d, int recover) {
    stbi__jpeg *j = &d->jpeg;
    if (++d->markers > d->limits.markers) return -LIMIT;
    if (j->marker != STBI__MARKER_none) {
        int value = j->marker;
        j->marker = STBI__MARKER_none;
        return value;
    }
    stbi__context *s = &d->input;
    while (s->img_buffer != s->img_buffer_end) {
        if (*s->img_buffer++ == 255) {
            while (s->img_buffer != s->img_buffer_end && *s->img_buffer == 255) {
                s->img_buffer++;
                if (++d->markers > d->limits.markers) return -LIMIT;
            }
            if (s->img_buffer == s->img_buffer_end) return -BAD;
            int value = *s->img_buffer++;
            if (value != 0) return value;
        }
        // Some producers leave junk or FF00 between header segments. Only
        // recover outside entropy data; the next marker must still validate.
        // Discarded bytes count toward the marker parsing budget.
        if (!recover) return -BAD;
        if (++d->markers > d->limits.markers) return -LIMIT;
    }
    return -BAD;
}

static int is_sof(int m) { return m >= 0xc0 && m <= 0xcf && m != 0xc4 && m != 0xc8 && m != 0xcc; }

/* Bound each marker segment before calling an upstream parser. */
static int segment(Decoder *d, int m, int frame) {
    stbi__context *s = &d->input;
    stbi__jpeg *j = &d->jpeg;
    stbi_uc *start = s->img_buffer, *end = s->img_buffer_end;
    if (end - start < 2) return BAD;
    size_t length = ((size_t)start[0] << 8) | start[1];
    if (length < 2 || length > (size_t)(end - start)) return BAD;
    if (is_sof(m)) {
        if (!frame) return BAD;
        if (m != 0xc0 && m != 0xc1 && m != 0xc2) return UNSUPPORTED;
        if (length < 8) return BAD;
        if (start[2] != 8 || (start[3] == 0 && start[4] == 0)) return UNSUPPORTED;
        if (start[7] != 1 && start[7] != 3 && start[7] != 4) return UNSUPPORTED;
        j->progressive = m == 0xc2;
    } else if (m == 0xcc || m == 0xde || m == 0xdf) return UNSUPPORTED;
    else if (m != 0xc4 && m != 0xdb && m != 0xdd && m != 0xda &&
             m != 0xdc && m != 0xfe && !(m >= 0xe0 && m <= 0xef)) return BAD;
    s->img_buffer_end = start + length;
    int ok;
    if (is_sof(m)) ok = stbi__process_frame_header(j, STBI__SCAN_header);
    else if (m == 0xda) ok = stbi__process_scan_header(j);
    else if (m == 0xdc) {
        ok = length == 4 && (((unsigned)start[2] << 8) | start[3]) == s->img_y;
        s->img_buffer = start + length;
    } else ok = stbi__process_marker(j, m);
    s->img_buffer_end = end;
    if (!ok || s->img_buffer != start + length) return BAD;
    if (m == 0xdb || m == 0xc4) {
        size_t pos = 2;
        while (pos < length) {
            unsigned int descriptor = start[pos++], table = descriptor & 15;
            if (m == 0xdb) {
                d->tables_q |= 1u << table;
                size_t size = descriptor >> 4 ? 128 : 64;
                for (size_t i = 0; i < size; i += size / 64)
                    if (start[pos+i] == 0 && (size == 64 || start[pos+i+1] == 0)) return BAD;
                pos += size;
            } else {
                unsigned int count = 0;
                for (int i = 0; i < 16; i++) count += start[pos++];
                if (descriptor >> 4) d->tables_ac |= 1u << table;
                else d->tables_dc |= 1u << table;
                pos += count;
            }
        }
    }
    return DONE;
}

int djvu_jpeg_init(void *state, const unsigned char *data, size_t size, void *user,
                   djvu_jpeg_alloc alloc, djvu_jpeg_free release,
                   djvu_jpeg_limits limits, djvu_jpeg_info *info) {
    Decoder *d = state;
    memset(d, 0, sizeof(*d));
    d->user = user;
    d->alloc = alloc;
    d->release = release;
    d->limits = limits;
    memset(d->levels, -1, sizeof(d->levels));
    if (size < 2 || size > INT_MAX || data[0] != 255 || data[1] != 0xd8) return BAD;
    stbi__start_mem(&d->input, data, (int)size);
    stbi__jpeg *j = &d->jpeg;
    j->s = &d->input;
    j->marker = STBI__MARKER_none;
    j->app14_color_transform = -1;
    stbi__setup_jpeg(j);
    d->input.img_buffer += 2;
    for (;;) {
        int m = marker(d, 1);
        if (m < 0) return -m;
        int status = segment(d, m, 1);
        if (status) return status;
        if (is_sof(m)) break;
    }
    if ((uint64_t)d->input.img_x * d->input.img_y > limits.pixels) return LIMIT;
    int h = 1, v = 1;
    for (int n = 0; n < d->input.img_n; n++) {
        if (j->img_comp[n].h > h) h = j->img_comp[n].h;
        if (j->img_comp[n].v > v) v = j->img_comp[n].v;
        for (int k = 0; k < n; k++) if (j->img_comp[k].id == j->img_comp[n].id) return BAD;
    }
    j->img_h_max = h;
    j->img_v_max = v;
    j->img_mcu_x = (d->input.img_x + h*8 - 1) / (h*8);
    j->img_mcu_y = (d->input.img_y + v*8 - 1) / (v*8);
    for (int n = 0; n < d->input.img_n; n++) {
        if (h % j->img_comp[n].h || v % j->img_comp[n].v) return UNSUPPORTED;
        j->img_comp[n].x = (d->input.img_x * j->img_comp[n].h + h - 1) / h;
        j->img_comp[n].y = (d->input.img_y * j->img_comp[n].v + v - 1) / v;
        j->img_comp[n].w2 = j->img_mcu_x * j->img_comp[n].h * 8;
        j->img_comp[n].h2 = j->img_mcu_y * j->img_comp[n].v * 8;
        j->img_comp[n].coeff_w = j->img_comp[n].w2 / 8;
        j->img_comp[n].coeff_h = j->img_comp[n].h2 / 8;
    }
    info->width = d->input.img_x;
    info->height = d->input.img_y;
    return DONE;
}

void djvu_jpeg_deinit(void *state) {
    Decoder *d = state;
    for (int n = 0; n < 4; n++) {
        size_t count = (size_t)d->jpeg.img_comp[n].w2 * d->jpeg.img_comp[n].h2;
        if (d->jpeg.img_comp[n].data) d->release(d->user, d->jpeg.img_comp[n].data, count);
        if (d->jpeg.img_comp[n].coeff) d->release(d->user, d->jpeg.img_comp[n].coeff, count * sizeof(short));
        if (d->jpeg.img_comp[n].linebuf) d->release(d->user, d->jpeg.img_comp[n].linebuf, d->input.img_x + 3);
    }
}

static int start_scan(Decoder *d) {
    stbi__jpeg *j = &d->jpeg;
    if (++d->scans > d->limits.scans) return LIMIT;
    if (j->progressive && j->spec_start && j->scan_n != 1) return BAD;
    if (j->progressive && j->succ_high && j->succ_low + 1 != j->succ_high) return BAD;
    unsigned int seen = 0;
    d->mcu_blocks = 0;
    for (int k = 0; k < j->scan_n; k++) {
        int n = j->order[k];
        if (seen & (1u << n)) return BAD;
        seen |= 1u << n;
        if (!(d->tables_q & (1u << j->img_comp[n].tq))) return BAD;
        if ((!j->progressive || (j->spec_start == 0 && j->succ_high == 0)) &&
            !(d->tables_dc & (1u << j->img_comp[n].hd))) return BAD;
        if ((!j->progressive || j->spec_start != 0) && !(d->tables_ac & (1u << j->img_comp[n].ha))) return BAD;
        if (d->levels[n][0] < 0) memcpy(d->quant[n], j->dequant[j->img_comp[n].tq], sizeof(d->quant[n]));
        if (j->progressive) {
            if (j->spec_start && d->levels[n][0] < 0) return BAD;
            for (int p = j->spec_start; p <= j->spec_end; p++) {
                if (d->levels[n][p] != (j->succ_high ? j->succ_high : -1)) return BAD;
                d->levels[n][p] = j->succ_low;
            }
        } else if (d->decoded & (1u << n)) return BAD;
        d->mcu_blocks += j->img_comp[n].h * j->img_comp[n].v;
    }
    if (j->scan_n == 1) {
        int n = j->order[0];
        d->mcu_width = (j->img_comp[n].x + 7) / 8;
        d->mcu_count = d->mcu_width * ((j->img_comp[n].y + 7) / 8);
        d->mcu_blocks = 1;
    } else {
        d->mcu_width = j->img_mcu_x;
        d->mcu_count = j->img_mcu_x * j->img_mcu_y;
    }
    d->mcu = d->block = d->restart = 0;
    stbi__jpeg_reset(j);
    d->phase = ENTROPY;
    return DONE;
}

static int end_entropy(Decoder *d, int restart) {
    stbi__jpeg *j = &d->jpeg;
    if (j->code_bits < 24) stbi__grow_buffer_unsafe(j);
    int real = j->code_bits - j->synthetic_bits;
    if (real < 0 || real > 7) return BAD;
    // A few producers pad the final byte with zeros. All declared blocks have
    // already decoded using real bits; accept uniform padding, never extra data.
    if (real) {
        unsigned int padding = j->code_buffer >> (32 - real);
        if (padding != 0 && padding != (1u << real) - 1) return BAD;
    }
    int m = marker(d, 0);
    if (m < 0) return -m;
    if (restart) {
        if (j->eob_run) return BAD;
        if (m != 0xd0 + d->restart) return BAD;
        d->restart = (d->restart + 1) % 8;
        stbi__jpeg_reset(j);
    } else {
        if (STBI__RESTART(m)) {
            if (!j->restart_interval || m != 0xd0 + d->restart) return BAD;
            m = marker(d, 0);
            if (m < 0) return -m;
        }
        j->marker = (unsigned char)m;
    }
    return DONE;
}

static int entropy_block(Decoder *d) {
    stbi__jpeg *j = &d->jpeg;
    if (++d->blocks > d->limits.blocks) return LIMIT;
    int n = j->order[0], x = d->mcu % d->mcu_width, y = d->mcu / d->mcu_width;
    if (j->scan_n != 1) {
        int b = d->block, k = 0;
        while (b >= j->img_comp[n].h * j->img_comp[n].v) {
            b -= j->img_comp[n].h * j->img_comp[n].v;
            n = j->order[++k];
        }
        x = x * j->img_comp[n].h + b % j->img_comp[n].h;
        y = y * j->img_comp[n].v + b / j->img_comp[n].h;
    }
    int ha = j->img_comp[n].ha, hd = j->img_comp[n].hd, ok;
    if (j->progressive) {
        short *block = j->img_comp[n].coeff + 64 * (x + y * j->img_comp[n].coeff_w);
        if (j->spec_start == 0) ok = stbi__jpeg_decode_block_prog_dc(j, block, j->huff_dc + hd, n);
        else ok = stbi__jpeg_decode_block_prog_ac(j, block, j->huff_ac + ha, j->fast_ac[ha]);
    } else {
        short block[64];
        ok = stbi__jpeg_decode_block(j, block, j->huff_dc + hd, j->huff_ac + ha, j->fast_ac[ha], n, d->quant[n]);
        if (ok) j->idct_block_kernel(j->img_comp[n].data + y*8*j->img_comp[n].w2 + x*8, j->img_comp[n].w2, block);
    }
    if (!ok || j->code_bits < j->synthetic_bits) return BAD;
    if (++d->block == d->mcu_blocks) {
        d->block = 0;
        d->mcu++;
        if (d->mcu == d->mcu_count) {
            int status = end_entropy(d, 0);
            if (status) return status;
            if (j->eob_run) return BAD;
            for (int k = 0; k < j->scan_n; k++) d->decoded |= 1u << j->order[k];
            d->phase = MARKER;
        } else if (--j->todo == 0) return end_entropy(d, 1);
    }
    return DONE;
}

static int rgb(Decoder *d, unsigned char *output) {
    stbi__jpeg *j = &d->jpeg;
    if (d->column == 0) {
        for (int n = 0; n < d->input.img_n; n++) {
            stbi__resample *r = &d->resample[n];
            int bottom = r->ystep >= (r->vs >> 1);
            d->rows[n] = r->resample(j->img_comp[n].linebuf, bottom ? r->line1 : r->line0,
                                    bottom ? r->line0 : r->line1, r->w_lores, r->hs);
            if (++r->ystep >= r->vs) {
                r->ystep = 0;
                r->line0 = r->line1;
                if (++r->ypos < j->img_comp[n].y) r->line1 += j->img_comp[n].w2;
            }
        }
    }
    unsigned int count = d->input.img_x - d->column;
    if (count > 256) count = 256;
    unsigned char temp[4 * 256];
    int direct = j->rgb == 3 || (j->app14_color_transform == 0 && !j->jfif);
    if ((d->input.img_n == 3 && !direct) || (d->input.img_n == 4 && j->app14_color_transform == 2))
        j->YCbCr_to_RGB_kernel(temp, d->rows[0]+d->column, d->rows[1]+d->column, d->rows[2]+d->column, count, 4);
    for (unsigned int k = 0; k < count; k++) {
        unsigned int x = d->column + k;
        unsigned char *out = output + 3 * ((size_t)d->row * d->input.img_x + x);
        for (int c = 0; c < 3; c++) {
            if (d->input.img_n == 1) {
                out[c] = d->rows[0][x];
            } else if (d->input.img_n == 3) {
                out[c] = direct ? d->rows[c][x] : temp[k*4+c];
            } else {
                out[c] = stbi__blinn_8x8(
                    j->app14_color_transform == 0 ? d->rows[c][x] : 255-temp[k*4+c], d->rows[3][x]);
            }
        }
    }
    d->column += count;
    if (d->column == d->input.img_x) {
        d->column = 0;
        if (++d->row == d->input.img_y) d->phase = COMPLETE;
    }
    return DONE;
}

static int advance(Decoder *d, unsigned char *output) {
    stbi__jpeg *j = &d->jpeg;
    int n = d->component;
    switch (d->phase) {
    case ALLOCATE: {
        uint64_t extent = (uint64_t)j->img_comp[n].w2 * j->img_comp[n].h2;
        if (extent > SIZE_MAX / sizeof(short)) return LIMIT;
        size_t count = (size_t)extent;
        j->img_comp[n].data = d->alloc(d->user, count);
        if (!j->img_comp[n].data) return OOM;
        if (j->progressive) {
            j->img_comp[n].coeff = d->alloc(d->user, count * sizeof(short));
            if (!j->img_comp[n].coeff) return OOM;
        }
        if (++d->component == d->input.img_n) {
            d->component = 0;
            d->phase = MARKER;
        }
        return DONE;
    }
    case MARKER: {
        int m = marker(d, 1);
        if (m < 0) return -m;
        if (m == 0xd9) {
            if (d->decoded != (1u << d->input.img_n) - 1) return BAD;
            if (d->input.img_n == 4 && j->app14_color_transform != 0 && j->app14_color_transform != 2) return UNSUPPORTED;
            d->component = d->block = 0;
            d->phase = j->progressive ? IDCT : RESAMPLE_INIT;
            return DONE;
        }
        int status = segment(d, m, 0);
        if (status) return status;
        return m == 0xda ? start_scan(d) : DONE;
    }
    case ENTROPY: return entropy_block(d);
    case IDCT: {
        if (++d->blocks > d->limits.blocks) return LIMIT;
        int width = (j->img_comp[n].x + 7) / 8, height = (j->img_comp[n].y + 7) / 8;
        int x = d->block % width, y = d->block / width;
        short *block = j->img_comp[n].coeff + 64*(x+y*j->img_comp[n].coeff_w);
        for (int i = 0; i < 64; i++) {
            int value = (int)block[i] * d->quant[n][i];
            if (value < -32768 || value > 32767) return UNSUPPORTED;
            block[i] = (short)value;
        }
        j->idct_block_kernel(j->img_comp[n].data+y*8*j->img_comp[n].w2+x*8, j->img_comp[n].w2, block);
        if (++d->block == width * height) {
            d->release(d->user, j->img_comp[n].coeff, (size_t)j->img_comp[n].w2*j->img_comp[n].h2*sizeof(short));
            j->img_comp[n].coeff = NULL;
            d->block = 0;
            if (++d->component == d->input.img_n) {
                d->component = 0;
                d->phase = RESAMPLE_INIT;
            }
        }
        return DONE;
    }
    case RESAMPLE_INIT: {
        stbi__resample *r = &d->resample[n];
        j->img_comp[n].linebuf = d->alloc(d->user, d->input.img_x+3);
        if (!j->img_comp[n].linebuf) return OOM;
        r->hs = j->img_h_max / j->img_comp[n].h;
        r->vs = j->img_v_max / j->img_comp[n].v;
        r->ystep = r->vs >> 1;
        r->w_lores = (d->input.img_x+r->hs-1)/r->hs;
        r->line0 = r->line1 = j->img_comp[n].data;
        if (r->hs == 1 && r->vs == 1) r->resample = resample_row_1;
        else if (r->hs == 1 && r->vs == 2) r->resample = stbi__resample_row_v_2;
        else if (r->hs == 2 && r->vs == 1) r->resample = stbi__resample_row_h_2;
        else if (r->hs == 2 && r->vs == 2) r->resample = j->resample_row_hv_2_kernel;
        else r->resample = stbi__resample_row_generic;
        if (++d->component == d->input.img_n) d->phase = RGB;
        return DONE;
    }
    case RGB: return rgb(d, output);
    case COMPLETE: return DONE;
    default: return BAD;
    }
}

int djvu_jpeg_step(void *state, size_t work, unsigned char *rgb) {
    Decoder *d = state;
    for (size_t i = 0; i < work && d->phase != COMPLETE; i++) {
        int status = advance(d, rgb);
        if (status) return status;
    }
    return d->phase == COMPLETE ? DONE : PROGRESS;
}
