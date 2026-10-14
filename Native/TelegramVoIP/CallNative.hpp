// SPDX-License-Identifier: MIT
#pragma once
#include "MakoshTelegramVoIP.h"
#include "api/scoped_refptr.h"
#include "modules/audio_device/include/audio_device.h"
#include <functional>
namespace makosh {
using AudioFactory = std::function<webrtc::scoped_refptr<webrtc::AudioDeviceModule>(webrtc::TaskQueueFactory *)>;
// Internal injected device boundary; absent from the dylib's exported C ABI.
MKCall *createCall(const MKCallConfig &, const MKCallCallbacks &, AudioFactory) noexcept;
}
