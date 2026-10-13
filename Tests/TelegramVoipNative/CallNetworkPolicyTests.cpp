// SPDX-License-Identifier: MIT
#include "CallNetworkPolicy.hpp"
#include "rtc_base/network.h"
#include "rtc_base/physical_socket_server.h"
#include "p2p/base/basic_packet_socket_factory.h"
#include <cassert>
#include <iostream>
int main() {
    rtc::PhysicalSocketServer socketServer;
    rtc::BasicPacketSocketFactory sockets(&socketServer);
    rtc::BasicNetworkManager network(&socketServer);
    {
        cricket::BasicPortAllocator allocator(&network, &sockets);
        makosh::configureCallPortAllocator(allocator, false, true, false);
        assert(allocator.candidate_filter() == cricket::CF_RELAY);
        assert(allocator.flags() & cricket::PORTALLOCATOR_DISABLE_UDP);
        assert(allocator.flags() & cricket::PORTALLOCATOR_DISABLE_TCP);
        assert(allocator.flags() & cricket::PORTALLOCATOR_DISABLE_STUN);
    }
    {
        cricket::BasicPortAllocator allocator(&network, &sockets);
        makosh::configureCallPortAllocator(allocator, true, true, true);
        assert(allocator.candidate_filter() == cricket::CF_RELAY);
        assert(allocator.flags() & cricket::PORTALLOCATOR_DISABLE_UDP);
        assert(allocator.flags() & cricket::PORTALLOCATOR_DISABLE_TCP);
        assert(allocator.flags() & cricket::PORTALLOCATOR_DISABLE_STUN);
        assert(allocator.flags() & cricket::PORTALLOCATOR_DISABLE_UDP_RELAY);
    }
    {
        cricket::BasicPortAllocator allocator(&network, &sockets);
        makosh::configureCallPortAllocator(allocator, true, true, false);
        assert(allocator.candidate_filter() == cricket::CF_ALL);
        assert(!(allocator.flags() & cricket::PORTALLOCATOR_DISABLE_UDP));
        assert(!(allocator.flags() & cricket::PORTALLOCATOR_DISABLE_TCP));
    }
    assert(!makosh::callRelayProtocol(false, true));
    assert(makosh::callRelayProtocol(true, true) == cricket::PROTO_TCP);
    assert(makosh::callRelayProtocol(false, false) == cricket::PROTO_UDP);
    std::cout << "Native ICE allocator: P2P denial and SOCKS5 forbid host/STUN/UDP relay bypass\n";
}
