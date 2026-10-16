#pragma once

#include "persistence.hpp"
#include <chrono>
#include <atomic>
#include <mutex>
#include <libtorrent/extensions.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <map>

namespace mulee {
struct ClientRules {
    std::mutex mutex;
    std::vector<std::string> values;
};

struct Torrent {
    lt::torrent_handle handle;
    Metadata metadata;
    std::vector<lt::tcp::endpoint> bootstrap_peers;
    std::shared_ptr<std::atomic<std::int64_t>> blocked_count;
    std::vector<lt::piece_index_t> priority_pieces;
    json::object diagnostics;
    std::string last_tracker_error;
    std::chrono::steady_clock::time_point last_diagnostics{};
};

class Session {
public:
    Session(Protocol& protocol, Persistence& persistence);
    void restore();
    void dispatch(const std::string& line);
    void poll();
    void shutdown();
    bool stopping() const;
    int listen_port() const;

private:
    Protocol& protocol_;
    Persistence& persistence_;
    lt::session_params dht_state_;
    lt::session session_;
    std::shared_ptr<ClientRules> client_rules_ = std::make_shared<ClientRules>();
    std::map<std::string, Torrent> torrents_;
    std::map<lt::torrent_handle, int> pending_resume_;
    std::string download_dir_;
    bool stopping_ = false;
    bool incoming_ = false;
    bool port_mapping_enabled_ = false;
    bool refresh_extra_mappings_ = false;
    struct ExtraMapping {
        std::vector<lt::port_mapping_t> handles;
        json::array results;
    };
    std::map<std::pair<std::string, int>, ExtraMapping> extra_mappings_;
    json::array bt_mappings_;
    json::object set_extra_port_mappings(const json::object& params);
    void update_extra_port_mappings();
    void clear_extra_port_mapping_handles();
    void port_mapping_alert(lt::port_mapping_t handle, lt::portmap_transport transport,
        int external_port, lt::portmap_protocol protocol, const std::string& address,
        const std::string& error);
    std::string external_address_;
    std::int64_t downloaded_ = 0;
    std::int64_t uploaded_ = 0;
    std::int64_t download_rate_ = 0;
    std::int64_t upload_rate_ = 0;
    std::uint64_t stats_generation_ = 0;
    std::int64_t queued_disk_bytes_ = 0;
    std::int64_t disk_blocked_peers_ = 0;
    bool disk_stats_available_ = false;
    int disk_cache_bytes_ = 16 * 1024 * 1024;
    std::chrono::steady_clock::time_point last_stats_ = std::chrono::steady_clock::now();
    std::chrono::steady_clock::time_point last_stats_request_ = last_stats_;
    std::map<std::string, int> dht_nodes_;
    std::chrono::steady_clock::time_point last_save_ = std::chrono::steady_clock::now();
    json::object execute(const std::string& method, const json::object& params);
    json::object configure(const json::object& params);
    json::object add(const json::object& params);
    json::object session_status();
    Torrent& find(const json::object& params);
    Torrent* find(const lt::torrent_handle& handle);
    void alerts();
    void save_all(bool final);
    void save(Torrent& torrent, bool final = false);
    void mark_completed(Torrent& torrent);
    void prepare(lt::add_torrent_params& params, const std::shared_ptr<std::atomic<std::int64_t>>& count);
    void apply_download_mode(Torrent& torrent);
    json::object add_trackers(Torrent& torrent, const json::object& params);
    void sample_diagnostics(Torrent& torrent);
};

json::object serialize_torrent(const std::string& id, const Torrent& torrent);
json::array serialize_files(const Torrent& torrent);
std::vector<lt::download_priority_t> priorities(const json::value& value, int file_count);
}
