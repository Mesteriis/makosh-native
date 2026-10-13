// SPDX-License-Identifier: MIT
#pragma once
#include "MakoshTelegramVoIP.h"
#include <algorithm>
#include <cstring>
#include <string_view>

namespace makosh {
template <size_t N> inline bool terminated(const char (&value)[N]) {
    return std::memchr(value, 0, N) != nullptr;
}
template <size_t N> inline bool validHost(const char (&value)[N]) {
    if (!terminated(value) || !value[0]) return false;
    return std::all_of(value, value + std::strlen(value), [](unsigned char c) {
        return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
            (c >= '0' && c <= '9') || c == '.' || c == '-' || c == ':';
    });
}
inline bool validateCall(const MKCallConfig &config) {
    if (config.abi_version != 1 || !terminated(config.version) ||
        (std::string_view(config.version) != "2.7.7" && std::string_view(config.version) != "5.0.0") ||
        (config.max_layer < 65 || config.max_layer > 92) || config.outgoing > 1 || config.allow_p2p > 1 ||
        config.allow_tcp > 1 || config.video > 1 || config.use_proxy > 1 ||
        std::none_of(std::begin(config.key), std::end(config.key), [](uint8_t b) { return b != 0; }) ||
        config.server_count > 32 || (config.server_count && !config.servers)) return false;
    bool relay = false, proxyRelay = false;
    for (size_t i = 0; i < config.server_count; ++i) {
        const auto &server = config.servers[i];
        if (!validHost(server.host) || !server.port || server.turn > 1 || server.tcp > 1 ||
            !terminated(server.username) || !terminated(server.password) ||
            (server.turn && (!server.username[0] || !server.password[0]))) return false;
        if (std::string_view(server.username) == "reflector") {
            if (!server.id || !server.turn || std::strlen(server.password) != 32 ||
                !std::all_of(server.password, server.password + 32, [](unsigned char c) {
                    return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f');
                })) return false;
        }
        relay = relay || server.turn;
        proxyRelay = proxyRelay || (server.turn && server.tcp);
    }
    if (!config.allow_p2p && !relay) return false;
    if (config.use_proxy && (!validHost(config.proxy_host) || !config.proxy_port || config.allow_p2p || !proxyRelay ||
        !terminated(config.proxy_username) || !terminated(config.proxy_password))) return false;
    return true;
}
} // namespace makosh
