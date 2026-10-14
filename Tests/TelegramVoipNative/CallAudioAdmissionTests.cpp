// SPDX-License-Identifier: MIT
#include "CallAudio.hpp"
#include "platform/PlatformInterface.h"
#include "api/task_queue/default_task_queue_factory.h"
#include "api/make_ref_counted.h"
#include <cassert>
#include <iostream>
#include <cstring>
class SelectedAudio : public tgcalls::DefaultWrappedAudioDeviceModule {
public:
    int input = -1, output = -1, starts = 0;
    bool present = true, duplicateDefault = true;
    explicit SelectedAudio(webrtc::scoped_refptr<webrtc::AudioDeviceModule> module) : DefaultWrappedAudioDeviceModule(module) {}
    int16_t RecordingDevices() override { return 2; }
    int16_t PlayoutDevices() override { return 2; }
    int32_t RecordingDeviceName(uint16_t index, char *name, char *guid) override {
        if (index > 1) return -1;
        std::strcpy(name, "QA"); std::strcpy(guid, present && (index == 1 || duplicateDefault) ? "qa-input" : "other-input"); return 0;
    }
    int32_t PlayoutDeviceName(uint16_t index, char *name, char *guid) override {
        if (index > 1) return -1;
        std::strcpy(name, "QA"); std::strcpy(guid, present && (index == 1 || duplicateDefault) ? "qa-output" : "other-output"); return 0;
    }
    int32_t SetRecordingDevice(uint16_t index) override { input = index; return 0; }
    int32_t SetPlayoutDevice(uint16_t index) override { output = index; return 0; }
    int32_t InitRecording() override { return 0; }
    int32_t InitPlayout() override { return 0; }
    int32_t StartRecording() override { ++starts; return 0; }
    int32_t StartPlayout() override { ++starts; return 0; }
};
class CountedAudio : public tgcalls::DefaultWrappedAudioDeviceModule {
    int &initializations;
    bool fail;
public:
    CountedAudio(webrtc::scoped_refptr<webrtc::AudioDeviceModule> module, int &initializations, bool fail)
        : DefaultWrappedAudioDeviceModule(module), initializations(initializations), fail(fail) {}
    int32_t Init() override { ++initializations; return fail ? -1 : DefaultWrappedAudioDeviceModule::Init(); }
};
int main() {
    auto queue = webrtc::CreateDefaultTaskQueueFactory();
    {
        int failures = 0, released = 0;
        auto selected = rtc::make_ref_counted<SelectedAudio>(webrtc::AudioDeviceModule::Create(webrtc::AudioDeviceModule::kDummyAudio, queue.get()));
        auto result = makosh::prepareCallAudio([&](auto *) -> webrtc::scoped_refptr<webrtc::AudioDeviceModule> { return selected; }, queue.get(),
            [&] { ++failures; }, [&] { ++released; }, {"qa-input", "qa-output"});
        assert(selected->input == 1 && selected->output == 1 && failures == 0);
        assert(result->SetRecordingDevice(uint16_t(0)) == 0 && selected->input == 1);
        assert(result->SetPlayoutDevice(uint16_t(0)) == 0 && selected->output == 1);
        selected->present = false;
        assert(result->StartRecording() == -1 && result->StartPlayout() == -1);
        assert(selected->starts == 0 && failures > 0);
        result = nullptr; assert(released == 1);
    }
    for (int mode = 0; mode < 3; ++mode) {
        int created = 0, initialized = 0, failures = 0, released = 0;
        auto result = makosh::prepareCallAudio([&](webrtc::TaskQueueFactory *factory) -> webrtc::scoped_refptr<webrtc::AudioDeviceModule> {
            ++created;
            if (mode == 0) return nullptr;
            auto dummy = webrtc::AudioDeviceModule::Create(webrtc::AudioDeviceModule::kDummyAudio, factory);
            assert(dummy); // Explicit dummy only: no physical factory or TCC.
            return rtc::make_ref_counted<CountedAudio>(dummy, initialized, mode == 1);
        }, queue.get(), [&] { ++failures; }, [&] { ++released; });
        assert(result && created == 1);
        assert(failures == (mode == 2 ? 0 : 1));
        for (int i = 0; i < 3; ++i) assert(result->Init() == 0);
        assert(initialized == (mode == 0 ? 0 : 1));
        assert(!result->Recording() && !result->Playing());
        assert(released == 0); result = nullptr; assert(released == 1);
    }
    std::cout << "Audio admission: one preflight; null/failed device stays noncapturing; native release remains observable\n";
}
