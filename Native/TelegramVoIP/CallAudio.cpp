// SPDX-License-Identifier: MIT
#include "CallAudio.hpp"
#include "platform/PlatformInterface.h"
#include "api/make_ref_counted.h"
#include "rtc_base/checks.h"
namespace makosh {
class ReleaseAwareAudio : public tgcalls::DefaultWrappedAudioDeviceModule {
    webrtc::scoped_refptr<webrtc::AudioDeviceModule> rejected;
    std::function<void()> released;
    static bool stopDevice(const webrtc::scoped_refptr<webrtc::AudioDeviceModule> &module) {
        if (!module) return true;
        module->StopRecording(); module->StopPlayout();
        return module->Terminate() == 0 && !module->Recording() && !module->Playing();
    }
public:
    ReleaseAwareAudio(webrtc::scoped_refptr<webrtc::AudioDeviceModule> module,
        webrtc::scoped_refptr<webrtc::AudioDeviceModule> rejected, std::function<void()> released)
        : DefaultWrappedAudioDeviceModule(module), rejected(std::move(rejected)), released(std::move(released)) {}
    // Preflight already succeeded; no second initialization can trigger fallback.
    int32_t Init() override { return 0; }
    ~ReleaseAwareAudio() override {
        const bool currentStopped = stopDevice(WrappedInstance());
        const bool rejectedStopped = stopDevice(rejected);
        if (currentStopped && rejectedStopped) released();
    }
};
webrtc::scoped_refptr<webrtc::AudioDeviceModule> prepareCallAudio(const AudioFactory &factory,
    webrtc::TaskQueueFactory *queue, std::function<void()> failed, std::function<void()> released) {
    auto module = factory(queue);
    webrtc::scoped_refptr<webrtc::AudioDeviceModule> rejected;
    if (!module || module->Init() != 0) {
        rejected = module;
        failed();
        // An inert native module carries cleanup after failure. It never opens a
        // device or produces a connected UI outcome. Never return nil here.
        module = webrtc::AudioDeviceModule::Create(webrtc::AudioDeviceModule::kDummyAudio, queue);
        RTC_CHECK(module && module->Init() == 0);
    }
    return rtc::make_ref_counted<ReleaseAwareAudio>(module, rejected, std::move(released));
}
}
