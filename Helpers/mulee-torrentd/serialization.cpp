#include "session.hpp"

// Boost.JSON is compiled exactly once; no Boost binary library is linked.
#include <boost/json/src.hpp>
#include <algorithm>
#include <libtorrent/peer_info.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>

namespace mulee {
std::vector<lt::download_priority_t> priorities(const json::value& value, int file_count) {
    if (!value.is_array() || value.as_array().size() != static_cast<std::size_t>(file_count))
        throw RequestError("invalid_params", "Priorities length must equal file count");
    std::vector<lt::download_priority_t> result;
    for (const auto& priority : value.as_array()) {
        if (!priority.is_int64() || priority.as_int64() < 0 || priority.as_int64() > 7)
            throw RequestError("invalid_params", "Priority must be an integer from 0 to 7");
        result.emplace_back(static_cast<std::uint8_t>(priority.as_int64()));
    }
    return result;
}

json::array serialize_files(const Torrent& torrent) {
    json::array result;
    auto info = torrent.handle.torrent_file();
    if (!info) return result;
    auto priorities = torrent.handle.get_file_priorities();
    std::vector<std::int64_t> progress;
    torrent.handle.file_progress(progress);
    const auto& files = info->files();
    for (auto index : files.file_range()) {
        auto i = static_cast<int>(index);
        result.push_back(json::object{{"index", i}, {"path", files.file_path(index)},
            {"size", files.file_size(index)}, {"done", progress.at(i)},
            {"priority", static_cast<std::uint8_t>(priorities.at(i))}});
    }
    return result;
}

void Session::sample_diagnostics(Torrent& torrent) {
    auto now = std::chrono::steady_clock::now();
    if (now - torrent.last_diagnostics < std::chrono::seconds(1)) return;
    torrent.last_diagnostics = now;
    std::vector<lt::peer_info> peers;
    torrent.handle.get_peer_info(peers);
    int tracker = 0, dht = 0, pex = 0, lsd = 0, incoming = 0;
    int ipv4 = 0, ipv6 = 0, tcp = 0, utp = 0, connected = 0;
    for (const auto& peer : peers) {
        if (peer.flags & (lt::peer_info::connecting | lt::peer_info::handshake)) continue;
        ++connected;
        tracker += bool(peer.source & lt::peer_info::tracker);
        dht += bool(peer.source & lt::peer_info::dht);
        pex += bool(peer.source & lt::peer_info::pex);
        lsd += bool(peer.source & lt::peer_info::lsd);
        incoming += bool(peer.source & lt::peer_info::incoming);
        if (peer.ip.address().is_v4()) ++ipv4;
        else if (peer.ip.address().is_v6()) ++ipv6;
        if (peer.flags & lt::peer_info::utp_socket) ++utp;
        else ++tcp;
    }
    int available = 0, failed = 0, pending = 0;
    for (const auto& entry : torrent.handle.trackers()) {
        bool working = false, failure = false;
        for (const auto& endpoint : entry.endpoints) {
            for (const auto& hash : endpoint.info_hashes) {
                working = working || (hash.start_sent && !hash.last_error && hash.fails == 0);
                failure = failure || bool(hash.last_error) || hash.fails > 0;
            }
        }
        if (working) ++available;
        else if (failure) ++failed;
        else ++pending;
    }
    // Session-wide pressure, sampled by the existing one-second stats request.
    // A merely nonempty queue is normal: backlog requires blocked peers or the
    // configured write high-water mark. Null means no stats sample yet.
    json::value backlog = disk_stats_available_
        ? json::value(disk_blocked_peers_ > 0 || queued_disk_bytes_ >= disk_cache_bytes_) : json::value(nullptr);
    torrent.diagnostics = {{"connected_peers", connected},
        {"peer_sources", json::object{{"tracker", tracker}, {"dht", dht}, {"pex", pex}, {"lsd", lsd}, {"incoming", incoming}}},
        {"ipv4", ipv4}, {"ipv6", ipv6}, {"tcp", tcp}, {"utp", utp},
        {"trackers_available", available}, {"trackers_failed", failed}, {"trackers_pending", pending},
        {"last_tracker_error", torrent.last_tracker_error.empty() ? json::value(nullptr) : json::value(torrent.last_tracker_error)},
        {"disk_backlogged", backlog}, {"queued_disk_bytes", queued_disk_bytes_},
        {"disk_blocked_peers", disk_blocked_peers_}, {"disk_queue_limit", disk_cache_bytes_}};
}

json::object serialize_torrent(const std::string& id, const Torrent& torrent) {
    auto status = torrent.handle.status();
    auto info = torrent.handle.torrent_file();
    auto priorities = torrent.handle.get_file_priorities();
    bool paused = bool(status.flags & lt::torrent_flags::paused);
    bool managed = bool(status.flags & lt::torrent_flags::auto_managed);
    bool queued = paused && managed;
    // Auto-managed pauses are queue state, not a user's pause.
    bool user_paused = paused && !managed;
    std::string state;
    if (status.errc) state = "error";
    else if (status.state == lt::torrent_status::checking_files
        || status.state == lt::torrent_status::checking_resume_data) state = "checking";
    else if (!status.has_metadata) state = "metadata";
    else if (status.is_finished) state = paused ? "finished" : "seeding";
    else state = "downloading";
    json::value content_path = nullptr;
    if (info && info->num_files() > 0) {
        auto path = fs::path(info->files().file_path(lt::file_index_t{0}));
        auto top = path.begin();
        content_path = (fs::path(status.save_path) / (path.has_parent_path() ? *top : path)).string();
    }
    json::value eta = nullptr;
    if (status.has_metadata && status.download_payload_rate > 0 && !status.is_finished)
        eta = (status.total_wanted - status.total_wanted_done) / status.download_payload_rate;
    int selected = static_cast<int>(std::count_if(priorities.begin(), priorities.end(),
        [](lt::download_priority_t priority) { return priority != lt::dont_download; }));
    auto diagnostics = torrent.diagnostics;
    diagnostics["blocked_clients_count"] = torrent.blocked_count->load(std::memory_order_relaxed);
    json::value error = status.errc ? json::value(status.errc.message()) : json::value(nullptr);
    return {{"id", id}, {"name", status.name.empty() ? id : status.name},
        {"save_path", status.save_path}, {"content_path", content_path},
        {"is_finished", status.has_metadata && status.is_finished
            && status.state != lt::torrent_status::checking_files
            && status.state != lt::torrent_status::checking_resume_data && !status.errc},
        {"sequential_download", torrent.metadata.sequential_download},
        {"first_last_priority", torrent.metadata.first_last_priority},
        {"skipped_files", torrent.metadata.skipped_files},
        // finished_duration 包含选择性下载完成后的做种时间，seeding_duration 不包含。
        {"seed_time_seconds", status.finished_duration.count()},
        {"seed_inactive_seconds", torrent.metadata.seed_inactive_seconds},
        {"max_connections", torrent.handle.max_connections()}, {"diagnostics", diagnostics},
        {"has_metadata", status.has_metadata}, {"state", state}, {"paused", user_paused}, {"queued", queued},
        {"total_wanted", status.has_metadata ? status.total_wanted : 0},
        {"total_wanted_done", status.total_wanted_done},
        {"progress", status.has_metadata ? static_cast<double>(status.progress) : 0.0},
        {"download_rate", status.download_payload_rate}, {"upload_rate", status.upload_payload_rate},
        {"all_time_download", status.all_time_download}, {"all_time_upload", status.all_time_upload},
        {"ratio", static_cast<double>(status.all_time_upload) / std::max<std::int64_t>(status.total_wanted_done, 1)},
        {"num_peers", status.num_peers}, {"num_seeds", status.num_seeds},
        {"list_peers", status.list_peers}, {"list_seeds", status.list_seeds},
        {"file_count", info ? info->num_files() : 0}, {"selected_file_count", selected},
        {"is_private", info ? info->priv() : false}, {"upload_limit", std::max(0, torrent.handle.upload_limit())},
        {"error", error}, {"source", torrent.metadata.source}, {"added_at", torrent.metadata.added_at},
        {"completed_at", torrent.metadata.completed_at}, {"eta", eta}};
}
}
