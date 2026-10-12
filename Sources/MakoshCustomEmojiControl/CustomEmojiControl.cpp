#include "MakoshCustomEmojiControl.h"
#include <CRLottie.h>
#include <cmath>
#include <cstring>
#include <memory>
#include <new>
#include <string>
#include <vector>

struct MakoshEmojiLottie {
    std::unique_ptr<rlottie::Animation> animation;
    size_t frame_count;
};

MakoshEmojiLottie *makosh_emoji_lottie_create(const uint8_t *json, size_t count,
                                            MakoshEmojiLottieInfo *info) {
    if (info) *info = {};
    if (!info || !json || count == 0 || count > 8 * 1024 * 1024 ||
        std::memchr(json, 0, count)) return nullptr;
    try {
        auto animation = rlottie::Animation::loadFromData(
            std::string(reinterpret_cast<const char *>(json), count), "", "", false);
        if (!animation) return nullptr;
        size_t width = 0, height = 0;
        animation->size(width, height);
        const size_t frames = animation->totalFrame();
        const double fps = animation->frameRate();
        if (width == 0 || height == 0 || width > 1536 || height > 1536 ||
            frames == 0 || frames > 3240 || !std::isfinite(fps) || fps <= 0 ||
            fps > 360 || static_cast<double>(frames) / fps > 9) return nullptr;
        auto owned = std::make_unique<MakoshEmojiLottie>();
        owned->frame_count = frames;
        owned->animation = std::move(animation);
        *info = {static_cast<uint32_t>(width), static_cast<uint32_t>(height),
                 static_cast<uint32_t>(frames), fps};
        return owned.release();
    } catch (...) {
        return nullptr;
    }
}

void makosh_emoji_lottie_destroy(MakoshEmojiLottie *animation) { delete animation; }

int32_t makosh_emoji_lottie_render(MakoshEmojiLottie *animation, uint32_t frame_index,
    uint32_t width, uint32_t height, uint8_t *pixels, size_t stride, size_t capacity) {
    if (!animation || !pixels || width == 0 || height == 0 || width > 512 || height > 512 ||
        frame_index >= animation->frame_count || stride < static_cast<size_t>(width) * 4 ||
        stride > capacity / height) return 1;
    try {
        // Native rendering owns a tight, aligned surface. Only a complete frame
        // reaches the caller; an exception cannot publish partial pixel writes.
        std::vector<uint32_t> frame(static_cast<size_t>(width) * height, 0);
        rlottie::Surface surface(frame.data(), width, height, static_cast<size_t>(width) * 4);
        animation->animation->renderSync(frame_index, surface, true);
        const size_t row_bytes = static_cast<size_t>(width) * 4;
        for (size_t row = 0; row < height; ++row) {
            std::memcpy(pixels + row * stride, frame.data() + row * width, row_bytes);
        }
        return 0;
    } catch (...) {
        return 2;
    }
}
