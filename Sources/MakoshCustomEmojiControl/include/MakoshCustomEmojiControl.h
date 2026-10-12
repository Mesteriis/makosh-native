#ifndef MAKOSH_CUSTOM_EMOJI_CONTROL_H
#define MAKOSH_CUSTOM_EMOJI_CONTROL_H
#include <stddef.h>
#include <stdint.h>
#include "MakoshCustomEmojiVP9.h"
#ifdef __cplusplus
extern "C" {
#endif
typedef struct MakoshEmojiLottie MakoshEmojiLottie;
typedef struct {
    uint32_t width;
    uint32_t height;
    uint32_t frame_count;
    double frame_rate;
} MakoshEmojiLottieInfo;
/* Own fixed C boundary. Input JSON is copied; output buffers remain caller-owned.
   Rendered pixels are premultiplied BGRA8 on the supported little-endian host. */
MakoshEmojiLottie *makosh_emoji_lottie_create(const uint8_t *json, size_t count, MakoshEmojiLottieInfo *info);
void makosh_emoji_lottie_destroy(MakoshEmojiLottie *animation);
int32_t makosh_emoji_lottie_render(MakoshEmojiLottie *animation, uint32_t frame_index,
    uint32_t width, uint32_t height, uint8_t *pixels, size_t stride, size_t capacity);
#ifdef __cplusplus
}
#endif
#endif
