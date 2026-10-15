#include "session.hpp"

#include <algorithm>
#include <cerrno>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>

namespace mulee {
namespace {
int available_port(int requested) {
    // Select one free TCP + UDP port before asking libtorrent to bind all
    // interfaces. With port 0 libtorrent may otherwise select different ports
    // on IPv4 and IPv6, making a single protocol listen_port misleading.
    for (int attempt = 0; attempt < 20; ++attempt) {
        std::vector<int> sockets;
        int candidate = attempt == 0 ? requested : 0;
        bool available = true;
        for (int family : {AF_INET, AF_INET6}) {
            for (int type : {SOCK_STREAM, SOCK_DGRAM}) {
                int descriptor = socket(family, type, 0);
                if (descriptor < 0) {
                    if (family == AF_INET6 && errno == EAFNOSUPPORT) continue;
                    available = false;
                    break;
                }
                sockets.push_back(descriptor);
                if (family == AF_INET6) {
                    int enabled = 1;
                    setsockopt(descriptor, IPPROTO_IPV6, IPV6_V6ONLY, &enabled, sizeof(enabled));
                }
                sockaddr_storage storage{};
                socklen_t size;
                if (family == AF_INET) {
                    auto* address = reinterpret_cast<sockaddr_in*>(&storage);
                    address->sin_family = AF_INET;
                    address->sin_port = htons(candidate);
                    size = sizeof(sockaddr_in);
                } else {
                    auto* address = reinterpret_cast<sockaddr_in6*>(&storage);
                    address->sin6_family = AF_INET6;
                    address->sin6_port = htons(candidate);
                    size = sizeof(sockaddr_in6);
                }
                if (bind(descriptor, reinterpret_cast<sockaddr*>(&storage), size) != 0) {
                    available = false;
                    break;
                }
                if (candidate == 0) {
                    getsockname(descriptor, reinterpret_cast<sockaddr*>(&storage), &size);
                    candidate = ntohs(reinterpret_cast<sockaddr_in*>(&storage)->sin_port);
                }
            }
            if (!available) break;
        }
        for (int descriptor : sockets) close(descriptor);
        if (available && candidate > 0) return candidate;
    }
    throw RequestError("io_error", "Cannot find an available TCP/UDP listen port");
}
}
void Session::dispatch(const std::string& line) {
    json::value id = nullptr;
    try {
        boost::system::error_code error;
        auto value = json::parse(line, error);
        if (error || !value.is_object()) throw RequestError("invalid_request", "Expected a JSON object");
        const auto& request = value.as_object();
        if (auto field = request.if_contains("id")) id = *field;
        auto method = request.if_contains("method");
        if (!method || !method->is_string() || method->as_string().empty())
            throw RequestError("invalid_request", "Missing method");
        json::object params;
        if (auto field = request.if_contains("params")) {
            if (!field->is_object()) throw RequestError("invalid_params", "params must be an object");
            params = field->as_object();
        }
        auto result = execute(std::string(method->as_string()), params);
        protocol_.respond(id, result);
    } catch (const RequestError& error) {
        protocol_.fail(id, error.code, error.what());
    } catch (const fs::filesystem_error& error) {
        protocol_.fail(id, "io_error", error.what());
    } catch (const std::system_error& error) {
        protocol_.fail(id, "io_error", error.what());
    } catch (const std::exception& error) {
        protocol_.fail(id, "internal", error.what());
    }
}

Torrent& Session::find(const json::object& params) {
    auto id = string_param(params, "id");
    auto found = torrents_.find(id);
    if (found == torrents_.end()) throw RequestError("not_found", "Torrent not found");
    return found->second;
}

json::object Session::configure(const json::object& params) {
    auto directory = absolute_path(string_param(params, "download_dir"));
    int port = int_param(params, "listen_port", 65535);
    int download = int_param(params, "download_limit");
    int upload = int_param(params, "upload_limit");
    int downloads = int_param(params, "max_active_downloads");
    int seeds = int_param(params, "max_active_seeds");
    bool dht = bool_param(params, "dht");
    bool lsd = bool_param(params, "lsd");
    bool mapping = bool_param(params, "port_mapping");
    auto encryption = string_param(params, "encryption");
    if (encryption != "prefer" && encryption != "require" && encryption != "disable")
        throw RequestError("invalid_params", "Unknown encryption policy");
    fs::create_directories(directory);
    if (port == 0 || port != listen_port()) port = available_port(port);
    lt::settings_pack settings;
    settings.set_str(lt::settings_pack::listen_interfaces,
        "0.0.0.0:" + std::to_string(port) + ",[::]:" + std::to_string(port));
    // Retry the requested port once, then let libtorrent ask the OS for a free port.
    settings.set_int(lt::settings_pack::max_retry_port_bind, 0);
    settings.set_int(lt::settings_pack::download_rate_limit, download);
    settings.set_int(lt::settings_pack::upload_rate_limit, upload);
    settings.set_int(lt::settings_pack::active_downloads, downloads);
    settings.set_int(lt::settings_pack::active_seeds, seeds);
    settings.set_int(lt::settings_pack::active_limit, downloads > 2147483647 - seeds ? 2147483647 : downloads + seeds);
    settings.set_bool(lt::settings_pack::enable_dht, dht);
    settings.set_bool(lt::settings_pack::enable_lsd, lsd);
    settings.set_bool(lt::settings_pack::enable_upnp, mapping);
    settings.set_bool(lt::settings_pack::enable_natpmp, mapping);
    int policy = encryption == "require" ? lt::settings_pack::pe_forced
        : encryption == "disable" ? lt::settings_pack::pe_disabled : lt::settings_pack::pe_enabled;
    settings.set_int(lt::settings_pack::in_enc_policy, policy);
    settings.set_int(lt::settings_pack::out_enc_policy, policy);
    settings.set_bool(lt::settings_pack::prefer_rc4, encryption == "prefer");
    session_.apply_settings(settings);
    // get_settings() is synchronous and is ordered after apply_settings(). It prevents
    // returning the previous listener's port while the network thread rebinds.
    session_.get_settings();
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(5);
    while (listen_port() == 0 && std::chrono::steady_clock::now() < deadline) {
        session_.wait_for_alert(std::chrono::milliseconds(50));
        alerts();
    }
    if (listen_port() == 0) throw RequestError("io_error", "Cannot open listening socket");
    download_dir_ = directory;
    if (!dht) dht_nodes_.clear();
    return {{"listen_port", listen_port()}};
}

json::object Session::add(const json::object& params) {
    bool magnet = params.contains("magnet");
    bool file = params.contains("torrent_file");
    if (magnet == file) throw RequestError("invalid_params", "Specify exactly one of magnet and torrent_file");
    auto path = params.contains("save_path") ? absolute_path(string_param(params, "save_path")) : download_dir_;
    if (path.empty()) throw RequestError("invalid_params", "Configure download_dir or specify save_path first");
    bool paused = params.contains("paused") ? bool_param(params, "paused") : false;
    Metadata metadata;
    metadata.added_at = unix_time();
    if (params.contains("source")) metadata.source = string_param(params, "source");
    lt::add_torrent_params add;
    lt::error_code error;
    if (magnet) {
        add = lt::parse_magnet_uri(string_param(params, "magnet"), error);
        if (error) throw RequestError("invalid_torrent", error.message());
        if (params.contains("file_priorities"))
            throw RequestError("invalid_params", "file_priorities requires torrent_file");
    } else {
        auto file_path = absolute_path(string_param(params, "torrent_file"));
        if (!fs::exists(file_path) || !fs::is_regular_file(file_path))
            throw RequestError("io_error", "Cannot read torrent_file");
        add.ti = std::make_shared<lt::torrent_info>(file_path, error);
        if (error) throw RequestError("invalid_torrent", error.message());
        add.info_hashes = add.ti->info_hashes();
        if (auto values = params.if_contains("file_priorities"))
            add.file_priorities = priorities(*values, add.ti->num_files());
    }
    auto id = torrent_id(add.info_hashes);
    auto duplicate = torrents_.find(id);
    if (duplicate != torrents_.end()) {
        auto& handle = duplicate->second.handle;
        auto trackers = handle.trackers();
        for (std::size_t i = 0; i < add.trackers.size(); ++i) {
            if (std::none_of(trackers.begin(), trackers.end(), [&](const lt::announce_entry& tracker) {
                return tracker.url == add.trackers[i];
            })) {
                lt::announce_entry tracker(add.trackers[i]);
                if (i < add.tracker_tiers.size()) tracker.tier = add.tracker_tiers[i];
                handle.add_tracker(tracker);
            }
        }
        save(duplicate->second);
        auto name = handle.status().name;
        return {{"id", id}, {"name", name.empty() ? id : name}, {"duplicate", true}};
    }
    fs::create_directories(path);
    add.save_path = path;
    // Explicit peer endpoints in magnets are passed through by parse_magnet_uri.
    if (paused) {
        add.flags |= lt::torrent_flags::paused;
        add.flags &= ~lt::torrent_flags::auto_managed;
    } else {
        add.flags &= ~lt::torrent_flags::paused;
        add.flags |= lt::torrent_flags::auto_managed;
    }
    auto handle = session_.add_torrent(add, error);
    if (error) throw RequestError("invalid_torrent", error.message());
    auto inserted = torrents_.emplace(id, Torrent{handle, metadata, add.peers});
    try {
        persistence_.save_meta(id, metadata);
        // Save immediately, including info metadata, so the original .torrent can be removed.
        save(inserted.first->second);
    } catch (...) {
        session_.remove_torrent(handle);
        torrents_.erase(inserted.first);
        throw;
    }
    auto name = handle.status().name;
    return {{"id", id}, {"name", name.empty() ? id : name}, {"duplicate", false}};
}

json::object Session::execute(const std::string& method, const json::object& params) {
    if (method == "configure") return configure(params);
    if (method == "add") return add(params);
    if (method == "list") {
        json::array result;
        for (auto& entry : torrents_) {
            auto status = entry.second.handle.status();
            if (status.has_metadata && status.is_finished) {
                mark_completed(entry.second);
            } else if (status.has_metadata && !entry.second.metadata.completed_at.is_null()
                && status.state == lt::torrent_status::downloading) {
                entry.second.metadata.completed_at = nullptr;
                persistence_.save_meta(entry.first, entry.second.metadata);
            }
            result.push_back(serialize_torrent(entry.first, entry.second));
        }
        return {{"torrents", result}};
    }
    if (method == "session_status") return session_status();
    if (method == "shutdown") {
        stopping_ = true;
        return {};
    }
    if (method == "pause" || method == "resume") {
        auto& torrent = find(params);
        if (method == "pause") {
            torrent.handle.unset_flags(lt::torrent_flags::auto_managed);
            torrent.handle.pause();
        } else {
            torrent.handle.set_flags(lt::torrent_flags::auto_managed);
            torrent.handle.resume();
        }
        save(torrent);
        return {};
    }
    if (method == "remove") {
        auto& torrent = find(params);
        bool delete_files = bool_param(params, "delete_files");
        auto id = string_param(params, "id");
        persistence_.remove(id);
        session_.remove_torrent(torrent.handle, delete_files ? lt::session::delete_files : lt::remove_flags_t{});
        torrents_.erase(id);
        return {};
    }
    if (method == "files") return {{"files", serialize_files(find(params))}};
    if (method == "set_file_priorities") {
        auto& torrent = find(params);
        auto info = torrent.handle.torrent_file();
        if (!info) throw RequestError("invalid_params", "Torrent has no metadata");
        torrent.handle.prioritize_files(priorities(required(params, "priorities"), info->num_files()));
        save(torrent);
        return {};
    }
    if (method == "set_upload_limit") {
        auto& torrent = find(params);
        torrent.handle.set_upload_limit(int_param(params, "limit"));
        save(torrent);
        return {};
    }
    throw RequestError("unknown_method", "Unknown method: " + method);
}
}
