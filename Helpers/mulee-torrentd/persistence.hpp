#pragma once

#include "protocol.hpp"
#include <filesystem>
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/session_params.hpp>
#include <string>
#include <vector>

namespace mulee {
namespace lt = libtorrent;
namespace fs = std::filesystem;

struct Metadata {
    json::value source = nullptr;
    std::int64_t added_at = 0;
    json::value completed_at = nullptr;
    bool sequential_download = false;
    bool first_last_priority = false;
};

std::string torrent_id(const lt::info_hash_t& hashes);
std::int64_t unix_time();

class Persistence {
public:
    explicit Persistence(fs::path directory);
    ~Persistence();
    Persistence(const Persistence&) = delete;
    Persistence& operator=(const Persistence&) = delete;
    bool locked() const;
    void log(const std::string& message);
    std::vector<lt::add_torrent_params> restore();
    Metadata load_meta(const std::string& id);
    void save_meta(const std::string& id, const Metadata& metadata);
    void save_resume(const std::string& id, const lt::add_torrent_params& params);
    void remove(const std::string& id);
    lt::session_params load_dht();
    void save_dht(const lt::session_params& params);

private:
    fs::path directory_;
    int lock_fd_ = -1;
    bool locked_ = false;
    void atomic_write(const fs::path& destination, const char* data, std::size_t size);
};
}
