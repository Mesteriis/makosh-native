#ifndef MAKOSH_JPEG_CONTROL_H
#define MAKOSH_JPEG_CONTROL_H
#include <stddef.h>
#include <stdint.h>

/* Borrows RGBX pixels. On success caller owns *output and releases it with free().
   On failure returns 0, clears outputs, and never prints codec diagnostics. */
int makosh_jpeg_encode_rgbx75(const uint8_t *pixels, size_t count, uint32_t width,
                            uint32_t height, size_t stride, uint8_t **output, size_t *length);
#endif
