/* Fixture tool: upstream whole-image decoder with the right-edge filter fix. */
#define STBI_ONLY_JPEG
#define STBI_NO_SIMD
#define STBI_NO_LINEAR
#define STBI_NO_HDR
#define STB_IMAGE_IMPLEMENTATION
#include "stb_image.h"
#include <stdio.h>

int main(int argc, char **argv) {
    if (argc != 2) return 1;
    int width, height, components;
    unsigned char *rgb = stbi_load(argv[1], &width, &height, &components, 3);
    if (!rgb) return 2;
    printf("P6\n%d %d\n255\n", width, height);
    size_t count = (size_t)width * height * 3;
    int ok = fwrite(rgb, 1, count, stdout) == count;
    stbi_image_free(rgb);
    return ok ? 0 : 3;
}
