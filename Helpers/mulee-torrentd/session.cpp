#include "session.hpp"
#include "fake_dns.hpp"

#include <algorithm>
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
        | lt::alert_category::error | lt::alert_category::storage | lt::alert_category::tracker));
    return settings;
}
}

Session::Session(Protocol& protocol, Persistence& persistence)
    : protocol_(protocol), persistence_(persistence), session_(defaults()) {
    // Global limits also apply to LAN and loopback peers. libtorrent's default
    // local peer class bypasses them, which would violate configure's limits.
    lt::ip_filter filter;
    const auto global = 1U << static_cast<std::uint32_t>(lt::session::global_peer_class_id);
    filter.add_rule(lt::make_address("0.0.0.0"), lt::make_address("255.255.255.255"), global);
    filter.add_rule(lt::make_address("::"), lt::make_address("ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff"), global);
    session_.set_peer_class_filter(filter);
}

void Session::restore() {
    for (auto& params : persistence_.restore()) {
        auto id = torrent_id(params.info_hashes);
        lt::error_code error;
        auto handle = session_.add_torrent(params, error);
        if (error) {
            persistence_.log("Cannot restore " + id + ": " + error.message());
            continue;
        }
        torrents_.emplace(id, Torrent{handle, persistence_.load_meta(id), params.peers});
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
            if (auto* saved = lt::alert_cast<lt::save_resume_data_alert>(alert)) {
                auto pending_save = pending_resume_.find(saved->handle);
                if (pending_save != pending_resume_.end() && --pending_save->second == 0)
                    pending_resume_.erase(pending_save);
                // Removed handles can still deliver resume alerts. Never resurrect them.
                if (auto* torrent = find(saved->handle)) {
                    auto id = torrent_id(saved->handle.info_hashes());
                    auto params = saved->params;
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
                persistence_.log(failed->message());
            } else if (auto* metadata = lt::alert_cast<lt::metadata_received_alert>(alert)) {
                if (auto* torrent = find(metadata->handle)) {
                    protocol_.send({{"event", "metadata_received"}, {"id", torrent_id(metadata->handle.info_hashes())},
                        {"name", metadata->handle.status().name}});
                    save(*torrent);
                }
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
            } else if (auto* external = lt::alert_cast<lt::external_ip_alert>(alert)) {
                external_address_ = external->external_address.to_string();
            } else if (auto* stats = lt::alert_cast<lt::session_stats_alert>(alert)) {
                static const int incoming_index = lt::find_metric_idx("peer.incoming_connections");
                static const int download_index = lt::find_metric_idx("net.recv_bytes");
                static const int upload_index = lt::find_metric_idx("net.sent_bytes");
                const auto counters = stats->counters();
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
        }
    }
}

void Session::poll() {
    for (const auto& message : take_dns_logs()) persistence_.log(message);
    alerts();
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
    session_.pause();
    save_all(true);
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
    while (!pending_resume_.empty() && std::chrono::steady_clock::now() < deadline) {
        session_.wait_for_alert(std::chrono::milliseconds(50));
        alerts();
    }
    if (!pending_resume_.empty()) persistence_.log("Timed out waiting for resume data at shutdown");
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
    return {{"listen_port", listen_port()}, {"dht_nodes", nodes}, {"has_incoming_connections", incoming_},
        {"download_rate", download_rate_}, {"upload_rate", upload_rate_},
        {"external_address", external_address_.empty() ? json::value(nullptr) : json::value(external_address_)}};
}
}
