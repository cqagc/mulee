#include "session.hpp"

#include <algorithm>
#include <cerrno>
#include <fstream>
#include <sstream>
#include <fnmatch.h>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/ip_filter.hpp>
#include <libtorrent/peer_info.hpp>
#include <libtorrent/write_resume_data.hpp>
#include <netinet/in.h>
#include <sys/socket.h>
#include <unistd.h>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/parse_url.hpp>
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
    int disk_cache = 16 * 1024 * 1024;
    if (auto value = params.if_contains("disk_cache_bytes")) {
        if (!value->is_int64() || value->as_int64() < 0)
            throw RequestError("invalid_params", "disk_cache_bytes must be a nonnegative integer");
        disk_cache = static_cast<int>(std::clamp<std::int64_t>(value->as_int64(), 1024 * 1024, 256 * 1024 * 1024));
    }
    std::vector<std::string> blocked;
    if (auto values = params.if_contains("blocked_clients")) {
        if (!values->is_array() || values->as_array().size() > 50)
            throw RequestError("invalid_params", "blocked_clients must contain at most 50 rules");
        for (const auto& value : values->as_array()) {
            if (!value.is_string() || value.as_string().empty() || value.as_string().size() > 64)
                throw RequestError("invalid_params", "Client rules must be nonempty strings of at most 64 bytes");
            std::string rule(value.as_string());
            if (std::any_of(rule.begin(), rule.end(), [](unsigned char c) { return c < 32 || c > 126; }))
                throw RequestError("invalid_params", "Client rules must be printable ASCII");
            if (std::find(blocked.begin(), blocked.end(), rule) == blocked.end()) blocked.push_back(rule);
        }
    }
    bool skip_junk = params.contains("skip_junk_files") ? bool_param(params, "skip_junk_files") : true;
    auto patterns = junk_patterns_;
    if (auto value = params.if_contains("junk_file_patterns")) {
        if (!value->is_array() || value->as_array().size() > 256)
            throw RequestError("invalid_params", "junk_file_patterns must contain at most 256 patterns");
        patterns.clear();
        for (const auto& item : value->as_array()) {
            if (!item.is_string() || item.as_string().empty() || item.as_string().size() > 1024)
                throw RequestError("invalid_params", "Invalid junk pattern");
            patterns.emplace_back(item.as_string());
        }
    }
    auto filters = ip_filters_;
    if (params.contains("ip_blocklist_path")) {
        auto path = string_param(params, "ip_blocklist_path");
        filters["imported"] = path.empty() ? json::array{} : read_blocklist(absolute_path(path));
    }
    apply_ip_filters(filters);
    persistence_.save_filters(filters);
    ip_filters_ = std::move(filters);
    skip_junk_files_ = skip_junk;
    junk_patterns_ = std::move(patterns);
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
    // Slow torrents remain excluded by dont_count_slow_torrents. Leave enough
    // headroom for metadata/stalled swarms even with small UI queue limits.
    settings.set_int(lt::settings_pack::active_limit,
        std::max(32, downloads > 2147483647 - seeds ? 2147483647 : downloads + seeds));
    settings.set_bool(lt::settings_pack::dont_count_slow_torrents, true);
    // libtorrent 2.0 read caching belongs to the OS. This bounds pending writes,
    // not a read cache allocation; clamp to avoid tiny queues or excessive memory.
    settings.set_int(lt::settings_pack::max_queued_disk_bytes, disk_cache);
    settings.set_bool(lt::settings_pack::enable_dht, dht);
    settings.set_bool(lt::settings_pack::enable_lsd, lsd);
    settings.set_bool(lt::settings_pack::enable_upnp, mapping);
    settings.set_bool(lt::settings_pack::enable_natpmp, mapping);
    int policy = encryption == "require" ? lt::settings_pack::pe_forced
        : encryption == "disable" ? lt::settings_pack::pe_disabled : lt::settings_pack::pe_enabled;
    settings.set_int(lt::settings_pack::in_enc_policy, policy);
    settings.set_int(lt::settings_pack::out_enc_policy, policy);
    settings.set_bool(lt::settings_pack::prefer_rc4, encryption == "prefer");
    bool listener_changed = port != listen_port();
    if (listener_changed || mapping != port_mapping_enabled_) {
        clear_extra_port_mapping_handles();
        bt_mappings_.clear();
    }
    port_mapping_enabled_ = mapping;
    {
        std::lock_guard<std::mutex> lock(client_rules_->mutex);
        client_rules_->values = std::move(blocked);
    }
    disk_cache_bytes_ = disk_cache;
    if (!dht && session_.get_settings().get_bool(lt::settings_pack::enable_dht)) {
        // A disabled DHT has no live routing table in session_state(). Keep the
        // last live snapshot for shutdown and a subsequent enable in this session.
        dht_state_ = session_.session_state(lt::session_handle::save_dht_state);
        session_.set_dht_state(dht_state_.dht_state);
    }
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
    update_extra_port_mappings();
    download_dir_ = directory;
    if (!dht) dht_nodes_.clear();
    auto applied = session_.get_settings();
    return {{"listen_port", listen_port()}, {"disk_cache_bytes", disk_cache_bytes_},
        {"connections_limit", applied.get_int(lt::settings_pack::connections_limit)},
        {"active_limit", applied.get_int(lt::settings_pack::active_limit)},
        {"dont_count_slow_torrents", applied.get_bool(lt::settings_pack::dont_count_slow_torrents)},
        {"announce_to_all_tiers", applied.get_bool(lt::settings_pack::announce_to_all_tiers)},
        {"announce_to_all_trackers", applied.get_bool(lt::settings_pack::announce_to_all_trackers)},
        {"unchoke_slots_limit", applied.get_int(lt::settings_pack::unchoke_slots_limit)},
        {"file_pool_size", applied.get_int(lt::settings_pack::file_pool_size)}};
}

json::object Session::set_extra_port_mappings(const json::object& params) {
    std::map<std::pair<std::string, int>, ExtraMapping> requested;
    for (const auto& protocol : {"tcp", "udp"}) {
        auto* ports = params.if_contains(protocol);
        if (!ports || !ports->is_array())
            throw RequestError("invalid_params", "tcp and udp must be arrays");
        for (const auto& value : ports->as_array()) {
            if (!value.is_int64() || value.as_int64() < 1 || value.as_int64() > 65535)
                throw RequestError("invalid_params", "Ports must be integers from 1 to 65535");
            requested.emplace(std::make_pair(protocol, static_cast<int>(value.as_int64())), ExtraMapping{});
        }
    }
    // Validate the entire request before changing any router mappings.
    for (auto& entry : extra_mappings_) {
        auto found = requested.find(entry.first);
        if (found != requested.end()) found->second = std::move(entry.second);
        else for (auto handle : entry.second.handles) session_.delete_port_mapping(handle);
    }
    extra_mappings_ = std::move(requested);
    update_extra_port_mappings();
    json::object result{{"tcp", json::array{}}, {"udp", json::array{}},
        {"enabled", port_mapping_enabled_}};
    for (const auto& entry : extra_mappings_)
        result[entry.first.first].as_array().push_back(entry.first.second);
    return result;
}

void Session::clear_extra_port_mapping_handles() {
    for (auto& entry : extra_mappings_) {
        for (auto handle : entry.second.handles) session_.delete_port_mapping(handle);
        entry.second.handles.clear();
        entry.second.results.clear();
    }
}

void Session::update_extra_port_mappings() {
    if (!port_mapping_enabled_) return;
    for (auto& entry : extra_mappings_) {
        if (!entry.second.handles.empty()) continue;
        auto protocol = entry.first.first == "tcp" ? lt::portmap_protocol::tcp : lt::portmap_protocol::udp;
        entry.second.handles = session_.add_port_mapping(protocol, entry.first.second, entry.first.second);
    }
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
    metadata.mark_incomplete = params.contains("mark_incomplete") ? bool_param(params, "mark_incomplete") : true;
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
    metadata.junk_pending = skip_junk_files_ && !params.contains("file_priorities");
    metadata.junk_patterns = junk_patterns_;
    if (metadata.junk_pending && add.ti) {
        const auto& files = add.ti->files();
        add.file_priorities.assign(add.ti->num_files(), lt::default_priority);
        for (auto index : files.file_range()) {
            auto name = fs::path(files.file_path(index)).filename().string();
            if (std::any_of(junk_patterns_.begin(), junk_patterns_.end(), [&](const auto& pattern) {
                return fnmatch(pattern.c_str(), name.c_str(), FNM_CASEFOLD) == 0;
            })) {
                add.file_priorities[static_cast<int>(index)] = lt::dont_download;
                metadata.skipped_files.push_back(json::object{{"index", static_cast<int>(index)}, {"path", files.file_path(index)}});
            }
        }
        metadata.junk_pending = false;
    }
    auto id = torrent_id(add.info_hashes);
    auto duplicate = torrents_.find(id);
    if (duplicate != torrents_.end()) {
        auto& handle = duplicate->second.handle;
        // Duplicate-add must not bypass private/metadata guards on tracker injection.
        if (!add.trackers.empty()) {
            json::array urls;
            for (const auto& url : add.trackers) urls.push_back(json::value(url));
            add_trackers(duplicate->second, {{"urls", urls}});
        }
        save(duplicate->second);
        auto name = handle.status().name;
        return {{"id", id}, {"name", name.empty() ? id : name}, {"duplicate", true}, {"skipped_files", duplicate->second.metadata.skipped_files}};
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
    if (metadata.mark_incomplete && add.ti) {
        for (auto index : add.ti->files().file_range()) {
            if (add.ti->files().pad_file_at(index)) continue;
            auto original = add.ti->files().file_path(index);
            metadata.original_paths[std::to_string(static_cast<int>(index))] = original;
            if (!fs::exists(fs::path(path) / original)) add.renamed_files[index] = original + ".mulee";
        }
    }
    auto count = std::make_shared<std::atomic<std::int64_t>>(0);
    prepare(add, count);
    auto handle = session_.add_torrent(add, error);
    if (error) throw RequestError("invalid_torrent", error.message());
    handle.set_max_connections(per_torrent_connections);
    auto inserted = torrents_.emplace(id, Torrent{handle, metadata, add.peers, count});
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
    return {{"id", id}, {"name", name.empty() ? id : name}, {"duplicate", false}, {"skipped_files", metadata.skipped_files}};
}

json::object Session::add_trackers(Torrent& torrent, const json::object& params) {
    auto info = torrent.handle.torrent_file();
    if (!info) throw RequestError("metadata_pending", "Retry after torrent metadata is available");
    if (info->priv()) throw RequestError("private_torrent", "Cannot append trackers to a private torrent");
    bool subscription = params.contains("subscription") ? bool_param(params, "subscription") : false;
    const auto& urls = required(params, "urls");
    if (!urls.is_array() || urls.as_array().size() > 50)
        throw RequestError("invalid_params", "urls must contain at most 50 tracker URLs");
    auto trackers = torrent.handle.trackers();
    std::vector<std::string> additions;
    for (const auto& value : urls.as_array()) {
        if (!value.is_string()) throw RequestError("invalid_params", "Tracker URL must be a string");
        std::string url(value.as_string());
        lt::error_code error;
        auto parsed = lt::parse_url_components(url, error);
        const auto& scheme = std::get<0>(parsed);
        if (url.size() > 2048 || error || std::get<2>(parsed).empty()
            || (scheme != "http" && scheme != "https" && scheme != "udp")
            || std::any_of(url.begin(), url.end(), [](unsigned char c) { return c <= 32 || c == 127; }))
            throw RequestError("invalid_params", "Expected an HTTP, HTTPS or UDP tracker URL");
        if (torrent.metadata.tracker_state.contains(url)) continue;
        if (std::none_of(trackers.begin(), trackers.end(), [&](const auto& entry) { return entry.url == url; })
            && std::find(additions.begin(), additions.end(), url) == additions.end()) additions.push_back(url);
    }
    std::size_t suspended = 0;
    for (const auto& entry : torrent.metadata.tracker_state)
        if (entry.value().as_object().at("disabled_until").as_int64() > unix_time()) ++suspended;
    if (!additions.empty() && trackers.size() + suspended + additions.size() > 50)
        throw RequestError("tracker_limit", "Torrent tracker limit is 50");
    // A separate, unused tier avoids changing the original tracker's failover group.
    int tier = 0;
    while (tier < 256 && std::any_of(trackers.begin(), trackers.end(),
        [&](const auto& entry) { return entry.tier == tier; })) ++tier;
    if (!additions.empty() && tier == 256) throw RequestError("tracker_limit", "No independent tracker tier available");
    for (const auto& url : additions) {
        lt::announce_entry tracker(url);
        tracker.tier = static_cast<std::uint8_t>(tier);
        torrent.handle.add_tracker(tracker);
        if (subscription) torrent.metadata.tracker_state[url] = json::object{
            {"tier", tier}, {"subscription", true}, {"failures", 0}, {"disabled_until", 0},
            {"last_result", ""}, {"peers", 0}};
    }
    if (!additions.empty()) {
        torrent.last_diagnostics = {};
        save(torrent);
    }
    return {{"added", additions.size()}, {"total", trackers.size() + suspended + additions.size()}};
}


void Session::apply_junk_filter(Torrent& torrent) {
    auto info = torrent.handle.torrent_file();
    if (!info || !torrent.metadata.junk_pending) return;
    auto values = torrent.handle.get_file_priorities();
    const auto& files = info->files();
    for (auto index : files.file_range()) {
        auto name = fs::path(files.file_path(index)).filename().string();
        if (std::any_of(torrent.metadata.junk_patterns.begin(), torrent.metadata.junk_patterns.end(), [&](const auto& pattern) {
            return fnmatch(pattern.c_str(), name.c_str(), FNM_CASEFOLD) == 0;
        })) {
            values.at(static_cast<int>(index)) = lt::dont_download;
            torrent.metadata.skipped_files.push_back(json::object{{"index", static_cast<int>(index)}, {"path", files.file_path(index)}});
        }
    }
    torrent.metadata.junk_pending = false;
    torrent.handle.prioritize_files(values);
    persistence_.save_meta(torrent_id(torrent.handle.info_hashes()), torrent.metadata);
}

void Session::wait_storage() {
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(300);
    while (storage_pending_ > 0 && std::chrono::steady_clock::now() < deadline) {
        session_.wait_for_alert(std::chrono::milliseconds(25));
        alerts();
    }
    if (storage_pending_ > 0) throw RequestError("io_error", "Storage operation timed out; inspect task state before retrying");
    if (!storage_error_.empty()) throw RequestError(storage_error_code_, storage_error_);
}

namespace {
std::string trim(std::string value) {
    auto first = value.find_first_not_of(" \t\r\n");
    return first == std::string::npos ? "" : value.substr(first, value.find_last_not_of(" \t\r\n") - first + 1);
}

void validate_relative(const std::string& value) {
    fs::path path(value);
    if (value.empty() || path.is_absolute()) throw RequestError("invalid_params", "Expected a relative file path");
    for (const auto& part : path)
        if (part == ".." || part == "." || part.empty()) throw RequestError("invalid_params", "Unsafe file path");
}

lt::address block_address(std::string value, lt::error_code& error) {
    value = trim(std::move(value));
    if (value.find(':') != std::string::npos) return lt::make_address(value, error);
    // DAT 常用补零的十进制 IPv4，不能交给地址解析器当作八进制或非法地址。
    std::string normalized;
    std::size_t start = 0;
    for (int i = 0; i < 4; ++i) {
        auto end = value.find('.', start);
        if ((i < 3 && end == std::string::npos) || (i == 3 && end != std::string::npos))
            return lt::make_address(value, error);
        auto part = value.substr(start, end == std::string::npos ? end : end - start);
        if (part.empty() || part.size() > 3 || part.find_first_not_of("0123456789") != std::string::npos)
            return lt::make_address(value, error);
        int octet = std::stoi(part);
        if (octet > 255) return lt::make_address(value, error);
        if (i > 0) normalized += ".";
        normalized += std::to_string(octet);
        if (i < 3) start = end + 1;
    }
    return lt::make_address(normalized, error);
}

void validate_tracker(const std::string& url) {
    lt::error_code error;
    auto parsed = lt::parse_url_components(url, error);
    const auto& scheme = std::get<0>(parsed);
    if (url.size() > 2048 || error || std::get<2>(parsed).empty()
        || (scheme != "http" && scheme != "https" && scheme != "udp")
        || std::any_of(url.begin(), url.end(), [](unsigned char c) { return c <= 32 || c == 127; }))
        throw RequestError("invalid_params", "Expected an HTTP, HTTPS or UDP tracker URL");
}
}

json::array Session::read_blocklist(const std::string& path) {
    if (!fs::is_regular_file(path) || fs::file_size(path) > 64 * 1024 * 1024)
        throw RequestError("io_error", "Cannot read blocklist, or blocklist exceeds 64 MiB");
    std::ifstream input(path);
    if (!input) throw RequestError("io_error", "Cannot open blocklist");
    json::array result;
    std::string line;
    int line_number = 0;
    while (std::getline(input, line)) {
        ++line_number;
        line = trim(line);
        if (line.empty() || line.front() == '#' || line.front() == ';') continue;
        auto comma = line.find(',');
        std::string range;
        bool block = true;
        if (comma != std::string::npos) {
            auto next = line.find(',', comma + 1);
            if (next == std::string::npos) throw RequestError("invalid_params", "Invalid DAT line " + std::to_string(line_number));
            auto level = trim(line.substr(comma + 1, next - comma - 1));
            if (level.empty() || level.find_first_not_of("0123456789") != std::string::npos || level.size() > 3)
                throw RequestError("invalid_params", "Invalid DAT level");
            block = std::stoi(level) < 127;
            range = trim(line.substr(0, comma));
        } else {
            auto colon = line.find(':');
            if (colon == std::string::npos) throw RequestError("invalid_params", "Invalid P2P line " + std::to_string(line_number));
            range = trim(line.substr(colon + 1));
        }
        auto dash = range.find('-');
        if (dash == std::string::npos) throw RequestError("invalid_params", "Missing IP range");
        lt::error_code first_error, last_error;
        auto first = block_address(range.substr(0, dash), first_error);
        auto last = block_address(range.substr(dash + 1), last_error);
        if (first_error || last_error || first.is_v4() != last.is_v4() || last < first)
            throw RequestError("invalid_params", "Invalid IP range on line " + std::to_string(line_number));
        if (block) result.push_back(json::object{{"first", first.to_string()}, {"last", last.to_string()}});
    }
    if (input.bad()) throw RequestError("io_error", "Cannot read blocklist");
    return result;
}

void Session::apply_ip_filters(const json::object& filters) {
    lt::ip_filter filter;
    if (auto values = filters.if_contains("imported")) {
        for (const auto& value : values->as_array()) {
            const auto& range = value.as_object();
            filter.add_rule(lt::make_address(string_param(range, "first")),
                lt::make_address(string_param(range, "last")), lt::ip_filter::blocked);
        }
    }
    if (auto values = filters.if_contains("banned")) {
        for (const auto& value : values->as_array()) {
            auto address = lt::make_address(std::string(value.as_string()));
            filter.add_rule(address, address, lt::ip_filter::blocked);
        }
    }
    // IP 访问控制与现有的全局带宽 peer class 分开，避免覆盖限速规则。
    session_.set_ip_filter(filter);
    session_.get_settings();
}

void Session::refresh_trackers(Torrent& torrent) {
    auto trackers = torrent.handle.trackers();
    bool changed = false;
    for (auto& entry : torrent.metadata.tracker_state) {
        auto& state = entry.value().as_object();
        auto until = state.at("disabled_until").as_int64();
        if (until == 0) continue;
        auto found = std::find_if(trackers.begin(), trackers.end(), [&](const auto& tracker) { return tracker.url == entry.key(); });
        if (until > unix_time()) {
            if (found != trackers.end()) { trackers.erase(found); changed = true; }
        } else {
            if (found == trackers.end()) {
                lt::announce_entry tracker(std::string(entry.key()));
                tracker.tier = static_cast<std::uint8_t>(state.at("tier").as_int64());
                trackers.push_back(tracker);
                changed = true;
            }
            state["disabled_until"] = 0;
            state["failures"] = 0;
            persistence_.save_meta(torrent_id(torrent.handle.info_hashes()), torrent.metadata);
        }
    }
    if (changed) { torrent.handle.replace_trackers(trackers); save(torrent); }
}

void Session::tracker_result(Torrent& torrent, const std::string& url, const std::string& result, int peers, bool failed) {
    auto info = torrent.handle.torrent_file();
    auto value = torrent.metadata.tracker_state.if_contains(url);
    if (!value) {
        auto trackers = torrent.handle.trackers();
        auto found = std::find_if(trackers.begin(), trackers.end(), [&](const auto& entry) { return entry.url == url; });
        if (found == trackers.end()) return;
        torrent.metadata.tracker_state[url] = json::object{{"tier", found->tier}, {"subscription", false},
            {"failures", 0}, {"disabled_until", 0}, {"last_result", ""}, {"peers", 0}};
        value = torrent.metadata.tracker_state.if_contains(url);
    }
    auto& state = value->as_object();
    state["last_result"] = result;
    state["peers"] = peers;
    auto failures = failed ? state.at("failures").as_int64() + 1 : 0;
    state["failures"] = failures;
    if (failed && failures >= 3 && info && !info->priv() && state.at("subscription").as_bool()
        && state.at("disabled_until").as_int64() == 0) {
        state["disabled_until"] = unix_time() + 24 * 60 * 60;
        refresh_trackers(torrent);
    }
    persistence_.save_meta(torrent_id(torrent.handle.info_hashes()), torrent.metadata);
}

json::object Session::tracker_list(Torrent& torrent) {
    refresh_trackers(torrent);
    json::array result;
    for (const auto& entry : torrent.handle.trackers()) {
        bool working = false, failed = false;
        std::string message;
        int peers = 0;
        for (const auto& endpoint : entry.endpoints) {
            for (const auto& hash : endpoint.info_hashes) {
                working = working || (hash.start_sent && !hash.last_error && hash.fails == 0);
                failed = failed || bool(hash.last_error) || hash.fails > 0;
                if (!hash.message.empty()) message = hash.message;
                else if (hash.last_error) message = hash.last_error.message();
                peers = std::max(peers, std::max(0, hash.scrape_complete) + std::max(0, hash.scrape_incomplete));
            }
        }
        auto stored = torrent.metadata.tracker_state.if_contains(entry.url);
        if (stored) {
            const auto& state = stored->as_object();
            message = string_param(state, "last_result");
            peers = static_cast<int>(state.at("peers").as_int64());
        }
        result.push_back(json::object{{"url", entry.url}, {"tier", entry.tier},
            {"status", working ? "working" : failed ? "failed" : "pending"},
            {"last_result", message}, {"peers", peers}, {"disabled_until", 0},
            {"subscription", stored ? stored->as_object().at("subscription").as_bool() : false}});
    }
    for (const auto& entry : torrent.metadata.tracker_state) {
        const auto& state = entry.value().as_object();
        if (state.at("disabled_until").as_int64() <= unix_time()) continue;
        result.push_back(json::object{{"url", entry.key()}, {"tier", state.at("tier")}, {"status", "disabled"},
            {"last_result", state.at("last_result")}, {"peers", state.at("peers")},
            {"disabled_until", state.at("disabled_until")}, {"subscription", state.at("subscription")}});
    }
    return {{"trackers", result}};
}

json::object Session::manage(const std::string& method, const json::object& params) {
    if (method == "ban_ip") {
        lt::error_code error;
        auto address = lt::make_address(string_param(params, "ip"), error);
        if (error) throw RequestError("invalid_params", "Expected an IP address");
        auto filters = ip_filters_;
        if (!filters.contains("banned")) filters["banned"] = json::array{};
        auto& banned = filters.at("banned").as_array();
        json::value value(address.to_string());
        if (std::find(banned.begin(), banned.end(), value) == banned.end()) banned.push_back(value);
        persistence_.save_filters(filters);
        apply_ip_filters(filters);
        ip_filters_ = std::move(filters);
        return {};
    }
    if (method == "import_ip_blocklist") {
        auto ranges = read_blocklist(absolute_path(string_param(params, "path")));
        auto filters = ip_filters_;
        filters["imported"] = ranges;
        persistence_.save_filters(filters);
        apply_ip_filters(filters);
        ip_filters_ = std::move(filters);
        return {{"blocked_ranges", ranges.size()}};
    }
    if (method == "create_torrent") {
        auto source = fs::path(absolute_path(string_param(params, "path"))).lexically_normal();
        auto destination = absolute_path(string_param(params, "output"));
        bool private_torrent = bool_param(params, "private");
        const auto& trackers = required(params, "trackers");
        if (!trackers.is_array() || trackers.as_array().size() > 50)
            throw RequestError("invalid_params", "Expected at most 50 trackers");
        for (const auto& url : trackers.as_array()) {
            if (!url.is_string()) throw RequestError("invalid_params", "Expected tracker URL");
            validate_tracker(std::string(url.as_string()));
        }
        if (!fs::exists(source) || fs::is_symlink(source) || (!fs::is_directory(source) && !fs::is_regular_file(source)))
            throw RequestError("io_error", "Expected a file or directory");
        if (fs::exists(destination)) throw RequestError("conflict", "Destination already exists");
        if (fs::is_directory(source)) {
            for (const auto& entry : fs::recursive_directory_iterator(source))
                if (entry.is_symlink()) throw RequestError("invalid_params", "Symbolic links cannot be included");
        }
        lt::file_storage files;
        lt::add_files(files, source.string());
        if (files.num_files() == 0) throw RequestError("invalid_params", "Source contains no files");
        lt::create_torrent creator(files, 0); // 不传 v1_only/v2_only，生成自动分块的混合种子。
        creator.set_priv(private_torrent);
        int tier = 0;
        for (const auto& url : trackers.as_array()) creator.add_tracker(std::string(url.as_string()), tier++);
        if (params.contains("comment")) creator.set_comment(string_param(params, "comment").c_str());
        lt::error_code error;
        lt::set_piece_hashes(creator, source.parent_path().string(), error);
        if (error) throw RequestError("io_error", error.message());
        auto buffer = creator.generate_buf();
        persistence_.write_torrent(destination, buffer);
        lt::torrent_info info(lt::span<char const>(buffer), error, lt::from_span);
        if (error) throw RequestError("invalid_torrent", error.message());
        return {{"path", destination}, {"id", torrent_id(info.info_hashes())}};
    }
    auto& torrent = find(params);
    auto& handle = torrent.handle;
    if (method == "trackers") return tracker_list(torrent);
    if (method == "set_trackers") {
        const auto& values = required(params, "trackers");
        if (!values.is_array() || values.as_array().size() > 50)
            throw RequestError("invalid_params", "Expected at most 50 trackers");
        std::vector<lt::announce_entry> trackers;
        json::object states;
        for (const auto& value : values.as_array()) {
            if (!value.is_object()) throw RequestError("invalid_params", "Expected tracker object");
            const auto& item = value.as_object();
            auto url = string_param(item, "url");
            validate_tracker(url);
            int tier = int_param(item, "tier", 255);
            if (std::any_of(trackers.begin(), trackers.end(), [&](const auto& entry) { return entry.url == url; }))
                throw RequestError("invalid_params", "Duplicate tracker URL");
            lt::announce_entry entry(url);
            entry.tier = static_cast<std::uint8_t>(tier);
            trackers.push_back(entry);
            bool subscription = item.contains("subscription") ? bool_param(item, "subscription") : false;
            auto existing = torrent.metadata.tracker_state.if_contains(url);
            states[url] = existing ? *existing : json::value(json::object{
                {"subscription", subscription}, {"tier", tier}, {"failures", 0},
                {"disabled_until", 0}, {"last_result", ""}, {"peers", 0}});
            states[url].as_object()["tier"] = tier;
            states[url].as_object()["subscription"] = subscription;
            if (!subscription) states[url].as_object()["disabled_until"] = 0;
        }
        torrent.metadata.tracker_state = std::move(states);
        handle.replace_trackers(trackers);
        refresh_trackers(torrent);
        save(torrent);
        persistence_.save_meta(string_param(params, "id"), torrent.metadata);
        return {};
    }
    if (method == "peers") {
        std::vector<lt::peer_info> peers;
        handle.get_peer_info(peers);
        json::array result;
        for (const auto& peer : peers) {
            json::array sources;
            if (peer.source & lt::peer_info::tracker) sources.push_back("tracker");
            if (peer.source & lt::peer_info::dht) sources.push_back("dht");
            if (peer.source & lt::peer_info::pex) sources.push_back("pex");
            if (peer.source & lt::peer_info::lsd) sources.push_back("lsd");
            if (peer.source & lt::peer_info::incoming) sources.push_back("incoming");
            result.push_back(json::object{{"address", peer.ip.address().to_string()}, {"port", peer.ip.port()},
                {"client", peer.client}, {"progress", static_cast<double>(peer.progress)},
                {"download_rate", peer.payload_down_speed}, {"upload_rate", peer.payload_up_speed},
                {"sources", sources}, {"connection", (peer.flags & lt::peer_info::utp_socket) ? "utp" : "tcp"}});
        }
        return {{"peers", result}};
    }
    if (method == "force_recheck" || method == "force_reannounce") {
        if (method == "force_recheck") handle.force_recheck();
        else handle.force_reannounce(0, -1, lt::torrent_handle::ignore_min_interval);
        save(torrent);
        return {};
    }
    auto info = handle.torrent_file();
    if (!info) throw RequestError("metadata_pending", "Retry after torrent metadata is available");
    if (method == "export_torrent") {
        auto output = absolute_path(string_param(params, "output"));
        // v2 完整哈希树只在 resume data 中，不能用 torrent_file() 直接往返导出。
        auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(10);
        while (pending_resume_.count(handle) && std::chrono::steady_clock::now() < deadline) {
            session_.wait_for_alert(std::chrono::milliseconds(25));
            alerts();
        }
        if (pending_resume_.count(handle)) throw RequestError("io_error", "Pending resume save timed out");
        export_handle_ = handle;
        export_resume_.reset();
        export_error_.clear();
        save(torrent);
        while (!export_resume_ && export_error_.empty() && std::chrono::steady_clock::now() < deadline) {
            session_.wait_for_alert(std::chrono::milliseconds(25));
            alerts();
        }
        export_handle_ = {};
        if (!export_error_.empty()) throw RequestError("io_error", export_error_);
        if (!export_resume_) throw RequestError("io_error", "Export resume save timed out");
        auto add = std::move(*export_resume_);
        export_resume_.reset();
        add.trackers.clear();
        add.tracker_tiers.clear();
        // 保留原始 info 和 v2 piece layers，同时使用编辑后的 tracker。
        for (const auto& tracker : handle.trackers()) {
            add.trackers.push_back(tracker.url);
            add.tracker_tiers.push_back(tracker.tier);
        }
        auto buffer = lt::write_torrent_file_buf(add, {});
        persistence_.write_torrent(output, buffer);
        return {{"path", output}, {"id", torrent_id(info->info_hashes())}};
    }
    storage_handle_ = handle;
    storage_error_.clear();
    storage_error_code_ = "io_error";
    storage_pending_ = 0;
    if (method == "move_storage") {
        auto path = absolute_path(string_param(params, "path"));
        auto conflict = string_param(params, "conflict");
        if (conflict != "fail" && conflict != "keep" && conflict != "overwrite")
            throw RequestError("invalid_params", "conflict must be fail, keep or overwrite");
        if (fs::path(path).lexically_normal() == fs::path(handle.status().save_path).lexically_normal()) return {};
        if (conflict == "fail") {
            for (auto index : info->files().file_range())
                if (fs::exists(fs::path(path) / info->files().file_path(index)))
                    throw RequestError("conflict", "Destination contains a torrent file");
        }
        fs::create_directories(path);
        auto original_flags = handle.flags();
        auto restore_activity = [&] {
            if (original_flags & lt::torrent_flags::auto_managed) handle.set_flags(lt::torrent_flags::auto_managed);
            if (!(original_flags & lt::torrent_flags::paused)) handle.resume();
        };
        if (conflict == "keep") {
            // 接管目标文件前先停写，校验后再恢复，避免覆盖选择保留的内容。
            handle.unset_flags(lt::torrent_flags::auto_managed);
            handle.pause();
        }
        storage_pending_ = 1;
        handle.move_storage(path, conflict == "fail" ? lt::move_flags_t::fail_if_exist
            : conflict == "keep" ? lt::move_flags_t::dont_replace : lt::move_flags_t::always_replace_files);
        try { wait_storage(); } catch (...) {
            if (conflict == "keep") restore_activity();
            throw;
        }
        if (conflict == "keep") {
            handle.force_recheck();
            restore_activity();
        }
    } else if (method == "rename_file") {
        auto from = string_param(params, "path");
        auto to = string_param(params, "new_path");
        validate_relative(from);
        validate_relative(to);
        std::vector<std::pair<lt::file_index_t, std::string>> changes;
        for (auto index : info->files().file_range()) {
            auto key = std::to_string(static_cast<int>(index));
            auto original = torrent.metadata.original_paths.if_contains(key);
            auto name = original ? std::string(original->as_string()) : info->files().file_path(index);
            if (name == from || name.compare(0, from.size() + 1, from + "/") == 0) {
                auto replacement = to + name.substr(from.size());
                auto current = info->files().file_path(index);
                auto storage_replacement = replacement + (original && current != name ? ".mulee" : "");
                auto directory = fs::path(handle.status().save_path);
                if (replacement != name && (fs::exists(directory / replacement) || fs::exists(directory / storage_replacement)))
                    throw RequestError("conflict", "Rename destination exists");
                for (auto other : info->files().file_range()) {
                    if (other == index) continue;
                    auto other_storage = info->files().file_path(other);
                    auto other_original = torrent.metadata.original_paths.if_contains(std::to_string(static_cast<int>(other)));
                    auto other_name = other_original ? std::string(other_original->as_string()) : other_storage;
                    if (other_storage == replacement || other_storage == storage_replacement
                        || other_name == replacement || other_name == storage_replacement)
                        throw RequestError("conflict", "Rename collides with another torrent file");
                }
                changes.emplace_back(index, replacement);
            }
        }
        if (changes.empty()) throw RequestError("not_found", "File or folder not found");
        if (from == to) return {};
        for (const auto& change : changes) {
            storage_pending_ = 1;
            auto key = std::to_string(static_cast<int>(change.first));
            auto current = info->files().file_path(change.first);
            bool marked = torrent.metadata.original_paths.contains(key) && current != std::string(torrent.metadata.original_paths.at(key).as_string());
            handle.rename_file(change.first, change.second + (marked ? ".mulee" : ""));
            wait_storage();
            if (torrent.metadata.original_paths.contains(key)) torrent.metadata.original_paths[key] = change.second;
        }
    }
    save(torrent);
    return {};
}

json::object Session::execute(const std::string& method, const json::object& params) {
    if (method == "move_storage" || method == "rename_file" || method == "force_recheck"
        || method == "force_reannounce" || method == "trackers" || method == "set_trackers"
        || method == "peers" || method == "ban_ip" || method == "import_ip_blocklist"
        || method == "create_torrent" || method == "export_torrent") return manage(method, params);
    if (method == "configure") return configure(params);
    if (method == "set_extra_port_mappings") return set_extra_port_mappings(params);
    if (method == "add") return add(params);
    if (method == "list") {
        json::array result;
        for (auto& entry : torrents_) {
            std::string update_error;
            try { update_incomplete_files(entry.second); }
            catch (const RequestError& error) { update_error = error.code; }
            catch (const std::exception&) { update_error = "io_error"; }
            if (!update_error.empty()) {
                auto snapshot = serialize_torrent(entry.first, entry.second);
                snapshot["state"] = "error";
                snapshot["error"] = update_error;
                snapshot["is_finished"] = false;
                result.push_back(std::move(snapshot));
                continue;
            }
            auto status = entry.second.handle.status();
            auto& metadata = entry.second.metadata;
            auto duration = status.finished_duration.count();
            auto payload = status.all_time_upload + status.all_time_download;
            // 只累计活跃且已完成的时间，重启和暂停不会丢失已有不活跃计数。
            if (payload != metadata.last_payload_total || !status.is_finished)
                metadata.seed_inactive_seconds = 0;
            else metadata.seed_inactive_seconds += std::max<std::int64_t>(0, duration - metadata.last_finished_duration);
            metadata.last_finished_duration = duration;
            metadata.last_payload_total = payload;
            if (status.has_metadata && status.is_finished) {
                mark_completed(entry.second);
            } else if (status.has_metadata && !entry.second.metadata.completed_at.is_null()
                && status.state == lt::torrent_status::downloading) {
                entry.second.metadata.completed_at = nullptr;
                persistence_.save_meta(entry.first, entry.second.metadata);
            }
            sample_diagnostics(entry.second);
            result.push_back(serialize_torrent(entry.first, entry.second));
        }
        return {{"torrents", result}};
    }
    if (method == "session_status") return session_status();
    if (method == "shutdown") {
        // Acknowledge only after every torrent's disk cache and resume metadata
        // have been saved. The parent may then bound best-effort network cleanup.
        shutdown();
        return {{"saved", true}};
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
    if (method == "set_download_mode") {
        auto& torrent = find(params);
        bool sequential = bool_param(params, "sequential_download");
        bool edges = bool_param(params, "first_last_priority");
        torrent.metadata.sequential_download = sequential;
        torrent.metadata.first_last_priority = edges;
        apply_download_mode(torrent);
        persistence_.save_meta(string_param(params, "id"), torrent.metadata);
        save(torrent);
        return {{"sequential_download", sequential}, {"first_last_priority", edges}};
    }
    if (method == "add_trackers") return add_trackers(find(params), params);
    if (method == "set_streaming") {
        auto& torrent = find(params);
        auto info = torrent.handle.torrent_file();
        if (!info) throw RequestError("metadata_pending", "Torrent has no metadata");
        int index = int_param(params, "file_index");
        if (index >= info->num_files() || info->files().pad_file_at(lt::file_index_t{index}))
            throw RequestError("invalid_params", "Invalid streaming file index");
        bool enabled = bool_param(params, "enabled");
        auto priorities = torrent.handle.get_file_priorities();
        auto previous = torrent.metadata.streaming_file;
        if (previous >= 0 && previous < static_cast<int>(priorities.size()) && (!enabled || previous != index)
            && priorities.at(previous) == lt::top_priority)
            priorities.at(previous) = lt::download_priority_t{static_cast<std::uint8_t>(torrent.metadata.streaming_previous_priority)};
        if (enabled) {
            if (previous != index)
                torrent.metadata.streaming_previous_priority = static_cast<std::uint8_t>(priorities.at(index));
            // 目标文件排在其他文件前面，顺序模式才会继续缓冲它的开头而非先下载别的文件。
            priorities.at(index) = lt::top_priority;
        }
        torrent.handle.prioritize_files(priorities);
        torrent.metadata.streaming_file = enabled ? index : -1;
        torrent.metadata.sequential_download = enabled;
        torrent.metadata.first_last_priority = enabled;
        apply_download_mode(torrent);
        persistence_.save_meta(string_param(params, "id"), torrent.metadata);
        save(torrent);
        json::array pieces;
        for (auto piece : torrent.priority_pieces) pieces.push_back(static_cast<int>(piece));
        return {{"file_index", index}, {"priority_pieces", pieces}};
    }
    if (method == "files") {
        auto& torrent = find(params);
        update_incomplete_files(torrent);
        return {{"files", serialize_files(torrent)}};
    }
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
