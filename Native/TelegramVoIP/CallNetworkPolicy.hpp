// SPDX-License-Identifier: MIT
#pragma once
#include "p2p/client/basic_port_allocator.h"
#include "p2p/base/port_interface.h"
#include <optional>
namespace makosh {
inline void configureCallPortAllocator(cricket::PortAllocator &allocator, bool p2p, bool tcp, bool proxy) {
    uint32_t flags = allocator.flags() | cricket::PORTALLOCATOR_ENABLE_IPV6 | cricket::PORTALLOCATOR_ENABLE_IPV6_ON_WIFI;
    if (!tcp || !p2p || proxy) flags |= cricket::PORTALLOCATOR_DISABLE_TCP;
    if (!p2p || proxy) {
        flags |= cricket::PORTALLOCATOR_DISABLE_UDP | cricket::PORTALLOCATOR_DISABLE_STUN;
        allocator.SetCandidateFilter(cricket::CF_RELAY);
    }
    if (proxy) flags |= cricket::PORTALLOCATOR_DISABLE_UDP_RELAY;
    allocator.set_flags(flags);
}
inline std::optional<cricket::ProtocolType> callRelayProtocol(bool tcp, bool proxy) {
    if (proxy && !tcp) return std::nullopt;
    return tcp ? cricket::PROTO_TCP : cricket::PROTO_UDP;
}
}
