// SPDX-License-Identifier: MIT
#include "CallNative.hpp"
#include "CallVideo.hpp"
#include "EncryptedConnection.h"
#include "LogSinkImpl.h"
#include "api/task_queue/default_task_queue_factory.h"
#include "modules/audio_device/include/test_audio_device.h"
#include "rtc_base/copy_on_write_buffer.h"
#include <atomic>
#include <cassert>
#include <chrono>
#include <cmath>
#include <cstring>
#include <deque>
#include <filesystem>
#include <iostream>
#include <mutex>
#include <thread>

struct Endpoint {
    MKCall *call = nullptr;
    std::atomic<int> connected{0}, frames{0}, audio{0}, released{0};
    std::mutex mutex;
    std::deque<std::vector<uint8_t>> signaling;
};
class Tone final : public webrtc::TestAudioDeviceModule::Capturer {
    int64_t sample = 0;
public:
    int SamplingFrequency() const override { return 48000; }
    int NumChannels() const override { return 1; }
    bool Capture(rtc::BufferT<int16_t> *buffer) override {
        buffer->SetSize(480);
        for (auto &value : *buffer) value = int16_t(8000 * std::sin(2 * 3.141592653589793 * 440 * sample++ / 48000));
        return true;
    }
};
class Output final : public webrtc::TestAudioDeviceModule::Renderer {
    Endpoint &endpoint;
public:
    explicit Output(Endpoint &endpoint) : endpoint(endpoint) {}
    int SamplingFrequency() const override { return 48000; }
    int NumChannels() const override { return 1; }
    bool Render(rtc::ArrayView<const int16_t> data) override {
        if (std::any_of(data.begin(), data.end(), [](int16_t v) { return std::abs(int(v)) > 20; })) ++endpoint.audio;
        return true;
    }
};
MKCallCallbacks callbacks(Endpoint &endpoint) {
    MKCallCallbacks result{}; result.context = &endpoint;
    result.state = [](void *p, int32_t value) { if (value == 2) ++static_cast<Endpoint *>(p)->connected; };
    result.remote_video = [](void *, int32_t) {};
    result.signaling = [](void *p, const uint8_t *data, size_t size) {
        auto &endpoint = *static_cast<Endpoint *>(p); std::lock_guard lock(endpoint.mutex);
        assert(endpoint.signaling.size() < 256 && size <= 65536);
        endpoint.signaling.emplace_back(data, data + size);
    };
    result.video_frame = [](void *p, CVPixelBufferRef frame) {
        assert(frame && CVPixelBufferGetWidth(frame) == 320 && CVPixelBufferGetHeight(frame) == 240);
        ++static_cast<Endpoint *>(p)->frames;
    };
    result.released = [](void *p) { ++static_cast<Endpoint *>(p)->released; };
    return result;
}
void relay(Endpoint &from, Endpoint &to) {
    std::deque<std::vector<uint8_t>> packets;
    { std::lock_guard lock(from.mutex); packets.swap(from.signaling); }
    for (const auto &packet : packets) assert(mk_call_receive_signaling(to.call, packet.data(), packet.size()));
}
int main(int argc, char **argv) {
    auto image = webrtc::I420Buffer::Create(4, 2);
    image->InitializeData();
    const uint8_t pixels[] = {1, 2, 3, 4, 5, 6, 7, 8};
    for (int y = 0; y < 2; ++y) std::memcpy(image->MutableDataY() + y * image->StrideY(), pixels + y * 4, 4);
    const webrtc::VideoRotation rotations[] = {webrtc::kVideoRotation_0, webrtc::kVideoRotation_90, webrtc::kVideoRotation_180, webrtc::kVideoRotation_270};
    const uint8_t expected[] = {1, 5, 8, 4};
    for (int i = 0; i < 4; ++i) {
        auto input = webrtc::VideoFrame::Builder().set_video_frame_buffer(image).set_rotation(rotations[i]).build();
        auto output = makosh::callVideoOutput(input);
        assert(output);
        assert(CVPixelBufferGetWidth(output) == (i % 2 ? 2 : 4));
        assert(CVPixelBufferGetHeight(output) == (i % 2 ? 4 : 2));
        assert(CVPixelBufferLockBaseAddress(output, kCVPixelBufferLock_ReadOnly) == kCVReturnSuccess);
        assert(*static_cast<uint8_t *>(CVPixelBufferGetBaseAddressOfPlane(output, 0)) == expected[i]);
        CVPixelBufferUnlockBaseAddress(output, kCVPixelBufferLock_ReadOnly); CVPixelBufferRelease(output);
    }

    const std::string version = argc == 2 ? argv[1] : "5.0.0";
    assert(version == "2.7.7" || version == "5.0.0");
    auto key = std::make_shared<std::array<uint8_t, 256>>();
    for (size_t i = 0; i < key->size(); ++i) (*key)[i] = uint8_t(i);
    tgcalls::EncryptedConnection sender(tgcalls::EncryptedConnection::Type::Transport, {key, true}, [](int, int) {});
    tgcalls::EncryptedConnection receiver(tgcalls::EncryptedConnection::Type::Transport, {key, false}, [](int, int) {});
    auto wrongKey = std::make_shared<std::array<uint8_t, 256>>(*key); (*wrongKey)[0] ^= 17;
    tgcalls::EncryptedConnection wrong(tgcalls::EncryptedConnection::Type::Transport, {wrongKey, false}, [](int, int) {});
    uint8_t body[] = {1, 2, 3, 4}; rtc::CopyOnWriteBuffer clear(body, sizeof(body));
    auto cipher = sender.encryptRawPacket(clear); assert(cipher);
    assert(!wrong.decryptRawPacket(*cipher));
    auto decoded = receiver.decryptRawPacket(*cipher); assert(decoded && decoded->size() == sizeof(body));
    assert(std::memcmp(decoded->data(), body, sizeof(body)) == 0);
    const auto forbiddenLog = std::filesystem::temp_directory_path() / "makosh-voip-synthetic-log-forbidden";
    assert(!std::filesystem::exists(forbiddenLog));
    tgcalls::LogSinkImpl sink({forbiddenLog.string()}); sink.OnLogMessage("synthetic-private-canary");
    assert(sink.result().empty() && !std::filesystem::exists(forbiddenLog));
    Endpoint left, right;
    MKCallConfig config{}; config.abi_version = 1; std::memcpy(config.version, version.c_str(), version.size() + 1);
    std::memcpy(config.key, key->data(), 256); config.max_layer = 92; config.allow_p2p = 1; config.video = 1;
    auto create = [&](Endpoint &endpoint, bool outgoing) {
        config.outgoing = outgoing; auto cb = callbacks(endpoint);
        return makosh::createCall(config, cb, [&endpoint](webrtc::TaskQueueFactory *factory) {
            auto result = webrtc::TestAudioDeviceModule::Create(factory, std::make_unique<Tone>(), std::make_unique<Output>(endpoint));
            assert(result && result->Init() == 0); return result;
        });
    };
    left.call = create(left, true); right.call = create(right, false); assert(left.call && right.call);
    CVPixelBufferRef frame = nullptr;
    assert(CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nullptr, &frame) == kCVReturnSuccess);
    CVPixelBufferLockBaseAddress(frame, 0);
    std::memset(CVPixelBufferGetBaseAddressOfPlane(frame, 0), 100, CVPixelBufferGetBytesPerRowOfPlane(frame, 0) * 240);
    std::memset(CVPixelBufferGetBaseAddressOfPlane(frame, 1), 128, CVPixelBufferGetBytesPerRowOfPlane(frame, 1) * 120);
    CVPixelBufferUnlockBaseAddress(frame, 0);
    for (int step = 0; step < 600; ++step) {
        relay(left, right); relay(right, left);
        assert(mk_call_push_video(left.call, frame)); assert(mk_call_push_video(right.call, frame));
        if (left.connected && right.connected && left.audio > 5 && right.audio > 5 && left.frames > 3 && right.frames > 3) break;
        std::this_thread::sleep_for(std::chrono::milliseconds(50));
    }
    assert(left.connected && right.connected && left.audio > 5 && right.audio > 5 && left.frames > 3 && right.frames > 3);
    assert(mk_call_set_muted(left.call, 1)); assert(mk_call_set_video(left.call, 0));
    auto pump = [&] {
        relay(left, right); relay(right, left);
        assert(mk_call_push_video(left.call, frame)); assert(mk_call_push_video(right.call, frame));
        std::this_thread::sleep_for(std::chrono::milliseconds(20));
    };
    for (int i = 0; i < 60; ++i) pump();
    const int mutedAudio = right.audio.load(), stoppedVideo = right.frames.load();
    for (int i = 0; i < 20; ++i) pump();
    assert(right.audio == mutedAudio && right.frames == stoppedVideo);
    assert(mk_call_set_muted(left.call, 0)); assert(mk_call_set_video(left.call, 1));
    for (int i = 0; i < 150 && (right.audio <= mutedAudio + 5 || right.frames <= stoppedVideo + 3); ++i) pump();
    assert(right.audio > mutedAudio + 5 && right.frames > stoppedVideo + 3);
    CVPixelBufferRelease(frame);
    assert(!mk_call_receive_signaling(left.call, nullptr, 1));
    mk_call_stop(left.call); mk_call_stop(right.call);
    for (int i = 0; i < 200 && (!left.released || !right.released); ++i) std::this_thread::sleep_for(std::chrono::milliseconds(20));
    assert(left.released == 1 && right.released == 1);
    assert(!mk_call_set_muted(left.call, 0)); assert(!mk_call_set_video(left.call, 1));
    const auto frames = left.frames.load(); std::this_thread::sleep_for(std::chrono::milliseconds(100)); assert(left.frames == frames);
    mk_call_destroy(left.call); mk_call_destroy(right.call);
    std::cout << "Native " << version << " encrypted VP8/Opus pair: connected, received PCM/video, wrong-key refused, logs disabled, mute/video controls verified, media released\n";
}
