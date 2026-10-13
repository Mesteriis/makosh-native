// SPDX-License-Identifier: MIT
#pragma once
#include <stddef.h>
#include <stdint.h>
#include <CoreVideo/CoreVideo.h>
#ifdef __cplusplus
extern "C" {
#define MK_CALL_NOEXCEPT noexcept
#else
#define MK_CALL_NOEXCEPT
#endif
#define MK_CALL_EXPORT __attribute__((visibility("default")))
typedef struct MKCall MKCall;
typedef struct {
    char host[256], username[256], password[256];
    uint16_t port;
    uint8_t id, turn, tcp;
} MKCallServer;
typedef struct {
    uint32_t abi_version;
    char version[16];
    uint8_t key[256];
    uint8_t outgoing, allow_p2p, allow_tcp, video, use_proxy;
    int32_t max_layer;
    const MKCallServer *servers;
    size_t server_count;
    char proxy_host[256], proxy_username[256], proxy_password[256];
    uint16_t proxy_port;
} MKCallConfig;
typedef struct {
    void *context;
    // 0 failed, 1 connecting, 2 established, 3 reconnecting.
    void (*state)(void *, int32_t);
    void (*remote_video)(void *, int32_t);
    // Borrowed memory; recipients must copy/retain before returning. No logging.
    void (*signaling)(void *, const uint8_t *, size_t);
    void (*video_frame)(void *, CVPixelBufferRef);
    // Last callback; confirms native capture/device release. May run off main.
    void (*released)(void *);
} MKCallCallbacks;
// Every input is copied synchronously. Calls for one handle must be serialized.
// A null return performs no capture and never schedules callbacks.
MK_CALL_EXPORT MKCall *mk_call_create(const MKCallConfig *, const MKCallCallbacks *) MK_CALL_NOEXCEPT;
MK_CALL_EXPORT int32_t mk_call_receive_signaling(MKCall *, const uint8_t *, size_t) MK_CALL_NOEXCEPT;
MK_CALL_EXPORT int32_t mk_call_set_muted(MKCall *, int32_t) MK_CALL_NOEXCEPT;
MK_CALL_EXPORT int32_t mk_call_set_video(MKCall *, int32_t) MK_CALL_NOEXCEPT;
// Only bounded, even-size, bi-planar 420v/420f buffers are accepted, copied on entry.
MK_CALL_EXPORT int32_t mk_call_push_video(MKCall *, CVPixelBufferRef) MK_CALL_NOEXCEPT;
// Idempotent for a live handle; callbacks are revoked immediately except released.
MK_CALL_EXPORT void mk_call_stop(MKCall *) MK_CALL_NOEXCEPT;
// Only after released; invalidates the handle. The caller retains it until then.
MK_CALL_EXPORT void mk_call_destroy(MKCall *) MK_CALL_NOEXCEPT;
#ifdef __cplusplus
}
#endif
