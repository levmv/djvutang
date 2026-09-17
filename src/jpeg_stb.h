#ifndef DJVU_JPEG_STB_H
#define DJVU_JPEG_STB_H
#include <stddef.h>
#include <stdint.h>
typedef void *(*djvu_jpeg_alloc)(void *user, size_t size);
typedef void (*djvu_jpeg_free)(void *user, void *ptr, size_t size);
typedef struct { size_t pixels, markers, scans, blocks; } djvu_jpeg_limits;
typedef struct { uint32_t width, height; } djvu_jpeg_info;
/* Status: 0 done, 1 progress, 2 invalid, 3 unsupported, 4 limit, 5 allocation. */
size_t djvu_jpeg_size(void);
int djvu_jpeg_init(void *state, const unsigned char *data, size_t size, void *user,
                   djvu_jpeg_alloc alloc, djvu_jpeg_free release,
                   djvu_jpeg_limits limits, djvu_jpeg_info *info);
int djvu_jpeg_step(void *state, size_t work, unsigned char *rgb);
void djvu_jpeg_deinit(void *state);
#endif
