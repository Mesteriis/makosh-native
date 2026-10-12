#ifndef MAKOSH_CUSTOM_EMOJI_VP9_H
#define MAKOSH_CUSTOM_EMOJI_VP9_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct MakoshEmojiVP9 MakoshEmojiVP9;
enum {
    MAKOSH_EMOJI_VP9_FRAME = 0,
    MAKOSH_EMOJI_VP9_NO_FRAME = 1,
    MAKOSH_EMOJI_VP9_FAILED = -1
};
/* Fixed canvas, sequential color/optional alpha VP9 packets; input is borrowed.
   Caller owns the output. Only a complete premultiplied BGRA8 frame is copied.
   No-frame packets advance state without output; bitstream failures invalidate
   the decoder. Each packet is limited to 8 MiB. Destroy with the matching API. */
MakoshEmojiVP9 *makosh_emoji_vp9_create(uint32_t width, uint32_t height, int32_t has_alpha);
void makosh_emoji_vp9_destroy(MakoshEmojiVP9 *decoder);
int32_t makosh_emoji_vp9_decode(MakoshEmojiVP9 *decoder,
    const uint8_t *color, size_t color_count, const uint8_t *alpha, size_t alpha_count,
    uint8_t *pixels, size_t stride, size_t capacity);
#ifdef __cplusplus
}
#endif
#endif
