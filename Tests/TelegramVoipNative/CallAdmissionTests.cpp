// SPDX-License-Identifier: MIT
#include "CallAdmission.hpp"
#include <cassert>
#include <cstring>
#include <iostream>

static_assert(noexcept(mk_call_create(nullptr, nullptr)));
static_assert(noexcept(mk_call_receive_signaling(nullptr, nullptr, 0)));
static_assert(noexcept(mk_call_set_muted(nullptr, 0)));
static_assert(noexcept(mk_call_set_video(nullptr, 0)));
static_assert(noexcept(mk_call_push_video(nullptr, nullptr)));
static_assert(noexcept(mk_call_stop(nullptr)));
static_assert(noexcept(mk_call_destroy(nullptr)));
int main() {
    MKCallConfig config{};
    config.abi_version = 1;
    std::memcpy(config.version, "5.0.0", 6);
    config.key[0] = 17;
    config.outgoing = 1;
    config.allow_p2p = 1;
    config.max_layer = 92;
    assert(makosh::validateCall(config));
    std::memset(config.audio_input_uid, 'x', sizeof(config.audio_input_uid));
    assert(makosh::validateCall(config)); // ABI1 never reads the appended fields.
    config.abi_version = 2; assert(!makosh::validateCall(config));
    config.audio_input_uid[0] = 0; assert(makosh::validateCall(config));
    config.abi_version = 1;
    config.max_layer = 65; assert(makosh::validateCall(config)); config.max_layer = 92;
    for (int field = 0; field != 8; ++field) {
        auto invalid = config;
        switch (field) {
        case 0: invalid.abi_version = 3; break;
        case 1: std::memset(invalid.key, 0, sizeof(invalid.key)); break;
        case 2: std::memcpy(invalid.version, "6.0.0", 6); break;
        case 3: invalid.outgoing = 2; break;
        case 4: invalid.allow_p2p = 2; break;
        case 5: invalid.max_layer = 64; break;
        case 6: invalid.server_count = 33; break;
        case 7: invalid.server_count = 1; invalid.servers = nullptr; break;
        }
        assert(!makosh::validateCall(invalid));
    }
    config.allow_p2p = 0;
    assert(!makosh::validateCall(config));
    MKCallServer relay{};
    std::memcpy(relay.host, "203.0.113.17", 13);
    relay.port = 443;
    relay.id = 1;
    relay.turn = 1;
    std::memcpy(relay.username, "reflector", 10);
    std::memcpy(relay.password, "00112233445566778899aabbccddeeff", 33);
    config.servers = &relay; config.server_count = 1;
    assert(makosh::validateCall(config));
    relay.password[0] = 'x'; assert(!makosh::validateCall(config)); relay.password[0] = '0';
    relay.turn = 0;
    assert(!makosh::validateCall(config));
    relay.turn = 1; relay.port = 0;
    assert(!makosh::validateCall(config));
    relay.port = 443;
    std::memset(relay.host, 'x', sizeof(relay.host));
    assert(!makosh::validateCall(config));
    std::memset(relay.host, 0, sizeof(relay.host));
    std::memcpy(relay.host, "127.0.0.1", 10);
    assert(makosh::validateCall(config));
    config.use_proxy = 1;
    assert(!makosh::validateCall(config));
    std::memcpy(config.proxy_host, "127.0.0.1", 10); config.proxy_port = 1080;
    assert(!makosh::validateCall(config)); // UDP relay cannot carry a SOCKS5 call
    relay.tcp = 1;
    assert(makosh::validateCall(config));
    config.allow_p2p = 1;
    assert(!makosh::validateCall(config)); // never bypass call proxy with direct candidates
    std::cout << "Call admission: malformed input and relay/proxy policy pass\n";
}
