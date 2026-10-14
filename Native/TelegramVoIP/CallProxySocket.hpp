// SPDX-License-Identifier: MIT
#pragma once
#include "rtc_base/async_socket.h"
#include "rtc_base/proxy_info.h"
#include "rtc_base/zero_memory.h"
#include "api/task_queue/pending_task_safety_flag.h"
#include <algorithm>
#include <array>
#include <cstring>
#include <vector>

namespace makosh {
// RFC 1928 CONNECT + RFC 1929 authentication. Owned by the native packet
// socket; no alternate endpoint, UDP association, logging, or retry path.
class CallSocks5Socket final : public rtc::AsyncSocketAdapter {
public:
    CallSocks5Socket(rtc::Socket *socket, const rtc::ProxyInfo &proxy)
        : AsyncSocketAdapter(socket), proxy_(proxy) {}
    ~CallSocks5Socket() override { clearOutput(); }
    int Connect(const rtc::SocketAddress &destination) override {
        const bool credentials = !proxy_.username.empty() || proxy_.password.GetLength();
        if (state_ != State::Idle || !proxy_.address.port() || !destination.port() ||
            destination.hostname().size() > 255 ||
            (credentials && (proxy_.username.empty() || proxy_.username.size() > 255 ||
                             !proxy_.password.GetLength() || proxy_.password.GetLength() > 255))) {
            SetError(EINVAL); return -1;
        }
        destination_ = destination;
        state_ = State::Connecting;
        return AsyncSocketAdapter::Connect(proxy_.address);
    }
    rtc::SocketAddress GetRemoteAddress() const override { return destination_; }
    ConnState GetState() const override {
        return state_ == State::Tunnel ? CS_CONNECTED :
            state_ == State::Closed || state_ == State::Idle ? CS_CLOSED : CS_CONNECTING;
    }
    int Send(const void *data, size_t size) override {
        if (state_ != State::Tunnel) { SetError(EWOULDBLOCK); return -1; }
        return AsyncSocketAdapter::Send(data, size);
    }
    int SendTo(const void *, size_t, const rtc::SocketAddress &) override { SetError(EACCES); return -1; }
    int Recv(void *data, size_t size, int64_t *timestamp) override {
        if (state_ != State::Tunnel) { SetError(EWOULDBLOCK); return -1; }
        if (inputSize_) {
            const size_t count = std::min(size, inputSize_);
            std::memcpy(data, input_.data(), count); consume(count);
            if (timestamp) *timestamp = -1;
            return int(count);
        }
        return AsyncSocketAdapter::Recv(data, size, timestamp);
    }
    int Close() override {
        state_ = State::Closed; clearOutput(); inputSize_ = 0;
        proxy_.password.Clear(); proxy_.username.clear();
        return AsyncSocketAdapter::Close();
    }
protected:
    void OnConnectEvent(rtc::Socket *) override {
        if (state_ != State::Connecting) return;
        const uint8_t method = proxy_.username.empty() ? 0 : 2;
        state_ = State::Method; output_ = {5, 1, method}; flush();
    }
    void OnWriteEvent(rtc::Socket *) override {
        if (state_ == State::Tunnel) { SignalWriteEvent(this); return; }
        flush();
    }
    void OnCloseEvent(rtc::Socket *, int error) override { fail(error ? error : ECONNRESET); }
    void OnReadEvent(rtc::Socket *) override {
        if (state_ == State::Tunnel) { SignalReadEvent(this); return; }
        if (state_ == State::Closed || state_ == State::Idle) return;
        if (inputSize_ == input_.size()) { fail(EPROTO); return; }
        int64_t timestamp;
        const int count = AsyncSocketAdapter::Recv(input_.data() + inputSize_, input_.size() - inputSize_, &timestamp);
        if (count <= 0) {
            if (count == 0 || !rtc::IsBlockingError(GetError())) fail(ECONNRESET);
            return;
        }
        inputSize_ += size_t(count);
        process();
    }
private:
    enum class State { Idle, Connecting, Method, Authentication, Reply, Tunnel, Closed };
    rtc::ProxyInfo proxy_;
    rtc::SocketAddress destination_;
    State state_ = State::Idle;
    std::array<uint8_t, 1024> input_{};
    size_t inputSize_ = 0, outputOffset_ = 0;
    std::vector<uint8_t> output_;
    webrtc::ScopedTaskSafety safety_;
    void clearOutput() {
        if (!output_.empty()) rtc::ExplicitZeroMemory(output_.data(), output_.size());
        output_.clear(); outputOffset_ = 0;
    }
    void consume(size_t count) {
        inputSize_ -= count;
        std::memmove(input_.data(), input_.data() + count, inputSize_);
    }
    void fail(int error) {
        if (state_ == State::Closed) return;
        Close(); SetError(error); SignalCloseEvent(this, error);
    }
    bool flush() {
        while (outputOffset_ < output_.size()) {
            const int count = AsyncSocketAdapter::Send(output_.data() + outputOffset_, output_.size() - outputOffset_);
            if (count < 0 && rtc::IsBlockingError(GetError())) return true;
            if (count <= 0) { fail(ECONNRESET); return false; }
            outputOffset_ += size_t(count);
        }
        clearOutput();
        return true;
    }
    bool request() {
        output_ = {5, 1, 0};
        const auto ip = destination_.ipaddr();
        if (ip.family() == AF_INET) {
            output_.push_back(1);
            const auto address = ip.ipv4_address();
            const auto *bytes = reinterpret_cast<const uint8_t *>(&address);
            output_.insert(output_.end(), bytes, bytes + 4);
        } else if (ip.family() == AF_INET6) {
            output_.push_back(4);
            const auto address = ip.ipv6_address();
            const auto *bytes = reinterpret_cast<const uint8_t *>(&address);
            output_.insert(output_.end(), bytes, bytes + 16);
        } else {
            const auto host = destination_.hostname();
            if (host.empty() || host.size() > 255) { fail(EINVAL); return false; }
            output_.push_back(3); output_.push_back(uint8_t(host.size()));
            output_.insert(output_.end(), host.begin(), host.end());
        }
        output_.push_back(uint8_t(destination_.port() >> 8));
        output_.push_back(uint8_t(destination_.port()));
        state_ = State::Reply; return flush();
    }
    void process() {
        // Reject unsolicited replies while our preceding request is incomplete.
        if (!output_.empty()) { fail(EPROTO); return; }
        if (state_ == State::Method) {
            if (inputSize_ < 2) return;
            const uint8_t expected = proxy_.username.empty() ? 0 : 2;
            if (input_[0] != 5 || input_[1] != expected) { fail(EACCES); return; }
            consume(2);
            if (expected == 2) {
                output_ = {1, uint8_t(proxy_.username.size())};
                output_.insert(output_.end(), proxy_.username.begin(), proxy_.username.end());
                output_.push_back(uint8_t(proxy_.password.GetLength()));
                const size_t offset = output_.size();
                output_.resize(offset + proxy_.password.GetLength());
                proxy_.password.CopyTo(reinterpret_cast<char *>(output_.data() + offset), false);
                proxy_.password.Clear(); proxy_.username.clear();
                state_ = State::Authentication;
                if (!flush()) return;
            } else if (!request()) return;
            if (inputSize_) { fail(EPROTO); return; }
        } else if (state_ == State::Authentication) {
            if (inputSize_ < 2) return;
            if (input_[0] != 1 || input_[1] != 0) { fail(EACCES); return; }
            consume(2); if (!request()) return;
            if (inputSize_) { fail(EPROTO); return; }
        } else if (state_ == State::Reply) {
            if (inputSize_ < 4) return;
            if (input_[0] != 5 || input_[1] != 0 || input_[2] != 0) { fail(EACCES); return; }
            size_t length;
            if (input_[3] == 1) length = 10;
            else if (input_[3] == 4) length = 22;
            else if (input_[3] == 3) {
                if (inputSize_ < 5) return;
                if (!input_[4]) { fail(EPROTO); return; }
                length = 7 + input_[4];
            } else { fail(EPROTO); return; }
            if (inputSize_ < length) return;
            consume(length); state_ = State::Tunnel;
            // No member access after an event: a receiver may destroy us.
            if (inputSize_) {
                const auto alive = safety_.flag();
                SignalConnectEvent(this);
                if (alive->alive()) SignalReadEvent(this);
                return;
            }
            SignalConnectEvent(this);
        } else fail(EPROTO);
    }
};
inline rtc::Socket *wrapCallSocks5(rtc::Socket *socket, const rtc::ProxyInfo &proxy) {
    return new CallSocks5Socket(socket, proxy);
}
} // namespace makosh
