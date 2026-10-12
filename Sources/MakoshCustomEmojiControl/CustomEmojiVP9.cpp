#include "MakoshCustomEmojiVP9.h"
#include <CVPX.h>
#include <algorithm>
#include <cmath>
#include <cstring>
#include <memory>
#include <new>
#include <vector>

namespace {
constexpr size_t packetLimit = 8 * 1024 * 1024;
class VP9Context final {
public:
    vpx_codec_ctx_t codec{};
    bool ready = false;
    bool initialize(uint32_t width, uint32_t height) {
        vpx_codec_dec_cfg_t config{};
        config.threads = 1;
        config.w = width;
        config.h = height;
        ready = vpx_codec_dec_init(&codec, vpx_codec_vp9_dx(), &config, 0) == VPX_CODEC_OK;
        return ready && vpx_codec_control(&codec, VP9D_SET_ROW_MT, 0) == VPX_CODEC_OK;
    }
    ~VP9Context() { if (ready) vpx_codec_destroy(&codec); }
    VP9Context() = default;
    VP9Context(const VP9Context &) = delete;
    VP9Context &operator=(const VP9Context &) = delete;
};

bool validImage(const vpx_image_t &image, uint32_t width, uint32_t height) {
    if (image.fmt != VPX_IMG_FMT_I420 || image.bit_depth != 8 ||
        image.d_w != width || image.d_h != height || image.w < width || image.h < height ||
        image.x_chroma_shift != 1 || image.y_chroma_shift != 1) return false;
    for (int plane = 0; plane != 3; ++plane) {
        const size_t minimum = plane == 0 ? width : (width + 1) / 2;
        if (!image.planes[plane] || image.stride[plane] <= 0 ||
            static_cast<size_t>(image.stride[plane]) < minimum ||
            static_cast<size_t>(image.stride[plane]) > packetLimit) return false;
    }
    return true;
}

struct ColorMatrix { double red, blue; };
bool colorMatrix(vpx_color_space_t space, ColorMatrix &result) {
    switch (space) {
        case VPX_CS_UNKNOWN: case VPX_CS_BT_601: case VPX_CS_SMPTE_170:
            result = {0.299, 0.114}; return true;
        case VPX_CS_BT_709: result = {0.2126, 0.0722}; return true;
        case VPX_CS_SMPTE_240: result = {0.212, 0.087}; return true;
        case VPX_CS_BT_2020: result = {0.2627, 0.0593}; return true;
        default: return false;
    }
}
uint8_t channel(double value, uint8_t alpha) {
    const auto clipped = std::clamp<long>(std::lround(value), 0, 255);
    return static_cast<uint8_t>((clipped * alpha + 127) / 255);
}
bool convert(const vpx_image_t &image, const vpx_image_t *alpha, std::vector<uint8_t> &output) {
    ColorMatrix matrix{};
    if (!colorMatrix(image.cs, matrix) ||
        (image.range != VPX_CR_STUDIO_RANGE && image.range != VPX_CR_FULL_RANGE)) return false;
    const double green = 1 - matrix.red - matrix.blue;
    const double yScale = image.range == VPX_CR_STUDIO_RANGE ? 255.0 / 219 : 1;
    const double cScale = image.range == VPX_CR_STUDIO_RANGE ? 255.0 / 224 : 1;
    const double yOffset = image.range == VPX_CR_STUDIO_RANGE ? 16 : 0;
    for (uint32_t y = 0; y != image.d_h; ++y) {
        const uint8_t *ys = image.planes[0] + size_t(y) * image.stride[0];
        const uint8_t *us = image.planes[1] + size_t(y / 2) * image.stride[1];
        const uint8_t *vs = image.planes[2] + size_t(y / 2) * image.stride[2];
        const uint8_t *as = alpha ? alpha->planes[0] + size_t(y) * alpha->stride[0] : nullptr;
        for (uint32_t x = 0; x != image.d_w; ++x) {
            const double luminance = (double(ys[x]) - yOffset) * yScale;
            const double u = (double(us[x / 2]) - 128) * cScale;
            const double v = (double(vs[x / 2]) - 128) * cScale;
            const uint8_t a = as ? as[x] : 255;
            const size_t offset = (size_t(y) * image.d_w + x) * 4;
            output[offset] = channel(luminance + 2 * (1 - matrix.blue) * u, a);
            output[offset + 1] = channel(luminance - 2 * matrix.blue * (1 - matrix.blue) / green * u
                - 2 * matrix.red * (1 - matrix.red) / green * v, a);
            output[offset + 2] = channel(luminance + 2 * (1 - matrix.red) * v, a);
            output[offset + 3] = a;
        }
    }
    return true;
}
bool decodePacket(VP9Context &context, const uint8_t *bytes, size_t count, vpx_image_t *&image) {
    if (vpx_codec_decode(&context.codec, bytes, static_cast<unsigned int>(count), nullptr, 0) != VPX_CODEC_OK) return false;
    vpx_codec_iter_t iterator = nullptr;
    image = vpx_codec_get_frame(&context.codec, &iterator);
    return !image || vpx_codec_get_frame(&context.codec, &iterator) == nullptr;
}
}

struct MakoshEmojiVP9 {
    const uint32_t width, height;
    const bool hasAlpha;
    bool valid = true;
    VP9Context color, alpha;
    std::vector<uint8_t> surface;
    MakoshEmojiVP9(uint32_t width, uint32_t height, bool hasAlpha)
        : width(width), height(height), hasAlpha(hasAlpha), surface(size_t(width) * height * 4) {}
};

extern "C" MakoshEmojiVP9 *makosh_emoji_vp9_create(uint32_t width, uint32_t height, int32_t hasAlpha) {
    if (!width || !height || width > 512 || height > 512 || (hasAlpha != 0 && hasAlpha != 1)) return nullptr;
    try {
        auto result = std::make_unique<MakoshEmojiVP9>(width, height, hasAlpha == 1);
        if (!result->color.initialize(width, height) ||
            (result->hasAlpha && !result->alpha.initialize(width, height))) return nullptr;
        return result.release();
    } catch (...) { return nullptr; }
}
extern "C" void makosh_emoji_vp9_destroy(MakoshEmojiVP9 *decoder) { delete decoder; }
extern "C" int32_t makosh_emoji_vp9_decode(MakoshEmojiVP9 *decoder,
    const uint8_t *color, size_t colorCount, const uint8_t *alpha, size_t alphaCount,
    uint8_t *pixels, size_t stride, size_t capacity) {
    if (!decoder || !decoder->valid) return MAKOSH_EMOJI_VP9_FAILED;
    const size_t rowBytes = size_t(decoder->width) * 4;
    // Caller-buffer mistakes do not consume the packet or mutate codec state.
    if (!pixels || stride < rowBytes || capacity < rowBytes ||
        size_t(decoder->height - 1) > (capacity - rowBytes) / stride) return MAKOSH_EMOJI_VP9_FAILED;
    try {
        if (!color || !colorCount || colorCount > packetLimit ||
            (decoder->hasAlpha ? (!alpha || !alphaCount || alphaCount > packetLimit) : alphaCount != 0)) {
            decoder->valid = false; return MAKOSH_EMOJI_VP9_FAILED;
        }
        vpx_image_t *image = nullptr, *mask = nullptr;
        if (!decodePacket(decoder->color, color, colorCount, image) ||
            (decoder->hasAlpha && !decodePacket(decoder->alpha, alpha, alphaCount, mask)) ||
            (decoder->hasAlpha && (bool(image) != bool(mask)))) {
            decoder->valid = false; return MAKOSH_EMOJI_VP9_FAILED;
        }
        if (!image) return MAKOSH_EMOJI_VP9_NO_FRAME;
        if (!validImage(*image, decoder->width, decoder->height) ||
            (mask && !validImage(*mask, decoder->width, decoder->height)) ||
            !convert(*image, mask, decoder->surface)) {
            decoder->valid = false; return MAKOSH_EMOJI_VP9_FAILED;
        }
        for (uint32_t row = 0; row != decoder->height; ++row)
            std::memcpy(pixels + size_t(row) * stride, decoder->surface.data() + size_t(row) * rowBytes, rowBytes);
        return MAKOSH_EMOJI_VP9_FRAME;
    } catch (...) {
        decoder->valid = false; return MAKOSH_EMOJI_VP9_FAILED;
    }
}
