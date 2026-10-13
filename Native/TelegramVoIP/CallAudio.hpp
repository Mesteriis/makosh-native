// SPDX-License-Identifier: MIT
#pragma once
#include "CallNative.hpp"
namespace makosh {
// The returned module is already initialized. A rejected injected device never
// reaches MediaManager's physical-device fallback; failure is explicitly emitted.
webrtc::scoped_refptr<webrtc::AudioDeviceModule> prepareCallAudio(
    const AudioFactory &, webrtc::TaskQueueFactory *, std::function<void()> failed, std::function<void()> released);
}
