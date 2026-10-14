// SPDX-License-Identifier: MIT
#include "v2/ReflectorPort.h"
#include "p2p/base/basic_packet_socket_factory.h"
#include "rtc_base/physical_socket_server.h"
#include "rtc_base/thread.h"
#include "rtc_base/logging.h"
#include "CallProxySocket.hpp"
#include <cassert>
#include <cstring>
#include <deque>
#include <iostream>

struct Wire {
    rtc::SocketAddress destination;
    std::vector<uint8_t> sent;
    std::deque<uint8_t> received;
    int destroyed = 0;
    int connects = 0;
    bool failConnect = false;
    size_t writeLimit = 1024;
};
class TestSocket final : public rtc::Socket {
public:
    explicit TestSocket(Wire &wire) : wire(wire) {}
    ~TestSocket() override { ++wire.destroyed; }
    Wire &wire;
    rtc::SocketAddress local;
    int error = 0;
    ConnState state = CS_CLOSED;
    rtc::SocketAddress GetLocalAddress() const override { return local; }
    rtc::SocketAddress GetRemoteAddress() const override { return wire.destination; }
    int Bind(const rtc::SocketAddress &address) override { local = address; return 0; }
    int Connect(const rtc::SocketAddress &address) override {
        ++wire.connects; wire.destination = address; state = CS_CONNECTING;
        if (wire.failConnect) { error = ECONNREFUSED; return -1; }
        return 0;
    }
    int Send(const void *data, size_t size) override {
        if (!wire.writeLimit) { error = EWOULDBLOCK; return -1; }
        size = std::min(size, wire.writeLimit);
        const auto *bytes = static_cast<const uint8_t *>(data);
        wire.sent.insert(wire.sent.end(), bytes, bytes + size);
        return int(size);
    }
    int SendTo(const void *, size_t, const rtc::SocketAddress &) override { assert(false); return -1; }
    int RecvFrom(void *, size_t, rtc::SocketAddress *, int64_t *) override { assert(false); return -1; }
    int Recv(void *data, size_t size, int64_t *) override {
        if (wire.received.empty()) { error = EWOULDBLOCK; return -1; }
        size = std::min(size, wire.received.size());
        for (size_t i = 0; i < size; ++i) { static_cast<uint8_t *>(data)[i] = wire.received.front(); wire.received.pop_front(); }
        return int(size);
    }
    int Listen(int) override { assert(false); return -1; }
    rtc::Socket *Accept(rtc::SocketAddress *) override { assert(false); return nullptr; }
    int Close() override { state = CS_CLOSED; return 0; }
    int GetError() const override { return error; }
    void SetError(int value) override { error = value; }
    ConnState GetState() const override { return state; }
    int GetOption(Option, int *value) override { *value = 0; return 0; }
    int SetOption(Option, int) override { return 0; }
    void connected() { state = CS_CONNECTED; SignalConnectEvent(this); }
    void receive(std::initializer_list<uint8_t> bytes) { wire.received.insert(wire.received.end(), bytes); SignalReadEvent(this); }
};
class Factory final : public rtc::SocketFactory {
public:
    Wire wire;
    TestSocket *socket = nullptr;
    bool failCreate = false;
    rtc::Socket *CreateSocket(int, int type) override {
        assert(type == SOCK_STREAM);
        if (failCreate) return nullptr;
        return socket = new TestSocket(wire);
    }
};
class Password final : public rtc::CryptStringImpl {
public:
    size_t GetLength() const override { return 1; }
    void CopyTo(char *out, bool terminate) const override { out[0] = 'p'; if (terminate) out[1] = 0; }
    std::string UrlEncode() const override { return "p"; }
    rtc::CryptStringImpl *Copy() const override { return new Password; }
    void CopyRawTo(std::vector<unsigned char> *out) const override { *out = {'p'}; }
};
static void boundaries(const std::string &mode) {
    Wire wire;
    auto *physical = new TestSocket(wire);
    rtc::ProxyInfo proxy; proxy.type = rtc::PROXY_SOCKS5;
    proxy.address = rtc::SocketAddress("127.0.0.3", 1080);
    const bool auth = mode == "auth-denied" || mode == "auth-downgrade";
    if (auth) { proxy.username = "u"; proxy.password = rtc::CryptString(Password{}); }
    auto socket = std::make_unique<makosh::CallSocks5Socket>(physical, proxy);
    const rtc::SocketAddress remote(mode == "domain" ? "relay.invalid" : mode == "ipv6" ? "::1" : "127.0.0.2", 8443);
    assert(socket->Connect(remote) == 0);
    assert(wire.destination == proxy.address);
    wire.writeLimit = 0;
    physical->connected();
    const char forbidden[] = "no-media-before-tunnel";
    assert(socket->Send(forbidden, sizeof(forbidden)) == -1);
    assert(wire.sent.empty());
    wire.writeLimit = 1; physical->SignalWriteEvent(physical);
    assert((wire.sent == std::vector<uint8_t>{5, 1, uint8_t(auth ? 2 : 0)}));
    wire.sent.clear();
    if (mode == "method-denied" || mode == "auth-downgrade") {
        physical->receive({5, uint8_t(auth ? 0 : 255)});
    } else {
        physical->receive({5}); physical->receive({uint8_t(auth ? 2 : 0)});
        if (auth) {
            assert((wire.sent == std::vector<uint8_t>{1, 1, 'u', 1, 'p'}));
            wire.sent.clear(); physical->receive({1, 1});
        } else if (mode == "reply-denied") physical->receive({5, 5, 0, 1});
        else if (mode == "reply-invalid") physical->receive({5, 0, 1, 1});
        else if (mode == "reply-address") physical->receive({5, 0, 0, 9});
        else {
            if (mode == "domain") {
                assert(wire.sent.size() == 7 + remote.hostname().size());
                assert(wire.sent[3] == 3 && wire.sent[4] == 13);
                assert(std::string(wire.sent.begin() + 5, wire.sent.end() - 2) == "relay.invalid");
            } else if (mode == "ipv6") assert(wire.sent.size() == 22 && wire.sent[3] == 4 && wire.sent[19] == 1);
            wire.sent.clear();
            physical->receive({5, 0, 0, 3, 1, 'x', 0});
            assert(socket->GetState() == rtc::Socket::CS_CONNECTING);
            // Coalesced first tunneled bytes must survive the handshake parser.
            physical->receive({1, 'a', 'b', 'c'});
            assert(socket->GetState() == rtc::Socket::CS_CONNECTED);
            char bytes[3]{}; int64_t time;
            assert(socket->Recv(bytes, 3, &time) == 3 && std::string(bytes, 3) == "abc");
            assert(socket->Send("media", 5) == 1); // Preserve partial-write semantics.
            socket->Close();
        }
    }
    assert(socket->GetState() == rtc::Socket::CS_CLOSED);
    assert(wire.connects == 1); // Failure never connects to the remote endpoint.
    socket.reset(); assert(wire.destroyed == 1);
}
int main(int argc, char **argv) {
    assert(argc == 2);
    rtc::LogMessage::LogToDebug(rtc::LS_NONE);
    rtc::AutoThread thread;
    rtc::PhysicalSocketServer server;
    rtc::BasicPacketSocketFactory packets(&server);
    rtc::IPAddress ip; assert(rtc::IPFromString("127.0.0.1", &ip));
    rtc::Network network("loopback", "synthetic", ip, 8);
    network.AddIP(ip);
    cricket::ProtocolAddress address(rtc::SocketAddress("127.0.0.2", 8443), cricket::PROTO_TCP);
    cricket::RelayServerConfig config;
    config.credentials.username = "reflector";
    config.credentials.password = "00112233445566778899aabbccddeeff";
    cricket::CreateRelayPortArgs args{};
    args.network_thread = rtc::Thread::Current(); args.socket_factory = &packets;
    args.network = &network; args.server_address = &address; args.config = &config;
    args.username = "synthetic"; args.password = "synthetic-password";
    Factory factory;
    const std::string mode = argv[1];
    if (mode == "domain" || mode == "ipv6" || mode.ends_with("denied") || mode.starts_with("reply-") || mode == "auth-downgrade") {
        boundaries(mode); std::cout << "SOCKS5 " << mode << " passed\n"; return 0;
    }
    if (mode == "packet-proxy") {
        rtc::BasicPacketSocketFactory tcpPackets(&factory);
        rtc::ProxyInfo proxy; proxy.type = rtc::PROXY_SOCKS5;
        proxy.address = rtc::SocketAddress("127.0.0.3", 1080);
        rtc::PacketSocketTcpOptions options;
        auto socket = std::unique_ptr<rtc::AsyncPacketSocket>(tcpPackets.CreateClientTcpSocket(
            rtc::SocketAddress(ip, 0), address.address, proxy, "synthetic", options));
        assert(socket && factory.wire.destination == proxy.address);
        factory.socket->connected(); assert((factory.wire.sent == std::vector<uint8_t>{5, 1, 0}));
        socket.reset(); assert(factory.wire.destroyed == 1);
        std::cout << "Ordinary TCP factory uses SOCKS5\n"; return 0;
    }
    factory.failCreate = mode == "teardown-null";
    factory.wire.failConnect = mode == "teardown-connect";
    auto port = tgcalls::ReflectorPort::Create(args, &factory, uint16_t(0), uint16_t(0), 1, 0, false, 0);
    assert(port);
    if (mode.starts_with("proxy")) {
        rtc::ProxyInfo proxy; proxy.type = rtc::PROXY_SOCKS5;
        proxy.address = rtc::SocketAddress("127.0.0.3", 1080);
        const bool authenticated = mode == "proxy-auth";
        if (authenticated) { proxy.username = "u"; proxy.password = rtc::CryptString(Password{}); }
        factory.wire.writeLimit = 1; // Every handshake send is a partial write.
        port->set_proxy("synthetic", proxy);
        port->PrepareAddress();
        assert(factory.wire.destination == proxy.address);
        factory.socket->connected();
        assert((factory.wire.sent == std::vector<uint8_t>{5, 1, uint8_t(authenticated ? 2 : 0)}));
        factory.wire.sent.clear();
        factory.socket->receive({5}); assert(factory.wire.sent.empty());
        factory.socket->receive({uint8_t(authenticated ? 2 : 0)});
        if (authenticated) {
            assert((factory.wire.sent == std::vector<uint8_t>{1, 1, 'u', 1, 'p'}));
            factory.wire.sent.clear(); factory.socket->receive({1});
            assert(factory.wire.sent.empty()); factory.socket->receive({0});
        }
        assert((factory.wire.sent == std::vector<uint8_t>{5, 1, 0, 1, 127, 0, 0, 2, 0x20, 0xfb}));
        factory.wire.sent.clear();
        factory.socket->receive({5, 0, 0, 1, 127, 0, 0});
        assert(port->socket()->GetState() == rtc::AsyncPacketSocket::STATE_CONNECTING);
        factory.socket->receive({1, 0, 1});
        assert(port->socket()->GetState() == rtc::AsyncPacketSocket::STATE_CONNECTED);
        assert(factory.wire.connects == 1);
        // Native RawTcpSocket prologue follows CONNECT, never before it.
        assert(!factory.wire.sent.empty());
    } else {
        port->PrepareAddress();
        assert(factory.failCreate || factory.wire.destination == address.address);
    }
    port.reset();
    assert(factory.wire.destroyed == (factory.failCreate ? 0 : 1));
    std::cout << "Native reflector " << mode << " passed\n";
}
