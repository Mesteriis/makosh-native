// SPDX-License-Identifier: MIT
#include "CallAudio.hpp"
#include "platform/PlatformInterface.h"
#include "api/task_queue/default_task_queue_factory.h"
#include "api/make_ref_counted.h"
#include <cassert>
#include <iostream>
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
