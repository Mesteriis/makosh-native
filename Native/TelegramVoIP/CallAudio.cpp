// SPDX-License-Identifier: MIT
#include "CallAudio.hpp"
#include "platform/PlatformInterface.h"
#include "api/make_ref_counted.h"
#include "rtc_base/checks.h"
#include <optional>
#include <cstring>
namespace makosh {
class ReleaseAwareAudio : public tgcalls::DefaultWrappedAudioDeviceModule {
    webrtc::scoped_refptr<webrtc::AudioDeviceModule> rejected;
    std::function<void()> released, failed;
    CallAudioDevices devices;
    uint16_t inputIndex = 0, outputIndex = 0;
    bool blocked = false;
    bool matches(bool input, uint16_t index) {
        const auto &uid = input ? devices.input : devices.output;
        char name[webrtc::kAdmMaxDeviceNameSize]{}, guid[webrtc::kAdmMaxGuidSize]{};
        auto module = WrappedInstance();
        const auto count = input ? module->RecordingDevices() : module->PlayoutDevices();
        if (count < 0 || count > 256 || index >= count) return false;
        const auto result = input ? module->RecordingDeviceName(index, name, guid) : module->PlayoutDeviceName(index, name, guid);
        return result == 0 && std::memchr(guid, 0, sizeof(guid)) && uid == guid;
    }
    int32_t reject() { if (!blocked) { blocked = true; failed(); } return -1; }
    int32_t select(bool input, uint16_t requested) {
        if (blocked) return -1;
        const auto &uid = input ? devices.input : devices.output;
        auto module = WrappedInstance();
        if (uid.empty()) return input ? module->SetRecordingDevice(requested) : module->SetPlayoutDevice(requested);
        if (uid.size() >= webrtc::kAdmMaxGuidSize || uid.find('\0') != std::string::npos) return reject();
        const auto count = input ? module->RecordingDevices() : module->PlayoutDevices();
        if (count <= 0 || count > 256) return reject();
        std::optional<uint16_t> chosen;
        for (int i = 0; i < count; ++i) {
            if (!matches(input, uint16_t(i))) continue;
            // macOS enumerates the default alias at0 and the same concrete
            // device again. Prefer the concrete entry, never the moving alias.
            if (chosen && *chosen != 0) return reject();
            chosen = uint16_t(i);
        }
        if (!chosen || *chosen == 0) return reject();
        const auto result = input ? module->SetRecordingDevice(*chosen) : module->SetPlayoutDevice(*chosen);
        if (result != 0 || !matches(input, *chosen)) return reject();
        (input ? inputIndex : outputIndex) = *chosen;
        return 0;
    }
    bool admit(bool input) {
        if (blocked) return false;
        const auto &uid = input ? devices.input : devices.output;
        if (uid.empty() || matches(input, input ? inputIndex : outputIndex)) return true;
        reject(); return false;
    }
    static bool stopDevice(const webrtc::scoped_refptr<webrtc::AudioDeviceModule> &module) {
        if (!module) return true;
        module->StopRecording(); module->StopPlayout();
        return module->Terminate() == 0 && !module->Recording() && !module->Playing();
    }
public:
    ReleaseAwareAudio(webrtc::scoped_refptr<webrtc::AudioDeviceModule> module,
        webrtc::scoped_refptr<webrtc::AudioDeviceModule> rejected, std::function<void()> released,
        std::function<void()> failed, CallAudioDevices devices, bool blocked)
        : DefaultWrappedAudioDeviceModule(module), rejected(std::move(rejected)), released(std::move(released)),
          failed(std::move(failed)), devices(std::move(devices)), blocked(blocked) {}
    void selectInitial() {
        if (!devices.input.empty()) select(true, 0);
        if (!devices.output.empty()) select(false, 0);
    }
    int32_t SetRecordingDevice(uint16_t index) override { return select(true, index); }
    int32_t SetPlayoutDevice(uint16_t index) override { return select(false, index); }
    int32_t SetRecordingDevice(WindowsDeviceType type) override {
        return devices.input.empty() && !blocked ? WrappedInstance()->SetRecordingDevice(type) : select(true, 0);
    }
    int32_t SetPlayoutDevice(WindowsDeviceType type) override {
        return devices.output.empty() && !blocked ? WrappedInstance()->SetPlayoutDevice(type) : select(false, 0);
    }
    int32_t InitRecording() override {
        if (!admit(true)) return -1;
        const auto result = WrappedInstance()->InitRecording();
        return result == 0 && admit(true) ? 0 : reject();
    }
    int32_t InitPlayout() override {
        if (!admit(false)) return -1;
        const auto result = WrappedInstance()->InitPlayout();
        return result == 0 && admit(false) ? 0 : reject();
    }
    int32_t StartRecording() override { return admit(true) ? WrappedInstance()->StartRecording() : -1; }
    int32_t StartPlayout() override { return admit(false) ? WrappedInstance()->StartPlayout() : -1; }
    // Preflight already succeeded; no second initialization can trigger fallback.
    int32_t Init() override { return 0; }
    ~ReleaseAwareAudio() override {
        const bool currentStopped = stopDevice(WrappedInstance());
        const bool rejectedStopped = stopDevice(rejected);
        if (currentStopped && rejectedStopped) released();
    }
};
webrtc::scoped_refptr<webrtc::AudioDeviceModule> prepareCallAudio(const AudioFactory &factory,
    webrtc::TaskQueueFactory *queue, std::function<void()> failed, std::function<void()> released, CallAudioDevices devices) {
    auto module = factory(queue);
    webrtc::scoped_refptr<webrtc::AudioDeviceModule> rejected;
    bool blocked = false;
    if (!module || module->Init() != 0) {
        blocked = true;
        rejected = module;
        failed();
        // An inert native module carries cleanup after failure. It never opens a
        // device or produces a connected UI outcome. Never return nil here.
        module = webrtc::AudioDeviceModule::Create(webrtc::AudioDeviceModule::kDummyAudio, queue);
        RTC_CHECK(module && module->Init() == 0);
    }
    auto result = rtc::make_ref_counted<ReleaseAwareAudio>(module, rejected, std::move(released), std::move(failed), std::move(devices), blocked);
    result->selectInitial(); return result;
}
}
