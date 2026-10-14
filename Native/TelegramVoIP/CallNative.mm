// SPDX-License-Identifier: MIT
#include "CallNative.hpp"
#include "CallAdmission.hpp"
#include "CallVideo.hpp"
#include "CallAudio.hpp"
#include "Instance.h"
#include "InstanceImpl.h"
#include "StaticThreads.h"
#include "VideoCaptureInterface.h"
#include "platform/PlatformInterface.h"
#include "api/make_ref_counted.h"
#include "rtc_base/ssl_adapter.h"
#include "rtc_base/time_utils.h"
#include "libyuv/convert.h"
#include "libyuv/convert_from.h"
#include <dispatch/dispatch.h>
#include <openssl/crypto.h>
#include <atomic>
#include <array>
#include <mutex>

namespace makosh {
class CallBackend;
class CallBackend final : public std::enable_shared_from_this<CallBackend> {
    class VideoSink final : public rtc::VideoSinkInterface<webrtc::VideoFrame> {
        std::weak_ptr<CallBackend> backend;
    public:
        explicit VideoSink(std::weak_ptr<CallBackend> backend) : backend(std::move(backend)) {}
        void OnFrame(const webrtc::VideoFrame &frame) override {
            if (const auto strong = backend.lock()) strong->receiveFrame(frame);
        }
    };
    MKCallCallbacks callbacks;
    std::recursive_mutex callbackMutex;
    std::atomic<bool> closing{false}, released{false};
    std::unique_ptr<tgcalls::Instance> instance;
    std::shared_ptr<tgcalls::VideoCaptureInterface> capture;
    std::shared_ptr<CallVideoContext> video = std::make_shared<CallVideoContext>();
    std::shared_ptr<VideoSink> sink;
    dispatch_queue_t control = dispatch_queue_create("org.makosh.telegram-call-release", DISPATCH_QUEUE_SERIAL);
    template <typename F> void emit(F &&f) {
        std::lock_guard lock(callbackMutex);
        if (!closing) f(callbacks);
    }
    void mediaReleased() {
        std::lock_guard lock(callbackMutex);
        if (closing && !released.exchange(true)) callbacks.released(callbacks.context);
    }
    void receiveFrame(const webrtc::VideoFrame &frame) {
        if (closing) return;
        auto output = callVideoOutput(frame);
        if (!output) return;
        emit([&](const auto &cb) { if (cb.video_frame) cb.video_frame(cb.context, output); });
        CVPixelBufferRelease(output);
    }
public:
    explicit CallBackend(MKCallCallbacks callbacks) : callbacks(callbacks) {}
    bool initialize(const MKCallConfig &config, AudioFactory factory) {
        static std::once_flag initialized;
        std::call_once(initialized, [] { rtc::InitializeSSL(); tgcalls::Register<tgcalls::InstanceImpl>(); });
        auto key = std::shared_ptr<const std::array<uint8_t, 256>>(new std::array<uint8_t, 256>, [](const auto *value) {
            OPENSSL_cleanse(const_cast<std::array<uint8_t, 256> *>(value), sizeof(*value)); delete value;
        });
        std::memcpy(const_cast<uint8_t *>(key->data()), config.key, 256);
        tgcalls::Descriptor descriptor{.encryptionKey = {key, bool(config.outgoing)}};
        descriptor.version = config.version;
        descriptor.config.initializationTimeout = 30; descriptor.config.receiveTimeout = 20;
        descriptor.config.maxApiLayer = config.max_layer; descriptor.config.enableP2P = config.allow_p2p;
        descriptor.config.allowTCP = config.allow_tcp; descriptor.config.enableAEC = true;
        descriptor.config.enableNS = true; descriptor.config.enableAGC = true;
        descriptor.config.preferredVideoCodecs = {"VP8"};
        descriptor.initialNetworkType = tgcalls::NetworkType::Unknown;
        for (size_t i = 0; i < config.server_count; ++i) {
            const auto &value = config.servers[i];
            descriptor.rtcServers.push_back({value.id, value.host, value.port, value.username, value.password, bool(value.turn), bool(value.tcp)});
        }
        if (config.use_proxy) descriptor.proxy = std::make_unique<tgcalls::Proxy>(tgcalls::Proxy{
            config.proxy_host, config.proxy_port, config.proxy_username, config.proxy_password});
        const std::weak_ptr<CallBackend> weak = shared_from_this();
        descriptor.stateUpdated = [weak](tgcalls::State state) {
            if (const auto self = weak.lock()) self->emit([&](const auto &cb) {
                const int value = state == tgcalls::State::Established ? 2 : state == tgcalls::State::Reconnecting ? 3 : state == tgcalls::State::Failed ? 0 : 1;
                cb.state(cb.context, value);
            });
        };
        descriptor.signalingDataEmitted = [weak](const auto &data) {
            if (data.empty() || data.size() > 65536) return;
            if (const auto self = weak.lock()) self->emit([&](const auto &cb) { cb.signaling(cb.context, data.data(), data.size()); });
        };
        descriptor.remoteMediaStateUpdated = [weak](tgcalls::AudioState, tgcalls::VideoState state) {
            if (const auto self = weak.lock()) self->emit([&](const auto &cb) { if (cb.remote_video) cb.remote_video(cb.context, state == tgcalls::VideoState::Active); });
        };
        const CallAudioDevices devices = config.abi_version == 2 ? CallAudioDevices{config.audio_input_uid, config.audio_output_uid} : CallAudioDevices{};
        descriptor.createAudioDeviceModule = [weak, factory = std::move(factory), devices](webrtc::TaskQueueFactory *queue) {
            return prepareCallAudio(factory, queue, [weak] {
                if (const auto self = weak.lock()) self->emit([](const auto &cb) { cb.state(cb.context, 0); });
            }, [weak] { if (const auto self = weak.lock()) self->mediaReleased(); }, devices);
        };
        // Create a source even for audio calls, so later camera activation never renegotiates the device boundary.
        capture = tgcalls::VideoCaptureInterface::Create(tgcalls::StaticThreads::getThreads(), "external", false, video);
        capture->setState(config.video ? tgcalls::VideoState::Active : tgcalls::VideoState::Inactive);
        if (config.video) descriptor.videoCapture = capture;
        instance = tgcalls::Meta::Create(config.version, std::move(descriptor));
        if (!instance) return false;
        sink = std::make_shared<VideoSink>(weak); instance->setIncomingVideoOutput(sink); return true;
    }
    bool receive(const uint8_t *bytes, size_t size) {
        if (closing || !bytes || !size || size > 65536) return false;
        instance->receiveSignalingData(std::vector<uint8_t>(bytes, bytes + size)); return true;
    }
    bool setMuted(int value) {
        if (closing || (value != 0 && value != 1)) return false;
        instance->setMuteMicrophone(value); return true;
    }
    bool setVideo(int value) {
        if (closing || (value != 0 && value != 1)) return false;
        capture->setState(value ? tgcalls::VideoState::Active : tgcalls::VideoState::Inactive);
        instance->setVideoCapture(value ? capture : nullptr); return true;
    }
    bool pushVideo(CVPixelBufferRef input) {
        if (closing || !input) return false;
        const size_t width = CVPixelBufferGetWidth(input), height = CVPixelBufferGetHeight(input);
        const auto format = CVPixelBufferGetPixelFormatType(input);
        if (width < 2 || height < 2 || width > 1920 || height > 1920 || width * height > 1920 * 1080 || (width & 1) || (height & 1) ||
            (format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange && format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) ||
            CVPixelBufferGetPlaneCount(input) != 2) return false;
        if (CVPixelBufferGetBytesPerRowOfPlane(input, 0) < width || CVPixelBufferGetBytesPerRowOfPlane(input, 1) < width ||
            CVPixelBufferGetBytesPerRowOfPlane(input, 0) > INT_MAX || CVPixelBufferGetBytesPerRowOfPlane(input, 1) > INT_MAX) return false;
        if (CVPixelBufferLockBaseAddress(input, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) return false;
        auto output = webrtc::I420Buffer::Create(int(width), int(height));
        const int result = libyuv::NV12ToI420(static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(input, 0)),
            int(CVPixelBufferGetBytesPerRowOfPlane(input, 0)), static_cast<const uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(input, 1)),
            int(CVPixelBufferGetBytesPerRowOfPlane(input, 1)), output->MutableDataY(), output->StrideY(), output->MutableDataU(),
            output->StrideU(), output->MutableDataV(), output->StrideV(), int(width), int(height));
        CVPixelBufferUnlockBaseAddress(input, kCVPixelBufferLock_ReadOnly);
        if (result != 0) return false;
        video->push(webrtc::VideoFrame::Builder().set_video_frame_buffer(output).set_timestamp_us(rtc::TimeMicros())
            .set_rotation(webrtc::kVideoRotation_0).build()); return true;
    }
    void stop() {
        { std::lock_guard lock(callbackMutex); if (closing.exchange(true)) return; }
        video->close(); sink.reset();
        const auto self = shared_from_this();
        instance->stop([self](tgcalls::FinalState) {
            dispatch_async(self->control, ^{ self->instance.reset(); self->capture.reset(); });
        });
    }
    bool isReleased() const { return released; }
};
}
struct MKCall { std::shared_ptr<makosh::CallBackend> backend; };
namespace makosh {
MKCall *createCall(const MKCallConfig &config, const MKCallCallbacks &callbacks, AudioFactory factory) noexcept {
    if (!validateCall(config) || !callbacks.state || !callbacks.signaling || !callbacks.released || !factory) return nullptr;
    // Allocate the public owner before starting native tasks. Unexpected native
    // allocation exceptions fail-stop via noexcept, never return a false release ACK.
    auto result = std::make_unique<MKCall>();
    result->backend = std::make_shared<CallBackend>(callbacks);
    if (!result->backend->initialize(config, std::move(factory))) std::terminate();
    return result.release();
}
}
extern "C" {
MKCall *mk_call_create(const MKCallConfig *config, const MKCallCallbacks *callbacks) noexcept {
    if (!config || !callbacks) return nullptr;
    return makosh::createCall(*config, *callbacks, [](webrtc::TaskQueueFactory *factory) {
        return webrtc::AudioDeviceModule::Create(webrtc::AudioDeviceModule::kPlatformDefaultAudio, factory);
    });
}
int32_t mk_call_receive_signaling(MKCall *call, const uint8_t *bytes, size_t size) noexcept { return call && call->backend->receive(bytes, size); }
int32_t mk_call_set_muted(MKCall *call, int32_t value) noexcept { return call && call->backend->setMuted(value); }
int32_t mk_call_set_video(MKCall *call, int32_t value) noexcept { return call && call->backend->setVideo(value); }
int32_t mk_call_push_video(MKCall *call, CVPixelBufferRef frame) noexcept { return call && call->backend->pushVideo(frame); }
void mk_call_stop(MKCall *call) noexcept { if (call) call->backend->stop(); }
void mk_call_destroy(MKCall *call) noexcept { if (call && call->backend->isReleased()) delete call; }
}
