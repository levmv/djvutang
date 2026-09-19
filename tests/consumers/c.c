#include <djvutang.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define CHECK(condition) do { \
    if (!(condition)) { fprintf(stderr, "line %d: %s\n", __LINE__, #condition); exit(1); } \
} while (0)
#define STATUS(call, expected) do { \
    djvutang_status actual = (call); \
    if (actual != (expected)) { \
        fprintf(stderr, "line %d: %s returned %d, expected %d\n", __LINE__, #call, (int)actual, (int)(expected)); \
        exit(1); \
    } \
} while (0)

typedef struct { uint8_t *data; size_t size; } bytes;
static const char *fixtures;

static bytes load(const char *name) {
    char path[1024];
    int n = snprintf(path, sizeof(path), "%s/%s", fixtures, name);
    CHECK(n > 0 && (size_t)n < sizeof(path));
    FILE *file = fopen(path, "rb");
    CHECK(file != NULL && fseek(file, 0, SEEK_END) == 0);
    long size = ftell(file);
    CHECK(size > 0 && fseek(file, 0, SEEK_SET) == 0);
    bytes result = {malloc((size_t)size + 1), (size_t)size};
    CHECK(result.data != NULL && fread(result.data, 1, result.size, file) == result.size);
    result.data[result.size] = 0;
    CHECK(fclose(file) == 0);
    return result;
}

static djvutang_document *open_document(bytes input) {
    djvutang_document *doc = NULL;
    STATUS(djvutang_open(input.data, input.size, 0, &doc), DJVUTANG_OK);
    CHECK(doc != NULL);
    return doc;
}

static void finish(djvutang_job *job) {
    djvutang_status status;
    size_t steps = 0;
    do {
        status = djvutang_render_step(job, 256);
        CHECK(++steps < 100000);
    } while (status == DJVUTANG_PROGRESS);
    CHECK(status == DJVUTANG_OK);
}

static void check_image(djvutang_job *job, const char *reference) {
    bytes ppm = load(reference);
    unsigned width, height;
    int offset = 0;
    CHECK(sscanf((const char *)ppm.data, "P6\n%u %u\n255%n", &width, &height, &offset) == 2);
    CHECK(offset > 0 && ppm.data[offset++] == '\n');
    djvutang_image image;
    STATUS(djvutang_render_image(job, &image), DJVUTANG_OK);
    CHECK(image.width == width && image.height == height && image.stride == width * 4);
    CHECK(image.size == (size_t)width * height * 4 && ppm.size - (size_t)offset == image.size / 4 * 3);
    for (size_t i = 0; i < image.size / 4; ++i) {
        CHECK(memcmp(image.rgba + 4 * i, ppm.data + offset + 3 * i, 3) == 0);
        CHECK(image.rgba[4 * i + 3] == 255);
    }
    free(ppm.data);
}

static void render_lifetimes(void) {
    bytes color = load("color.djvu"), tiny = load("tiny.djvu");
    djvutang_document *a = open_document(color), *b = open_document(tiny);
    djvutang_memory baseline, memory;
    STATUS(djvutang_get_memory(a, &baseline), DJVUTANG_OK);
    djvutang_page_info info;
    CHECK(djvutang_page_count(a) == 1);
    STATUS(djvutang_get_page_info(a, 0, &info), DJVUTANG_OK);
    CHECK(info.width > 16 && info.height > 16 && info.dpi > 0 && info.rotation == 0);
    STATUS(djvutang_get_page_info(a, UINT32_MAX, &info), DJVUTANG_INVALID_ARGUMENT);

    djvutang_job *ja = NULL, *jb = NULL, *extra = NULL;
    STATUS(djvutang_render_start(a, 0, NULL, &ja), DJVUTANG_OK);
    STATUS(djvutang_render_start(b, 0, NULL, &jb), DJVUTANG_OK);
    STATUS(djvutang_render_step(ja, 0), DJVUTANG_INVALID_ARGUMENT);
    STATUS(djvutang_render_step(ja, 1), DJVUTANG_PROGRESS);
    STATUS(djvutang_render_step(jb, 1), DJVUTANG_PROGRESS);
    STATUS(djvutang_render_start(a, 0, NULL, &extra), DJVUTANG_BUSY);
    CHECK(extra == NULL);
    STATUS(djvutang_close(a), DJVUTANG_BUSY);
    STATUS(djvutang_trim_cache(a, 0), DJVUTANG_BUSY);
    djvutang_image image;
    STATUS(djvutang_render_image(ja, &image), DJVUTANG_BUSY);
    finish(jb);
    finish(ja);
    check_image(ja, "color-expected.ppm");
    check_image(jb, "tiny-expected.ppm");
    STATUS(djvutang_close(a), DJVUTANG_BUSY);
    djvutang_render_destroy(jb);
    STATUS(djvutang_close(b), DJVUTANG_OK);
    free(tiny.data);

    STATUS(djvutang_render_image(ja, &image), DJVUTANG_OK);
    bytes full = {malloc(image.size), image.size};
    CHECK(full.data != NULL);
    memcpy(full.data, image.rgba, full.size);
    djvutang_render_options options = {0};
    options.rotation = 4;
    STATUS(djvutang_render_restart(ja, &options), DJVUTANG_INVALID_ARGUMENT);
    djvutang_image retained;
    STATUS(djvutang_render_image(ja, &retained), DJVUTANG_OK);
    CHECK(retained.rgba == image.rgba && memcmp(retained.rgba, full.data, full.size) == 0);
    options.rotation = 1;
    options.region = (djvutang_region){3, 5, 7, 11};
    djvutang_geometry geometry;
    STATUS(djvutang_get_geometry(a, 0, &options, &geometry), DJVUTANG_OK);
    CHECK(geometry.width == 7 && geometry.height == 11 && geometry.rotation == 1);
    CHECK(geometry.page_width == info.height && geometry.page_height == info.width);
    CHECK(geometry.matrix[4] == -3 && geometry.matrix[5] == info.width - 5);
    CHECK(geometry.inverse[0] == 0 && geometry.inverse[1] == 1);
    STATUS(djvutang_render_restart(ja, &options), DJVUTANG_OK);
    finish(ja);
    STATUS(djvutang_render_image(ja, &image), DJVUTANG_OK);
    for (uint32_t y = 0; y < image.height; ++y)
        for (uint32_t x = 0; x < image.width; ++x) {
            size_t source = ((size_t)(x + 3) * info.width + info.width - 1 - (y + 5)) * 4;
            CHECK(memcmp(image.rgba + y * image.stride + x * 4, full.data + source, 4) == 0);
        }
    free(full.data);

    options = (djvutang_render_options){0};
    options.width = 19;
    options.height = 23;
    STATUS(djvutang_get_geometry(a, 0, &options, &geometry), DJVUTANG_OK);
    CHECK(geometry.width <= 19 && geometry.height <= 23);
    STATUS(djvutang_render_restart(ja, &options), DJVUTANG_OK);
    finish(ja);
    STATUS(djvutang_render_image(ja, &image), DJVUTANG_OK);
    CHECK(image.width == geometry.width && image.height == geometry.height);
    STATUS(djvutang_render_restart(ja, NULL), DJVUTANG_OK);
    djvutang_render_cancel(ja);
    STATUS(djvutang_render_step(ja, 1), DJVUTANG_CANCELLED);
    STATUS(djvutang_render_image(ja, &image), DJVUTANG_CANCELLED);
    djvutang_render_destroy(ja);
    STATUS(djvutang_trim_cache(a, 0), DJVUTANG_OK);
    STATUS(djvutang_get_memory(a, &memory), DJVUTANG_OK);
    CHECK(memory.live_bytes == baseline.live_bytes && memory.peak_bytes > memory.live_bytes);
    STATUS(djvutang_thumbnail_start(a, 0, &extra), DJVUTANG_OK);
    CHECK(extra == NULL);
    STATUS(djvutang_close(a), DJVUTANG_OK);
    free(color.data);
}

static void metadata(void) {
    bytes input = load("text-z.djvu"), raw = load("text.raw");
    djvutang_document *doc = open_document(input);
    djvutang_buffer text = {0}, annotations = {0}, outline = {0};
    STATUS(djvutang_text(doc, 0, &text), DJVUTANG_OK);
    STATUS(djvutang_annotations_json(doc, 0, &annotations), DJVUTANG_OK);
    STATUS(djvutang_outline_json(doc, &outline), DJVUTANG_OK);
    CHECK(annotations.data == NULL && outline.data == NULL);
    STATUS(djvutang_close(doc), DJVUTANG_OK);
    free(input.data);
    size_t length = ((size_t)raw.data[0] << 16) | ((size_t)raw.data[1] << 8) | raw.data[2];
    CHECK(text.size == length && memcmp(text.data, raw.data + 3, length) == 0);
    djvutang_buffer_free(&text);
    CHECK(text.data == NULL && text.size == 0);
    djvutang_buffer_free(&text);
    free(raw.data);

    input = load("text-empty.djvu");
    doc = open_document(input);
    STATUS(djvutang_text(doc, 0, &text), DJVUTANG_OK);
    CHECK(text.data != NULL && text.size == 0);
    STATUS(djvutang_close(doc), DJVUTANG_OK);
    djvutang_buffer_free(&text);
    free(input.data);

    input = load("annotations-a.djvu");
    doc = open_document(input);
    STATUS(djvutang_annotations_json(doc, 0, &annotations), DJVUTANG_OK);
    STATUS(djvutang_close(doc), DJVUTANG_OK);
    free(input.data);
    CHECK(annotations.size > 2 && annotations.data[0] == '{' && annotations.data[annotations.size - 1] == '}');
    djvutang_buffer_free(&annotations);

    input = load("outline.djvu");
    doc = open_document(input);
    STATUS(djvutang_outline_json(doc, &outline), DJVUTANG_OK);
    STATUS(djvutang_close(doc), DJVUTANG_OK);
    free(input.data);
    CHECK(outline.size > 2 && outline.data[0] == '{' && outline.data[outline.size - 1] == '}');
    djvutang_buffer_free(&outline);

    input = load("bad-text.djvu");
    doc = open_document(input);
    djvutang_job *job = NULL;
    STATUS(djvutang_render_start(doc, 0, NULL, &job), DJVUTANG_OK);
    STATUS(djvutang_render_step(job, 1), DJVUTANG_PROGRESS);
    STATUS(djvutang_text(doc, 0, &text), DJVUTANG_INVALID_DATA);
    CHECK(text.data == NULL && text.size == 0);
    finish(job);
    djvutang_render_destroy(job);
    STATUS(djvutang_close(doc), DJVUTANG_OK);
    free(input.data);

    input = load("metadata-indirect/index.djvu");
    doc = open_document(input);
    djvutang_metadata_scan *scan = NULL, *second = NULL;
    STATUS(djvutang_metadata_start(doc, &scan), DJVUTANG_OK);
    STATUS(djvutang_metadata_start(doc, &second), DJVUTANG_BUSY);
    CHECK(second == NULL);
    STATUS(djvutang_close(doc), DJVUTANG_BUSY);
    djvutang_metadata_cancel(scan);
    STATUS(djvutang_metadata_step(scan, 1), DJVUTANG_CANCELLED);
    djvutang_metadata_destroy(scan);
    STATUS(djvutang_metadata_start(doc, &scan), DJVUTANG_OK);
    for (;;) {
        djvutang_status state = djvutang_metadata_step(scan, 7);
        if (state == DJVUTANG_OK) break;
        CHECK(state == DJVUTANG_PROGRESS);
        djvutang_metadata_request request;
        STATUS(djvutang_metadata_range(scan, &request), DJVUTANG_OK);
        if (!request.length) continue;
        djvutang_component component;
        STATUS(djvutang_get_component(doc, request.component, &component), DJVUTANG_OK);
        char name[256];
        CHECK(component.name_size < 200);
        snprintf(name, sizeof(name), "metadata-indirect/%.*s", (int)component.name_size, (const char *)component.name);
        bytes file = load(name);
        CHECK((size_t)request.offset + request.length <= file.size);
        STATUS(djvutang_metadata_provide(scan, file.data + request.offset, request.length, (uint32_t)file.size), DJVUTANG_OK);
        free(file.data);
    }
    djvutang_metadata_cancel(scan); /* A completed result survives late cancellation. */
    STATUS(djvutang_metadata_json(scan, &annotations), DJVUTANG_OK);
    djvutang_metadata_destroy(scan);
    STATUS(djvutang_close(doc), DJVUTANG_OK);
    free(input.data);
    CHECK(annotations.size > 100 && memcmp(annotations.data, "{\"metadata\":", 12) == 0);
    djvutang_buffer_free(&annotations);
}

static void components_and_thumbnails(void) {
    bytes input = load("indirect-layers/index.djvu");
    djvutang_document *doc = open_document(input);
    djvutang_page_info info;
    STATUS(djvutang_get_page_info(doc, 0, &info), DJVUTANG_MISSING_COMPONENT);
    for (unsigned pass = 0; pass < 2; ++pass) {
        size_t loaded = 0;
        for (;;) {
            djvutang_component component;
            STATUS(djvutang_next_missing(doc, 0, DJVUTANG_SCOPE_INCLUDES, &component), DJVUTANG_OK);
            if (component.index == UINT32_MAX) break;
            CHECK(++loaded <= 6 && component.id_size != 0 && component.name_size != 0);
            char name[256];
            int n = snprintf(name, sizeof(name), "indirect-layers/%.*s", (int)component.name_size, (const char *)component.name);
            CHECK(n > 0 && (size_t)n < sizeof(name));
            bytes part = load(name);
            STATUS(djvutang_provide_component(doc, component.index, part.data, 4), DJVUTANG_INVALID_DATA);
            STATUS(djvutang_provide_component(doc, component.index, part.data, part.size), DJVUTANG_OK);
            memset(part.data, 0, part.size);
            free(part.data);
        }
        CHECK(loaded == 6);
        djvutang_job *job = NULL;
        STATUS(djvutang_render_start(doc, 0, NULL, &job), DJVUTANG_OK);
        finish(job);
        check_image(job, "jpeg-foreground-reference.ppm");
        djvutang_render_destroy(job);
        STATUS(djvutang_trim_cache(doc, 0), DJVUTANG_OK);
    }
    STATUS(djvutang_close(doc), DJVUTANG_OK);
    free(input.data);

    input = load("thumbnail-inline.djvu");
    doc = open_document(input);
    djvutang_job *job = NULL;
    STATUS(djvutang_thumbnail_start(doc, 0, &job), DJVUTANG_OK);
    CHECK(job != NULL);
    finish(job);
    check_image(job, "thumbnail-color-expected.ppm");
    djvutang_render_destroy(job);
    STATUS(djvutang_close(doc), DJVUTANG_OK);
    free(input.data);
}

static void errors_and_limits(void) {
    djvutang_document *doc = NULL;
    STATUS(djvutang_open(NULL, 0, 0, &doc), DJVUTANG_INVALID_ARGUMENT);
    CHECK(doc == NULL);
    STATUS(djvutang_open((const uint8_t *)"bad!", 4, 0, &doc), DJVUTANG_INVALID_DATA);
    bytes input = load("color.djvu");
    STATUS(djvutang_open(input.data, input.size, 1, &doc), DJVUTANG_LIMIT_EXCEEDED);
    CHECK(doc == NULL);
    STATUS(djvutang_open(input.data, input.size, 12 * 1024, &doc), DJVUTANG_OK);
    djvutang_job *job = NULL;
    STATUS(djvutang_render_start(doc, 0, NULL, &job), DJVUTANG_OK);
    djvutang_status status;
    do { status = djvutang_render_step(job, 4096); } while (status == DJVUTANG_PROGRESS);
    CHECK(status == DJVUTANG_LIMIT_EXCEEDED);
    djvutang_buffer text;
    STATUS(djvutang_text(doc, 0, &text), DJVUTANG_OK);
    CHECK(text.data == NULL);
    STATUS(djvutang_render_step(job, 1), DJVUTANG_LIMIT_EXCEEDED);
    djvutang_render_destroy(job);
    STATUS(djvutang_close(doc), DJVUTANG_OK);
    free(input.data);
    STATUS(djvutang_close(NULL), DJVUTANG_OK);
    djvutang_render_cancel(NULL);
    djvutang_render_destroy(NULL);
    djvutang_buffer_free(NULL);
}

int main(int argc, char **argv) {
    CHECK(argc == 2);
    fixtures = argv[1];
    render_lifetimes();
    metadata();
    components_and_thumbnails();
    errors_and_limits();
    puts("C API: rendering, ownership, metadata, components and limits.");
    return 0;
}
