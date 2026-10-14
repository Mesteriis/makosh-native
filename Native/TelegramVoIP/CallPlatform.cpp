// SPDX-License-Identifier: MIT
#include "CallVideo.hpp"
#include "platform/PlatformInterface.h"
#include "VideoCapturerInterface.h"
#include "VideoCaptureInterface.h"
#include "api/video_codecs/video_encoder_factory_template.h"
#include "api/video_codecs/video_decoder_factory_template.h"
#include "api/video_codecs/video_encoder_factory_template_libvpx_vp8_adapter.h"
#include "api/video_codecs/video_decoder_factory_template_libvpx_vp8_adapter.h"
#include "api/make_ref_counted.h"
namespace makosh {
class CallCapturer final : public tgcalls::VideoCapturerInterface {
    std::shared_ptr<CallVideoContext> context;
    std::function<void(tgcalls::VideoState)> updated;
    tgcalls::VideoState state = tgcalls::VideoState::Inactive;
public:
    CallCapturer(std::shared_ptr<CallVideoContext> context, std::function<void(tgcalls::VideoState)> updated)
        : context(std::move(context)), updated(std::move(updated)) {}
    ~CallCapturer() override { context->setActive(false); }
    void setState(tgcalls::VideoState value) override {
        context->setActive(value == tgcalls::VideoState::Active);
        if (state != value) { state = value; updated(value); }
    }
    void setPreferredCaptureAspectRatio(float) override {}
    void setUncroppedOutput(std::shared_ptr<rtc::VideoSinkInterface<webrtc::VideoFrame>>) override {}
    int getRotation() override { return 0; }
};
class CallPlatform final : public tgcalls::PlatformInterface {
public:
    std::unique_ptr<webrtc::VideoEncoderFactory> makeVideoEncoderFactory(bool, bool) override {
        return std::make_unique<webrtc::VideoEncoderFactoryTemplate<webrtc::LibvpxVp8EncoderTemplateAdapter>>();
    }
    std::unique_ptr<webrtc::VideoDecoderFactory> makeVideoDecoderFactory() override {
        return std::make_unique<webrtc::VideoDecoderFactoryTemplate<webrtc::LibvpxVp8DecoderTemplateAdapter>>();
    }
    bool supportsEncoding(const std::string &codec) override { return codec == "VP8"; }
    webrtc::scoped_refptr<webrtc::VideoTrackSourceInterface> makeVideoSource(rtc::Thread *, rtc::Thread *) override {
        return rtc::make_ref_counted<CallVideoSource>();
    }
    void adaptVideoSource(webrtc::scoped_refptr<webrtc::VideoTrackSourceInterface>, int, int, int) override {}
    std::unique_ptr<tgcalls::VideoCapturerInterface> makeVideoCapturer(
        webrtc::scoped_refptr<webrtc::VideoTrackSourceInterface> source, std::string,
        std::function<void(tgcalls::VideoState)> updated, std::function<void(tgcalls::PlatformCaptureInfo)> captureUpdated,
        std::shared_ptr<tgcalls::PlatformContext> platformContext, std::pair<int, int> &resolution) override {
        auto context = std::dynamic_pointer_cast<CallVideoContext>(platformContext);
        if (!context) return nullptr;
        context->attach(webrtc::scoped_refptr<CallVideoSource>(static_cast<CallVideoSource *>(source.get())));
        resolution = {640, 480}; captureUpdated({false, 0});
        return std::make_unique<CallCapturer>(std::move(context), std::move(updated));
    }
};
}
namespace tgcalls {
std::unique_ptr<PlatformInterface> CreatePlatformInterface() { return std::make_unique<makosh::CallPlatform>(); }
}
