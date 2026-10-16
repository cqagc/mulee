#include "session.hpp"
#include "fake_dns.hpp"

#include <algorithm>
#include <cctype>
#include <libtorrent/peer_connection_handle.hpp>
#include <libtorrent/bdecode.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/ip_filter.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/session_stats.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>

namespace mulee {
namespace {
lt::settings_pack defaults() {
    lt::settings_pack settings;
    settings.set_str(lt::settings_pack::user_agent, "Mulee/0.1.0 libtorrent/2.0.15");
    settings.set_str(lt::settings_pack::peer_fingerprint, "-MU0100-");
    // Only bound the best-effort tracker stopped announce. Resume data and disk
    // cache are still flushed and acknowledged before session destruction.
    settings.set_int(lt::settings_pack::stop_tracker_timeout, 1);
    // Bound socket/file pressure while allowing several active swarms.
    settings.set_int(lt::settings_pack::connections_limit, 500);
    settings.set_int(lt::settings_pack::file_pool_size, 100);
    // Spread discovery across tiers without simultaneously flooding every URL.
    settings.set_bool(lt::settings_pack::announce_to_all_tiers, true);
    settings.set_bool(lt::settings_pack::announce_to_all_trackers, false);
    // Keep upload useful per peer instead of dividing bandwidth into tiny slots.
    settings.set_int(lt::settings_pack::unchoke_slots_limit, 16);
    settings.set_int(lt::settings_pack::max_queued_disk_bytes, 16 * 1024 * 1024);
    settings.set_str(lt::settings_pack::listen_interfaces, "0.0.0.0:0,[::]:0");
    settings.set_bool(lt::settings_pack::listen_system_port_fallback, true);
    settings.set_bool(lt::settings_pack::enable_incoming_utp, true);
    settings.set_bool(lt::settings_pack::enable_outgoing_utp, true);
    settings.set_bool(lt::settings_pack::enable_incoming_tcp, true);
    settings.set_bool(lt::settings_pack::enable_outgoing_tcp, true);
    // Do not contact the network until the parent supplies its settings.
    settings.set_bool(lt::settings_pack::enable_dht, false);
    settings.set_bool(lt::settings_pack::enable_lsd, false);
    settings.set_bool(lt::settings_pack::enable_upnp, false);
    settings.set_bool(lt::settings_pack::enable_natpmp, false);
    settings.set_int(lt::settings_pack::alert_mask, static_cast<std::uint32_t>(lt::alert_category::status
        | lt::alert_category::error | lt::alert_category::storage | lt::alert_category::tracker
        | lt::alert_category::port_mapping));
    return settings;
}

lt::session_params startup(lt::session_params params) {
    params.settings = defaults();
    return params;
}

std::string lowercase(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(),
        [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return value;
}

class ClientPeer final : public lt::peer_plugin {
public:
    ClientPeer(lt::peer_connection_handle peer, std::shared_ptr<ClientRules> rules,
        std::shared_ptr<std::atomic<std::int64_t>> count)
        : peer_(std::move(peer)), rules_(std::move(rules)), count_(std::move(count)) {}

    bool on_handshake(lt::span<char const>) override {
        handshaken_ = true;
        check("");
        return true;
    }

    bool on_extension_handshake(const lt::bdecode_node& node) override {
        auto name = node.dict_find_string_value("v");
        client_ = std::string(name.data(), name.size());
        check(client_);
        return true;
    }

    void tick() override {
        // Reconfiguration also applies to connections that already handshook.
        if (handshaken_) check(client_);
    }

private:
    lt::peer_connection_handle peer_;
    std::shared_ptr<ClientRules> rules_;
    std::shared_ptr<std::atomic<std::int64_t>> count_;
    bool handshaken_ = false;
    bool blocked_ = false;
    std::string client_;

    void check(std::string name) {
        if (blocked_ || peer_.is_disconnecting()) return;
        std::lock_guard<std::mutex> lock(rules_->mutex);
        if (rules_->values.empty()) return;
        if (name.empty()) {
            lt::peer_info info;
            peer_.get_peer_info(info);
            name = info.client;
        }
        name = lowercase(std::move(name));
        const auto& id = peer_.pid();
        const std::string prefix(id.data(), id.size());
        for (const auto& rule : rules_->values) {
            bool match = rule.front() == '-' ? prefix.compare(0, rule.size(), rule) == 0
                : name.compare(0, rule.size(), lowercase(rule)) == 0;
            if (!match) continue;
            blocked_ = true;
            count_->fetch_add(1, std::memory_order_relaxed);
            peer_.disconnect(lt::errors::peer_banned, lt::operation_t::bittorrent);
            return;
        }
    }
};

class ClientTorrent final : public lt::torrent_plugin {
public:
    ClientTorrent(std::shared_ptr<ClientRules> rules, std::shared_ptr<std::atomic<std::int64_t>> count)
        : rules_(std::move(rules)), count_(std::move(count)) {}

    std::shared_ptr<lt::peer_plugin> new_connection(const lt::peer_connection_handle& peer) override {
        return std::make_shared<ClientPeer>(peer, rules_, count_);
    }

private:
    std::shared_ptr<ClientRules> rules_;
    std::shared_ptr<std::atomic<std::int64_t>> count_;
};

}

Session::Session(Protocol& protocol, Persistence& persistence)
    : protocol_(protocol), persistence_(persistence), dht_state_(persistence.load_dht()), session_(startup(dht_state_)) {
    // Global limits also apply to LAN and loopback peers. libtorrent's default
    // local peer class bypasses them, which would violate configure's limits.
    lt::ip_filter filter;
    const auto global = 1U << static_cast<std::uint32_t>(lt::session::global_peer_class_id);
    filter.add_rule(lt::make_address("0.0.0.0"), lt::make_address("255.255.255.255"), global);
    filter.add_rule(lt::make_address("::"), lt::make_address("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"), global);
    session_.set_peer_class_filter(filter);
    ip_filters_ = persistence_.load_filters();
    apply_ip_filters(ip_filters_);
}

void Session::prepare(lt::add_torrent_params& params,
    const std::shared_ptr<std::atomic<std::int64_t>>& count) {
    params.max_connections = per_torrent_connections;
    params.extensions.push_back([rules = client_rules_, count](const lt::torrent_handle&, lt::client_data_t) {
        return std::make_shared<ClientTorrent>(rules, count);
    });
}

void Session::apply_download_mode(Torrent& torrent) {
    auto& handle = torrent.handle;
    handle.set_flags(torrent.metadata.sequential_download ? lt::torrent_flags::sequential_download
        : lt::torrent_flags_t{}, lt::torrent_flags::sequential_download);
    for (auto piece : torrent.priority_pieces) handle.reset_piece_deadline(piece);
    torrent.priority_pieces.clear();
    auto info = handle.torrent_file();
    if (!info || (!torrent.metadata.first_last_priority && torrent.metadata.streaming_file < 0)) return;
    auto priorities = handle.get_file_priorities();
    const auto& files = info->files();
    for (auto index : files.file_range()) {
        if (files.pad_file_at(index) || files.file_size(index) == 0
            || priorities.at(static_cast<int>(index)) == lt::dont_download) continue;
        if (torrent.metadata.streaming_file >= 0) {
            if (static_cast<int>(index) != torrent.metadata.streaming_file) continue;
            auto size = files.file_size(index);
            // 开头必须覆盖播放器的 20 MB 或 5% 阈值，避免只加速 2% 后长期等待。
            auto head_bytes = std::min<std::int64_t>(20'000'000, size / 20 + (size % 20 != 0));
            auto tail_bytes = std::max<std::int64_t>(1, size / 50 + (size % 50 != 0));
            auto first = info->map_file(index, 0, 1).piece;
            auto head = info->map_file(index, head_bytes - 1, 1).piece;
            auto tail = info->map_file(index, size - tail_bytes, 1).piece;
            auto last = info->map_file(index, files.file_size(index) - 1, 1).piece;
            for (int piece = static_cast<int>(first); piece <= static_cast<int>(last); ++piece) {
                if (piece > static_cast<int>(head) && piece < static_cast<int>(tail)) continue;
                torrent.priority_pieces.push_back(lt::piece_index_t{piece});
                handle.set_piece_deadline(lt::piece_index_t{piece}, 0);
            }
            continue;
        }
        for (auto offset : {std::int64_t{0}, files.file_size(index) - 1}) {
            auto piece = info->map_file(index, offset, 1).piece;
            if (std::find(torrent.priority_pieces.begin(), torrent.priority_pieces.end(), piece)
                != torrent.priority_pieces.end()) continue;
            torrent.priority_pieces.push_back(piece);
            // Only edge pieces of selected files get deadlines; skipped files stay skipped.
            handle.set_piece_deadline(piece, 0);
        }
    }
}

// 文件进度只计已校验的完整 piece；改名等磁盘操作完成后才发布完成状态。
void Session::update_incomplete_files(Torrent& torrent) {
    if (updating_incomplete_ || stopping_) return;
    auto info = torrent.handle.torrent_file();
    if (!info) return;
    auto status = torrent.handle.status();
    if (status.state == lt::torrent_status::checking_files
        || status.state == lt::torrent_status::checking_resume_data) return;
    updating_incomplete_ = true;
    try {
        std::vector<std::int64_t> done;
        torrent.handle.file_progress(done, lt::torrent_handle::piece_granularity);
        bool changed = false;
        for (auto index : info->files().file_range()) {
            int i = static_cast<int>(index);
            if (info->files().pad_file_at(index)) continue;
            auto current = info->files().file_path(index);
            auto key = std::to_string(i);
            if (torrent.metadata.mark_incomplete && !torrent.metadata.original_paths.contains(key)) {
                torrent.metadata.original_paths[key] = current;
                changed = true;
            }
            auto original = torrent.metadata.original_paths.if_contains(key);
            if (!original) continue;
            std::string logical(original->as_string());
            bool complete = done.at(i) >= info->files().file_size(index);
            auto target = complete ? logical : logical + ".mulee";
            if (target == current) continue;
            if (fs::exists(fs::path(status.save_path) / target))
                throw RequestError("conflict", "Incomplete-file rename destination exists");
            persistence_.save_meta(torrent_id(torrent.handle.info_hashes()), torrent.metadata);
            storage_handle_ = torrent.handle;
            storage_error_.clear();
            storage_error_code_ = "io_error";
            storage_pending_ = 1;
            torrent.handle.rename_file(index, target);
            wait_storage();
            changed = true;
        }
        if (status.is_finished && torrent.metadata.streaming_file >= 0) {
            auto priorities = torrent.handle.get_file_priorities();
            auto index = torrent.metadata.streaming_file;
            if (index < static_cast<int>(priorities.size()) && priorities.at(index) == lt::top_priority) {
                priorities.at(index) = lt::download_priority_t{static_cast<std::uint8_t>(torrent.metadata.streaming_previous_priority)};
                torrent.handle.prioritize_files(priorities);
            }
            torrent.metadata.streaming_file = -1;
            torrent.metadata.sequential_download = false;
            torrent.metadata.first_last_priority = false;
            apply_download_mode(torrent);
            changed = true;
        }
        if (changed) {
            persistence_.save_meta(torrent_id(torrent.handle.info_hashes()), torrent.metadata);
            save(torrent);
        }
    } catch (...) {
        updating_incomplete_ = false;
        throw;
    }
    updating_incomplete_ = false;
}

void Session::restore() {
    for (auto& params : persistence_.restore()) {
        auto id = torrent_id(params.info_hashes);
        auto metadata = persistence_.load_meta(id);
        // meta 与 resume 保存时刻可能不同，以实际存在的后缀文件恢复磁盘映射。
        for (const auto& entry : metadata.original_paths) {
            auto index = lt::file_index_t{std::stoi(std::string(entry.key()))};
            std::string original(entry.value().as_string());
            if (fs::exists(fs::path(params.save_path) / (original + ".mulee")))
                params.renamed_files[index] = original + ".mulee";
            else if (fs::exists(fs::path(params.save_path) / original)) params.renamed_files[index] = original;
        }
        lt::error_code error;
        auto count = std::make_shared<std::atomic<std::int64_t>>(0);
        prepare(params, count);
        auto handle = session_.add_torrent(params, error);
        if (error) {
            persistence_.log("Cannot restore " + id + ": " + error.message());
            continue;
        }
        handle.set_max_connections(per_torrent_connections);
        auto inserted = torrents_.emplace(id, Torrent{handle, metadata, params.peers, count});
        apply_junk_filter(inserted.first->second);
        apply_download_mode(inserted.first->second);
        refresh_trackers(inserted.first->second);
    }
    // Ensure the listener exists before announcing readiness.
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (session_.listen_port() == 0 && std::chrono::steady_clock::now() < deadline) {
        session_.wait_for_alert(std::chrono::milliseconds(50));
        alerts();
    }
}

bool Session::stopping() const {
    return stopping_;
}

int Session::listen_port() const {
    return session_.listen_port();
}

Torrent* Session::find(const lt::torrent_handle& handle) {
    for (auto& entry : torrents_) {
        if (entry.second.handle == handle) return &entry.second;
    }
    return nullptr;
}

void Session::mark_completed(Torrent& torrent) {
    if (torrent.metadata.completed_at.is_null()) {
        torrent.metadata.completed_at = unix_time();
        persistence_.save_meta(torrent_id(torrent.handle.info_hashes()), torrent.metadata);
    }
}

void Session::save(Torrent& torrent, bool final) {
    if (!final && pending_resume_.count(torrent.handle)) return;
    auto flags = lt::torrent_handle::save_info_dict;
    if (final) flags |= lt::torrent_handle::flush_disk_cache;
    torrent.handle.save_resume_data(flags);
    ++pending_resume_[torrent.handle];
}

void Session::save_all(bool final) {
    for (auto& entry : torrents_) save(entry.second, final);
}

void Session::alerts() {
    std::vector<lt::alert*> pending;
    session_.pop_alerts(&pending);
    for (auto* alert : pending) {
        try {
            if (auto* moved = lt::alert_cast<lt::storage_moved_alert>(alert)) {
                if (moved->handle == storage_handle_) storage_pending_ = 0;
            } else if (auto* failed = lt::alert_cast<lt::storage_moved_failed_alert>(alert)) {
                if (failed->handle == storage_handle_) {
                    storage_pending_ = 0;
                    storage_error_ = failed->error.message();
                    storage_error_code_ = failed->error == boost::system::errc::file_exists ? "conflict" : "io_error";
                }
            } else if (auto* renamed = lt::alert_cast<lt::file_renamed_alert>(alert)) {
                if (renamed->handle == storage_handle_) storage_pending_ = 0;
            } else if (auto* failed = lt::alert_cast<lt::file_rename_failed_alert>(alert)) {
                if (failed->handle == storage_handle_) {
                    storage_pending_ = 0;
                    storage_error_ = failed->error.message();
                    storage_error_code_ = failed->error == boost::system::errc::file_exists ? "conflict" : "io_error";
                }
            } else if (auto* saved = lt::alert_cast<lt::save_resume_data_alert>(alert)) {
                auto pending_save = pending_resume_.find(saved->handle);
                if (pending_save != pending_resume_.end() && --pending_save->second == 0)
                    pending_resume_.erase(pending_save);
                // Removed handles can still deliver resume alerts. Never resurrect them.
                if (auto* torrent = find(saved->handle)) {
                    auto id = torrent_id(saved->handle.info_hashes());
                    auto params = saved->params;
                    if (saved->handle == export_handle_) export_resume_ = params;
                    // Keep explicit magnet x.pe hints even if the peer disconnected
                    // during pause/shutdown and libtorrent omitted it from its list.
                    for (const auto& peer : torrent->bootstrap_peers) {
                        if (std::find(params.peers.begin(), params.peers.end(), peer) == params.peers.end())
                            params.peers.push_back(peer);
                    }
                    persistence_.save_resume(id, params);
                    persistence_.save_meta(id, torrent->metadata);
                }
            } else if (auto* failed = lt::alert_cast<lt::save_resume_data_failed_alert>(alert)) {
                auto pending_save = pending_resume_.find(failed->handle);
                if (pending_save != pending_resume_.end() && --pending_save->second == 0)
                    pending_resume_.erase(pending_save);
                if (failed->handle == export_handle_) export_error_ = failed->error.message();
                persistence_.log(failed->message());
                if (stopping_) throw std::runtime_error("Cannot save resume data at shutdown");
            } else if (auto* metadata = lt::alert_cast<lt::metadata_received_alert>(alert)) {
                if (auto* torrent = find(metadata->handle)) {
                    apply_junk_filter(*torrent);
                    protocol_.send({{"event", "metadata_received"}, {"id", torrent_id(metadata->handle.info_hashes())},
                        {"name", metadata->handle.status().name}, {"skipped_files", torrent->metadata.skipped_files}});
                    apply_download_mode(*torrent);
                    save(*torrent);
                }
            } else if (auto* priority = lt::alert_cast<lt::file_prio_alert>(alert)) {
                if (auto* torrent = find(priority->handle)) apply_download_mode(*torrent);
            } else if (auto* finished = lt::alert_cast<lt::torrent_finished_alert>(alert)) {
                if (auto* torrent = find(finished->handle)) {
                    mark_completed(*torrent);
                    protocol_.send({{"event", "finished"}, {"id", torrent_id(finished->handle.info_hashes())}});
                    save(*torrent);
                }
            } else if (auto* error = lt::alert_cast<lt::torrent_error_alert>(alert)) {
                if (find(error->handle)) protocol_.send({{"event", "torrent_error"},
                    {"id", torrent_id(error->handle.info_hashes())}, {"message", error->error.message()}});
                persistence_.log(error->message());
            } else if (auto* error = lt::alert_cast<lt::torrent_delete_failed_alert>(alert)) {
                protocol_.send({{"event", "torrent_error"}, {"id", torrent_id(error->info_hashes)},
                    {"message", error->error.message()}});
                persistence_.log(error->message());
            } else if (auto* error = lt::alert_cast<lt::tracker_error_alert>(alert)) {
                if (auto* torrent = find(error->handle)) {
                    torrent->last_tracker_error = error->error.message() + ": " + error->failure_reason();
                    // 跳过宣告是本机网络接口的决定，不能记成 tracker 连续失败。
                    if (error->error != lt::errors::announce_skipped)
                        tracker_result(*torrent, error->tracker_url(), torrent->last_tracker_error, 0, true);
                }
                persistence_.log(error->message());
            } else if (auto* reply = lt::alert_cast<lt::tracker_reply_alert>(alert)) {
                if (auto* torrent = find(reply->handle))
                    tracker_result(*torrent, reply->tracker_url(), "OK", reply->num_peers, false);
            } else if (auto* mapped = lt::alert_cast<lt::portmap_alert>(alert)) {
                port_mapping_alert(mapped->mapping, mapped->map_transport, mapped->external_port,
                    mapped->map_protocol, mapped->local_address.to_string(), "");
            } else if (auto* failed = lt::alert_cast<lt::portmap_error_alert>(alert)) {
                port_mapping_alert(failed->mapping, failed->map_transport, 0,
                    lt::portmap_protocol::none, failed->local_address.to_string(), failed->error.message());
            } else if (lt::alert_cast<lt::listen_succeeded_alert>(alert)) {
                refresh_extra_mappings_ = true;
            } else if (auto* external = lt::alert_cast<lt::external_ip_alert>(alert)) {
                external_address_ = external->external_address.to_string();
            } else if (auto* stats = lt::alert_cast<lt::session_stats_alert>(alert)) {
                static const int incoming_index = lt::find_metric_idx("peer.incoming_connections");
                static const int download_index = lt::find_metric_idx("net.recv_bytes");
                static const int upload_index = lt::find_metric_idx("net.sent_bytes");
                static const int disk_bytes_index = lt::find_metric_idx("disk.queued_write_bytes");
                static const int disk_peers_index = lt::find_metric_idx("peer.num_peers_down_disk");
                const auto counters = stats->counters();
                if (disk_bytes_index >= 0 && disk_peers_index >= 0) {
                    queued_disk_bytes_ = counters[disk_bytes_index];
                    disk_blocked_peers_ = counters[disk_peers_index];
                    disk_stats_available_ = true;
                }
                incoming_ = incoming_ || counters[incoming_index] > 0;
                auto now = std::chrono::steady_clock::now();
                double elapsed = std::chrono::duration<double>(now - last_stats_).count();
                if (elapsed >= 0.5) {
                    download_rate_ = static_cast<std::int64_t>((counters[download_index] - downloaded_) / elapsed);
                    upload_rate_ = static_cast<std::int64_t>((counters[upload_index] - uploaded_) / elapsed);
                    downloaded_ = counters[download_index];
                    uploaded_ = counters[upload_index];
                    last_stats_ = now;
                }
                ++stats_generation_;
            } else if (auto* dht = lt::alert_cast<lt::dht_stats_alert>(alert)) {
                int count = 0;
                for (const auto& bucket : dht->routing_table) count += bucket.num_nodes;
                dht_nodes_[dht->local_endpoint.address().to_string()] = count;
            } else if (alert->category() & lt::alert_category::error) {
                persistence_.log(alert->message());
            }
        } catch (const std::exception& error) {
            persistence_.log(std::string("Alert handling: ") + error.what());
            if (stopping_) throw;
        }
    }
}

void Session::port_mapping_alert(lt::port_mapping_t handle, lt::portmap_transport transport,
    int external_port, lt::portmap_protocol protocol, const std::string& address, const std::string& error) {
    if (!port_mapping_enabled_) return;
    auto found = extra_mappings_.end();
    int candidates = 0;
    for (auto entry = extra_mappings_.begin(); entry != extra_mappings_.end(); ++entry) {
        if (std::find(entry->second.handles.begin(), entry->second.handles.end(), handle)
            == entry->second.handles.end()) continue;
        if (protocol != lt::portmap_protocol::none
            && (entry->first.first == "tcp") != (protocol == lt::portmap_protocol::tcp)) continue;
        found = entry;
        ++candidates;
        if (error.empty() && entry->first.second == external_port) {
            candidates = 1;
            break;
        }
    }
    // Mapping indices belong to individual interfaces and mapper mechanisms.
    // An ambiguous error has no port/protocol; forward it without guessing a port.
    if (candidates > 1) {
        protocol_.send({{"event", error.empty() ? "portmap" : "portmap_error"}, {"scope", "unknown"},
            {"mapping", static_cast<int>(handle)}, {"external_port", external_port},
            {"transport", transport == lt::portmap_transport::upnp ? "upnp" : "natpmp"},
            {"local_address", address}, {"succeeded", error.empty()}, {"message", error}});
        return;
    }
    // Deleted mappings can report external_port=0; never treat deletion as success.
    if (error.empty() && external_port == 0) return;
    const std::string name = transport == lt::portmap_transport::upnp ? "upnp" : "natpmp";
    json::object result{{"scope", found == extra_mappings_.end() ? "bittorrent" : "extra"},
        {"transport", name}, {"external_port", external_port}, {"succeeded", error.empty()},
        {"local_address", address}, {"message", error}};
    if (found != extra_mappings_.end()) {
        result["protocol"] = found->first.first;
        result["local_port"] = found->first.second;
    } else {
        result["protocol"] = protocol == lt::portmap_protocol::tcp ? "tcp"
            : protocol == lt::portmap_protocol::udp ? "udp" : "unknown";
        result["local_port"] = listen_port();
    }
    auto& results = found == extra_mappings_.end() ? bt_mappings_ : found->second.results;
    auto previous = std::find_if(results.begin(), results.end(), [&](const auto& value) {
        const auto& object = value.as_object();
        return object.at("transport") == result.at("transport")
            && object.at("local_address") == result.at("local_address")
            && object.at("protocol") == result.at("protocol");
    });
    if (previous == results.end()) results.push_back(result);
    else *previous = result;
    result["event"] = error.empty() ? "portmap" : "portmap_error";
    protocol_.send(result);
}

void Session::poll() {
    for (const auto& message : take_dns_logs()) persistence_.log(message);
    alerts();
    if (refresh_extra_mappings_) {
        refresh_extra_mappings_ = false;
        clear_extra_port_mapping_handles();
    }
    update_extra_port_mappings();
    for (auto& entry : torrents_) {
        refresh_trackers(entry.second);
        try { update_incomplete_files(entry.second); }
        catch (const std::exception& error) { persistence_.log(error.what()); }
    }
    auto now = std::chrono::steady_clock::now();
    if (now - last_stats_request_ >= std::chrono::seconds(1)) {
        session_.post_session_stats();
        last_stats_request_ = now;
    }
    if (now - last_save_ >= std::chrono::seconds(10)) {
        save_all(false);
        last_save_ = now;
    }
    session_.wait_for_alert(std::chrono::milliseconds(25));
}

void Session::shutdown() {
    stopping_ = true;
    stop_create();
    clear_extra_port_mapping_handles();
    extra_mappings_.clear();
    // Snapshot local DHT routing state before pausing; this performs no network wait.
    try {
        if (session_.get_settings().get_bool(lt::settings_pack::enable_dht))
            dht_state_ = session_.session_state(lt::session_handle::save_dht_state);
        persistence_.save_dht(dht_state_);
    } catch (const std::exception& error) {
        persistence_.log(std::string("Cannot save DHT state: ") + error.what());
    }
    session_.pause();
    save_all(true);
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (!pending_resume_.empty() && std::chrono::steady_clock::now() < deadline) {
        session_.wait_for_alert(std::chrono::milliseconds(50));
        alerts();
    }
    if (!pending_resume_.empty()) throw std::runtime_error("Timed out waiting for resume data at shutdown");
}

json::object Session::session_status() {
    auto generation = stats_generation_;
    session_.post_session_stats();
    session_.post_dht_stats();
    auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(250);
    do {
        session_.wait_for_alert(std::chrono::milliseconds(25));
        alerts();
    } while (generation == stats_generation_ && std::chrono::steady_clock::now() < deadline);
    int nodes = 0;
    for (const auto& entry : dht_nodes_) nodes += entry.second;
    json::array extra;
    for (const auto& entry : extra_mappings_) {
        extra.push_back(json::object{{"protocol", entry.first.first}, {"local_port", entry.first.second},
            {"results", entry.second.results}});
    }
    return {{"port_mapping_enabled", port_mapping_enabled_}, {"port_mappings", bt_mappings_},
        {"extra_port_mappings", extra}, {"listen_port", listen_port()}, {"dht_nodes", nodes}, {"has_incoming_connections", incoming_},
        {"download_rate", download_rate_}, {"upload_rate", upload_rate_},
        {"external_address", external_address_.empty() ? json::value(nullptr) : json::value(external_address_)}};
}
}
