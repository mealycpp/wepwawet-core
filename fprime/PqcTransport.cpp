#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <limits>
#include <string>
#include "PqcTransport/PqcTransport.hpp"

#include <sys/socket.h>
#include <sys/select.h>
#include <sys/time.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <cerrno>
#include <cstring>
#include <cstdio>
#include <array>
#include <vector>
#include <fstream>
#include <chrono>

namespace Wepwawet {

static constexpr int PORT = 9091;
static constexpr char REQUEST[]  = "WCORE-PING-V1";
static constexpr char RESPONSE[] = "WCORE-PONG-V1";

static bool nodeAddress(const char*& local, const char*& peer) {
    char hostname[128] = {};
    if (gethostname(hostname, sizeof(hostname) - 1) != 0)
        return false;

    if (std::strcmp(hostname, "aup1") == 0) {
        local = "<AUP1_IP>";
        peer  = "<AUP2_IP>";
        return true;
    }

    if (std::strcmp(hostname, "aup2") == 0) {
        local = "<AUP2_IP>";
        peer  = "<AUP1_IP>";
        return true;
    }

    return false;
}

static void socketTimeout(int fd) {
    timeval timeout = {2, 0};
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof(timeout));
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, sizeof(timeout));
}

static bool sendExact(int fd, const char* data, size_t size) {
    size_t done = 0;
    while (done < size) {
        ssize_t n = send(fd, data + done, size - done, MSG_NOSIGNAL);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            return false;
        }
        done += static_cast<size_t>(n);
    }
    return true;
}

static bool recvExact(int fd, char* data, size_t size) {
    size_t done = 0;
    while (done < size) {
        ssize_t n = recv(fd, data + done, size - done, 0);
        if (n <= 0) {
            if (n < 0 && errno == EINTR) continue;
            return false;
        }
        done += static_cast<size_t>(n);
    }
    return true;
}

PqcTransport::PqcTransport(const char* const name)
    : PqcTransportComponentBase(name),
      m_connectionCount(0),
      m_bytesSent(0),
      m_bytesRecv(0),
      m_running(true),
      m_listener(&PqcTransport::listenerLoop, this) {}

PqcTransport::~PqcTransport() {
    m_running.store(false);
    if (m_listener.joinable())
        m_listener.join();
}

void PqcTransport::listenerLoop() {
    const char* local = nullptr;
    const char* peer = nullptr;

    if (!nodeAddress(local, peer)) {
        std::fprintf(stderr, "WCORE: unknown board hostname\n");
        return;
    }

    int server = socket(AF_INET, SOCK_STREAM, 0);
    if (server < 0) return;

    int reuse = 1;
    setsockopt(server, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    sockaddr_in address = {};
    address.sin_family = AF_INET;
    address.sin_port = htons(PORT);
    inet_pton(AF_INET, local, &address.sin_addr);

    if (bind(server, reinterpret_cast<sockaddr*>(&address),
             sizeof(address)) != 0 || listen(server, 4) != 0) {
        std::perror("WCORE: listener setup");
        close(server);
        return;
    }

    std::fprintf(stderr, "WCORE: listening on %s:%d\n", local, PORT);

    while (m_running.load()) {
        fd_set ready;
        FD_ZERO(&ready);
        FD_SET(server, &ready);

        timeval timeout = {0, 250000};
        int result = select(server + 1, &ready, nullptr, nullptr, &timeout);
        if (result <= 0) continue;

        sockaddr_in remote = {};
        socklen_t remoteLength = sizeof(remote);
        int client = accept(server,
                            reinterpret_cast<sockaddr*>(&remote),
                            &remoteLength);
        if (client < 0) continue;

        socketTimeout(client);

        // Framing: 4-byte big-endian message length,
        // message bytes, then 2420-byte ML-DSA signature.
        // The message itself must contain signed identity,
        // destination, version, and sequence information.
        constexpr size_t PK_SIZE = 1312;
        constexpr size_t SIG_SIZE = 2420;
        constexpr size_t MAX_MESSAGE = 4096;

        U8 lengthBytes[4] = {};
        bool valid = remote.sin_addr.s_addr == inet_addr(peer);
        bool received = valid &&
            recvExact(client, reinterpret_cast<char*>(lengthBytes), 4);

        U32 length =
            (static_cast<U32>(lengthBytes[0]) << 24) |
            (static_cast<U32>(lengthBytes[1]) << 16) |
            (static_cast<U32>(lengthBytes[2]) << 8) |
             static_cast<U32>(lengthBytes[3]);

        bool accepted = false;

        if (received && length > 0 && length <= MAX_MESSAGE) {
            std::vector<U8> message(length);
            std::array<U8, SIG_SIZE> signature{};
            std::array<U8, PK_SIZE> publicKey{};

            bool complete =
                recvExact(client,
                          reinterpret_cast<char*>(message.data()),
                          message.size()) &&
                recvExact(client,
                          reinterpret_cast<char*>(signature.data()),
                          signature.size());

            std::ifstream key(
                "/home/xilinx/wepwawet-core/firmware/identity/"
                "trusted_peer_pk.bin",
                std::ios::binary);

            bool trustedKeyLoaded =
                static_cast<bool>(key.read(
                    reinterpret_cast<char*>(publicKey.data()),
                    publicKey.size()));

            if (trustedKeyLoaded) {
                trustedKeyLoaded =
                    key.peek() == std::char_traits<char>::eof();
            }

            if (complete && trustedKeyLoaded &&
                this->isConnected_authOut_OutputPort(0)) {

                Fw::Buffer pkBuf(publicKey.data(), publicKey.size());
                Fw::Buffer msgBuf(message.data(), message.size());
                Fw::Buffer sigBuf(signature.data(), signature.size());

                U8 verdict = 0;
                this->authOut_out(
                    0, pkBuf, msgBuf, sigBuf, verdict);

                accepted = verdict == 1;
            }
        }

        const char reply = accepted ? 'A' : 'R';
        sendExact(client, &reply, 1);

        std::fprintf(stderr,
                     "WCORE: authenticated receive verdict=%s\\n",
                     accepted ? "ACCEPT" : "REJECT");

        close(client);
    }

    close(server);
}

// WCORE_AUTHENTICATED_PEER_PING
// Root-owned persistent counter; increment-and-fsync before signing/sending.
static bool takeSendSequence(U64& seq) {
    int fd = open("/var/lib/wepwawet-core/send_sequence",
                  O_RDWR | O_NOFOLLOW | O_CLOEXEC);
    if (fd < 0) return false;
    if (flock(fd, LOCK_EX) != 0) { close(fd); return false; }
    bool ok = false;
    do {
        struct stat st {};
        if (fstat(fd, &st) != 0 || !S_ISREG(st.st_mode) ||
            st.st_uid != 0 || (st.st_mode & (S_IWGRP | S_IWOTH)) ||
            st.st_size < 2 || st.st_size > 21) break;
        char buf[32] = {};
        ssize_t n = pread(fd, buf, st.st_size, 0);
        if (n != st.st_size || buf[n - 1] != '\n') break;
        U64 value = 0;
        bool valid = true;
        for (ssize_t i = 0; i < n - 1; ++i) {
            if (buf[i] < '0' || buf[i] > '9') { valid = false; break; }
            const U64 digit = static_cast<U64>(buf[i] - '0');
            if (value > (std::numeric_limits<U64>::max() - digit) / 10) {
                valid = false; break;
            }
            value = value * 10 + digit;
        }
        if (!valid || value == std::numeric_limits<U64>::max()) break;
        seq = value + 1;
        const std::string next = std::to_string(seq) + "\n";
        if (pwrite(fd, next.data(), next.size(), 0) !=
            static_cast<ssize_t>(next.size())) break;
        if (ftruncate(fd, next.size()) != 0 || fsync(fd) != 0) break;
        ok = true;
    } while (false);
    flock(fd, LOCK_UN);
    close(fd);
    return ok;
}

void PqcTransport::PeerPing_cmdHandler(FwOpcodeType opCode, U32 cmdSeq) {
    const char* local = nullptr;
    const char* peer = nullptr;
    if (!nodeAddress(local, peer) || !this->isConnected_signOut_OutputPort(0)) {
        this->log_WARNING_HI_PeerError(Fw::String("Invalid node or signer unavailable"));
        this->cmdResponse_out(opCode, cmdSeq, Fw::CmdResponse::EXECUTION_ERROR);
        return;
    }

    char hostname[128] = {};
    if (gethostname(hostname, sizeof(hostname)-1) != 0) {
        this->cmdResponse_out(opCode, cmdSeq, Fw::CmdResponse::EXECUTION_ERROR);
        return;
    }
    const std::string sender = std::strcmp(hostname,"aup1") == 0 ? "AUP1" : "AUP2";
    const std::string target = sender == "AUP1" ? "AUP2" : "AUP1";
    U64 sequence = 0;
    if (!takeSendSequence(sequence)) {
        this->log_WARNING_HI_PeerError(Fw::String("Send sequence unavailable"));
        this->cmdResponse_out(opCode, cmdSeq, Fw::CmdResponse::EXECUTION_ERROR);
        return;
    }

    // Signed envelope includes protocol version, sender, destination and sequence.
    const std::string message = "WCORE-V1|" + sender + "|" + target +
        "|SEQ=" + std::to_string(sequence) + "|PeerPing";
    std::array<U8,2560> secret{};
    std::array<U8,2420> signature{};
    bool haveSecret = false;
    {
        std::ifstream in("/home/xilinx/wepwawet-core/firmware/identity/node_sk.bin",
                         std::ios::binary);
        // seal_v8: with the key sealed in the PL the operator removes node_sk.bin; then no secret is read here and an
        // empty buffer is passed (HwAccelMgr signs with the sealed key and never reads skBuffer on a v8 image).
        if (in.is_open() && (!in.read(reinterpret_cast<char*>(secret.data()), secret.size()) ||
            in.peek() != std::char_traits<char>::eof())) {
            this->log_WARNING_HI_PeerError(Fw::String("Signing key unavailable"));
            this->cmdResponse_out(opCode, cmdSeq, Fw::CmdResponse::EXECUTION_ERROR);
            return;
        }
        haveSecret = in.is_open();
    }

    Fw::Buffer secretBuf(secret.data(), haveSecret ? secret.size() : 0);
    Fw::Buffer msgBuf(reinterpret_cast<U8*>(const_cast<char*>(message.data())),
                      message.size());
    Fw::Buffer sigBuf(signature.data(), signature.size());
    this->signOut_out(0, secretBuf, msgBuf, sigBuf);
    // Clear local secret copy once signing returns.
    volatile U8* wipe = secret.data();
    for (size_t i = 0; i < secret.size(); ++i) wipe[i] = 0;
    if (sigBuf.getSize() != signature.size()) {
        this->log_WARNING_HI_PeerError(Fw::String("F-prime signing failed"));
        this->cmdResponse_out(opCode, cmdSeq, Fw::CmdResponse::EXECUTION_ERROR);
        return;
    }

    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        this->cmdResponse_out(opCode, cmdSeq, Fw::CmdResponse::EXECUTION_ERROR);
        return;
    }
    socketTimeout(fd);
    sockaddr_in address = {};
    address.sin_family = AF_INET;
    address.sin_port = htons(PORT);
    inet_pton(AF_INET, peer, &address.sin_addr);
    const U32 len = static_cast<U32>(message.size());
    const char prefix[4] = {
        static_cast<char>((len >> 24) & 255),
        static_cast<char>((len >> 16) & 255),
        static_cast<char>((len >> 8) & 255),
        static_cast<char>(len & 255)
    };
    char response = 0;
    const bool connected = connect(fd, reinterpret_cast<sockaddr*>(&address),
                                   sizeof(address)) == 0;
    const bool success = connected && sendExact(fd, prefix, 4) &&
        sendExact(fd, message.data(), message.size()) &&
        sendExact(fd, reinterpret_cast<const char*>(signature.data()),
                  signature.size()) &&
        recvExact(fd, &response, 1) && response == 'A';
    close(fd);
    if (!success) {
        this->log_WARNING_HI_PeerError(Fw::String("Authenticated peer exchange failed"));
        this->cmdResponse_out(opCode, cmdSeq, Fw::CmdResponse::EXECUTION_ERROR);
        return;
    }
    m_connectionCount++;
    m_bytesSent += 4 + message.size() + signature.size();
    m_bytesRecv++;
    this->tlmWrite_ConnectionCount(m_connectionCount);
    this->tlmWrite_BytesSent(m_bytesSent);
    this->tlmWrite_BytesRecv(m_bytesRecv);
    this->log_ACTIVITY_HI_PeerConnected(Fw::String(peer));
    this->cmdResponse_out(opCode, cmdSeq, Fw::CmdResponse::OK);
}

} // namespace Wepwawet
