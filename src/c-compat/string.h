/* Freestanding declarations; Zig supplies compiler-rt memory routines. */
#pragma once
#include <stddef.h>
void *memcpy(void *restrict dest, const void *restrict src, size_t size);
void *memset(void *dest, int value, size_t size);
