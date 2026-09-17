#ifndef DJVUTANG_H
#define DJVUTANG_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct djvutang_document djvutang_document;
typedef struct djvutang_job djvutang_job;
typedef int32_t djvutang_status;

enum {
    DJVUTANG_OK = 0,
    DJVUTANG_PROGRESS = 1,
    DJVUTANG_INVALID_DATA = 2,
    DJVUTANG_UNSUPPORTED = 3,
    DJVUTANG_LIMIT_EXCEEDED = 4,
    DJVUTANG_CANCELLED = 5,
    DJVUTANG_OUT_OF_MEMORY = 6,
    DJVUTANG_INVALID_ARGUMENT = 7,
    DJVUTANG_BUSY = 8,
    DJVUTANG_MISSING_COMPONENT = 9
};

/* Page and component indexes start at zero. Calls using the same document or
 * its job must be serialized, including cancellation and destruction. Different
 * documents are independent. Pointers must be valid for their stated lifetime. */

typedef struct {
    uint32_t width, height, dpi, rotation;
} djvutang_page_info;

typedef struct {
    uint32_t x, y, width, height;
} djvutang_region;

/* Zero-initialize, then set the desired fields. NULL means all defaults.
 * subsample: 0 or 1 for full size; 2..256 for integer reduction.
 * width/height: both zero, or a fit box preserving aspect ratio; excludes
 * subsample > 1. Shrinking can use reduced IW44 reconstruction.
 * rotation: additional counterclockwise quarter turns, 0..3.
 * region: all zero for the whole output, otherwise a nonempty rectangle in
 * output pixels after sizing and rotation. It must fit wholly inside the page. */
typedef struct {
    uint32_t subsample, rotation, width, height;
    djvutang_region region;
} djvutang_render_options;

typedef struct {
    uint32_t x, y, width, height, page_width, page_height, rotation;
    /* Unrotated page edges to output: (x,y) -> (a*x+c*y+e, b*x+d*y+f). */
    double matrix[6], inverse[6];
} djvutang_geometry;

typedef struct {
    const uint8_t *rgba;
    size_t size, stride;
    uint32_t width, height;
} djvutang_image;

typedef struct {
    size_t live_bytes, peak_bytes, cache_bytes;
} djvutang_memory;

/* Borrows immutable input until close. memory_limit=0 selects 64 MiB.
 * The limit covers decoder allocations, excluding input, the document handle
 * and returned metadata buffers. Core format/complexity limits also apply.
 * On failure, *out is NULL. IO stays with the caller. */
djvutang_status djvutang_open(const uint8_t *data, size_t size,
                             size_t memory_limit, djvutang_document **out);
/* A live job, even completed or cancelled, returns BUSY and keeps the document
 * open. Destroy the job first. NULL is accepted. */
djvutang_status djvutang_close(djvutang_document *document);
uint32_t djvutang_page_count(const djvutang_document *document);
djvutang_status djvutang_get_page_info(djvutang_document *document, uint32_t page,
                                      djvutang_page_info *out);
djvutang_status djvutang_get_geometry(djvutang_document *document, uint32_t page,
                                     const djvutang_render_options *options,
                                     djvutang_geometry *out);
djvutang_status djvutang_get_memory(const djvutang_document *document,
                                   djvutang_memory *out);
/* Evicts supplied components and shared dictionaries. Returns BUSY while a job
 * exists; does not free the borrowed input. limit=0 drops all idle cache. */
djvutang_status djvutang_trim_cache(djvutang_document *document, size_t limit);

/* One job per document. Start functions set *out to NULL on failure. */
djvutang_status djvutang_render_start(djvutang_document *document, uint32_t page,
                                     const djvutang_render_options *options,
                                     djvutang_job **out);
/* Decodes a stored thumbnail at its encoded size/orientation.
 * OK with *out=NULL means absent; does not render a replacement. */
djvutang_status djvutang_thumbnail_start(djvutang_document *document, uint32_t page,
                                        djvutang_job **out);
/* work > 0 counts operations, not time. Returns PROGRESS, OK when complete, or
 * an error. No partial pixels are exposed. A failed job must be destroyed. */
djvutang_status djvutang_render_step(djvutang_job *job, uint32_t work);
/* Reuses decoded layers after completion. Failure preserves existing pixels;
 * success invalidates them and requires stepping again. */
djvutang_status djvutang_render_restart(djvutang_job *job,
                                       const djvutang_render_options *options);
/* Borrowed, top-down RGBA8; valid until successful restart or job destruction. */
djvutang_status djvutang_render_image(const djvutang_job *job, djvutang_image *out);
/* Cancels unfinished work between steps. Does not free the job; completed
 * results are unaffected. Both functions accept NULL. */
void djvutang_render_cancel(djvutang_job *job);
void djvutang_render_destroy(djvutang_job *job);

enum {
    DJVUTANG_SCOPE_PAGE = 0,
    DJVUTANG_SCOPE_INCLUDES = 1,
    DJVUTANG_SCOPE_THUMBNAIL = 2
};

typedef struct {
    uint32_t index;
    const uint8_t *id;
    size_t id_size;
    const uint8_t *name;
    size_t name_size;
} djvutang_component;

/* For indirect documents and external INCL references. PAGE prepares info and
 * geometry; INCLUDES prepares rendering/text/annotations; THUMBNAIL prepares
 * stored thumbnails. OK with index=UINT32_MAX means ready. Otherwise load the
 * indicated component, supply it, and repeat. ID and suggested filename are
 * borrowed until document close and need not be NUL-terminated. The host decides
 * how to resolve them; an empty name can fall back to the ID. */
djvutang_status djvutang_next_missing(djvutang_document *document, uint32_t page,
                                     uint32_t scope, djvutang_component *out);
/* Copies an AT&T-prefixed component file; input is borrowed only for this call. */
djvutang_status djvutang_provide_component(djvutang_document *document,
                                          uint32_t index, const uint8_t *data,
                                          size_t size);

typedef struct {
    const uint8_t *data;
    size_t size;
} djvutang_buffer;

/* Owned UTF-8 snapshots, independent of the document and render job. data=NULL
 * means absent; a present empty value has non-NULL data and size=0. Data is not
 * NUL-terminated. Output is cleared on failure; free any previous result first.
 * Text replaces malformed UTF-8 with U+FFFD. JSON uses the CLI's metadata schema.
 * Metadata failures do not cancel rendering. */
djvutang_status djvutang_text(djvutang_document *document, uint32_t page,
                             djvutang_buffer *out);
djvutang_status djvutang_annotations_json(djvutang_document *document, uint32_t page,
                                         djvutang_buffer *out);
djvutang_status djvutang_outline_json(djvutang_document *document, djvutang_buffer *out);
/* Frees an owned metadata buffer and clears it. NULL/empty buffers are accepted. */
void djvutang_buffer_free(djvutang_buffer *buffer);

#ifdef __cplusplus
}
#endif
#endif
