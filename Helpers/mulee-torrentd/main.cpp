#include "session.hpp"
#include "fake_dns.hpp"

#include <csignal>
#include <cstdlib>
#include <iostream>

namespace {
volatile std::sig_atomic_t interrupted = 0;
void signal_handler(int) {
    interrupted = 1;
}
}

int main(int argc, char** argv) {
    setenv("LANG", "en_US.UTF-8", 1);
    setenv("LC_ALL", "en_US.UTF-8", 1);
    std::signal(SIGPIPE, SIG_IGN);
    std::signal(SIGTERM, signal_handler);
    std::signal(SIGINT, signal_handler);
    mulee::Protocol protocol;
    try {
        if (argc == 2 && std::string(argv[1]) == "--test-dns") return mulee::test_fake_dns();
        if (argc != 3 || std::string(argv[1]) != "--state-dir")
            throw std::runtime_error("Usage: mulee-torrentd --state-dir <absolute directory>");
        mulee::Persistence persistence(mulee::absolute_path(argv[2]));
        if (!persistence.locked()) {
            protocol.send({{"event", "fatal"}, {"message", "state-dir is already locked by another process"}});
            return 2;
        }
        mulee::install_fake_ip_resolver();
        mulee::Session session(protocol, persistence);
        session.restore();
        protocol.send({{"event", "ready"}, {"version", "0.1.0"}, {"libtorrent", "2.0.15"},
            {"listen_port", session.listen_port()}});
        protocol.start();
        while (!interrupted && !session.stopping()) {
            std::string line;
            while (!interrupted && !session.stopping() && protocol.pop(line)) session.dispatch(line);
            if (protocol.ended()) break;
            session.poll();
        }
        session.shutdown();
        return 0;
    } catch (const std::exception& error) {
        std::cerr << error.what() << '\n';
        protocol.send({{"event", "fatal"}, {"message", error.what()}});
        return 1;
    }
}
