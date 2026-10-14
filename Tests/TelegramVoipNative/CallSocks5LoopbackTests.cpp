// SPDX-License-Identifier: MIT
#include "CallProxySocket.hpp"
#include "rtc_base/physical_socket_server.h"
#include "rtc_base/logging.h"
#include "rtc_base/thread.h"
#include <cassert>
#include <chrono>
#include <iostream>
#include <poll.h>
#include <thread>
#include <unistd.h>

struct Listener {
    int fd = ::socket(AF_INET, SOCK_STREAM, 0);
    uint16_t port = 0;
    Listener() {
        assert(fd >= 0);
        sockaddr_in address{}; address.sin_family = AF_INET; address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
        assert(::bind(fd, reinterpret_cast<sockaddr *>(&address), sizeof(address)) == 0);
        socklen_t size = sizeof(address);
        assert(getsockname(fd, reinterpret_cast<sockaddr *>(&address), &size) == 0);
        port = ntohs(address.sin_port); assert(::listen(fd, 1) == 0);
    }
    ~Listener() { ::close(fd); }
};
static std::vector<uint8_t> receive(int fd, size_t size) {
    std::vector<uint8_t> result(size);
    size_t offset = 0;
    while (offset < size) {
        pollfd ready{fd, POLLIN, 0}; assert(::poll(&ready, 1, 3000) == 1);
        const auto count = ::recv(fd, result.data() + offset, size - offset, 0);
        assert(count > 0); offset += size_t(count);
    }
    return result;
}
class Events final : public sigslot::has_slots<> {
public:
    bool connected = false, received = false;
    std::string payload;
    void connect(rtc::Socket *socket) {
        connected = true;
        assert(socket->Send("PING", 4) == 4);
    }
    void read(rtc::Socket *socket) {
        char bytes[4]; int64_t time;
        const int count = socket->Recv(bytes, 4, &time);
        if (count < 0 && rtc::IsBlockingError(socket->GetError())) return;
        assert(count > 0); payload.append(bytes, size_t(count));
        assert(payload.size() <= 4);
        if (payload.size() == 4) { assert(payload == "PONG"); received = true; }
    }
};
int main() {
    rtc::LogMessage::LogToDebug(rtc::LS_NONE);
    Listener proxyListener, forbiddenDirectRelay;
    std::thread proxy([&] {
        pollfd ready{proxyListener.fd, POLLIN, 0}; assert(::poll(&ready, 1, 3000) == 1);
        const int fd = ::accept(proxyListener.fd, nullptr, nullptr); assert(fd >= 0);
        assert((receive(fd, 3) == std::vector<uint8_t>{5, 1, 0}));
        const uint8_t method[]{5, 0}; assert(::send(fd, method, sizeof(method), 0) == 2);
        const auto request = receive(fd, 10);
        assert((request == std::vector<uint8_t>{5, 1, 0, 1, 127, 0, 0, 1,
            uint8_t(forbiddenDirectRelay.port >> 8), uint8_t(forbiddenDirectRelay.port)}));
        const uint8_t reply[]{5, 0, 0, 1, 127, 0, 0, 1, 0, 1, 'P', 'O', 'N', 'G'};
        assert(::send(fd, reply, sizeof(reply), 0) == sizeof(reply));
        assert((receive(fd, 4) == std::vector<uint8_t>{'P', 'I', 'N', 'G'}));
        ::close(fd);
    });
    rtc::PhysicalSocketServer server;
    rtc::AutoSocketServerThread thread(&server);
    rtc::ProxyInfo proxyInfo; proxyInfo.type = rtc::PROXY_SOCKS5;
    proxyInfo.address = rtc::SocketAddress("127.0.0.1", proxyListener.port);
    auto socket = std::make_unique<makosh::CallSocks5Socket>(server.CreateSocket(AF_INET, SOCK_STREAM), proxyInfo);
    Events events;
    socket->SignalConnectEvent.connect(&events, &Events::connect);
    socket->SignalReadEvent.connect(&events, &Events::read);
    assert(socket->Connect(rtc::SocketAddress("127.0.0.1", forbiddenDirectRelay.port)) == 0);
    const auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (!events.received && std::chrono::steady_clock::now() < deadline) {
        server.Wait(webrtc::TimeDelta::Millis(10), true);
    }
    assert(events.connected && events.received);
    pollfd direct{forbiddenDirectRelay.fd, POLLIN, 0};
    assert(::poll(&direct, 1, 0) == 0); // Real TCP connection reached only SOCKS5.
    socket->Close(); socket.reset(); proxy.join();
    std::cout << "Actual loopback SOCKS5 CONNECT/media: proxy only, no direct relay connection\n";
}
