// SPDX-License-Identifier: MIT
#pragma once
#include "PlatformContext.h"
#include "media/base/adapted_video_track_source.h"
#include "api/video/i420_buffer.h"
#include <CoreVideo/CoreVideo.h>
#include "api/video/video_frame.h"
#include "libyuv/convert_from.h"
#include <climits>
#include <atomic>
#include <mutex>
namespace makosh {
// Owned NV12 result. Apply the negotiated frame rotation before presenting it.
inline CVPixelBufferRef callVideoOutput(const webrtc::VideoFrame &frame) {
    const int w = frame.width(), h = frame.height();
    if (w < 2 || h < 2 || w > 1920 || h > 1920 || w * h > 1920 * 1080 || (w & 1) || (h & 1) || !frame.video_frame_buffer()) return nullptr;
    const auto rotation = frame.rotation();
    if (rotation != webrtc::kVideoRotation_0 && rotation != webrtc::kVideoRotation_90 && rotation != webrtc::kVideoRotation_180 && rotation != webrtc::kVideoRotation_270) return nullptr;
    auto buffer = frame.video_frame_buffer()->ToI420();
    if (!buffer || buffer->width() != w || buffer->height() != h) return nullptr;
    if (rotation != webrtc::kVideoRotation_0) buffer = webrtc::I420Buffer::Rotate(*buffer, rotation);
    CVPixelBufferRef output = nullptr;
    if (CVPixelBufferCreate(kCFAllocatorDefault, buffer->width(), buffer->height(), kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nullptr, &output) != kCVReturnSuccess) return nullptr;
    if (CVPixelBufferLockBaseAddress(output, 0) != kCVReturnSuccess) { CVPixelBufferRelease(output); return nullptr; }
    const auto yStride = CVPixelBufferGetBytesPerRowOfPlane(output, 0), uvStride = CVPixelBufferGetBytesPerRowOfPlane(output, 1);
    int result = -1;
    if (yStride >= buffer->width() && uvStride >= buffer->width() && yStride <= INT_MAX && uvStride <= INT_MAX) {
        result = libyuv::I420ToNV12(buffer->DataY(), buffer->StrideY(), buffer->DataU(), buffer->StrideU(), buffer->DataV(), buffer->StrideV(),
            static_cast<uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(output, 0)), int(yStride),
            static_cast<uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(output, 1)), int(uvStride), buffer->width(), buffer->height());
    }
    CVPixelBufferUnlockBaseAddress(output, 0);
    if (result != 0) { CVPixelBufferRelease(output); return nullptr; }
    return output;
}

class CallVideoSource : public rtc::AdaptedVideoTrackSource {
public:
    SourceState state() const override { return kLive; }
    bool remote() const override { return false; }
    bool is_screencast() const override { return false; }
    absl::optional<bool> needs_denoising() const override { return false; }
    void push(const webrtc::VideoFrame &frame) { OnFrame(frame); }
};
class CallVideoContext final : public tgcalls::PlatformContext {
    std::mutex mutex;
    webrtc::scoped_refptr<CallVideoSource> source;
    bool active = false, closed = false;
public:
    void attach(webrtc::scoped_refptr<CallVideoSource> value) { std::lock_guard lock(mutex); if (!closed) source = value; }
    void setActive(bool value) { std::lock_guard lock(mutex); active = value; }
    void close() { std::lock_guard lock(mutex); closed = true; active = false; source = nullptr; }
    void push(const webrtc::VideoFrame &frame) {
        std::lock_guard lock(mutex);
        if (!closed && active && source) source->push(frame);
    }
};
}
