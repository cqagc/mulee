#include "persistence.hpp"

#include <cerrno>
#include <ctime>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <iterator>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/bdecode.hpp>
#include <libtorrent/session_handle.hpp>
#include <libtorrent/write_resume_data.hpp>
#include <sys/file.h>
#include <sys/stat.h>
#include <unistd.h>

namespace mulee {
std::int64_t unix_time() {
    return static_cast<std::int64_t>(std::time(nullptr));
}

std::string torrent_id(const lt::info_hash_t& hashes) {
    const auto hash = hashes.get_best();
    static constexpr char hex[] = "0123456789abcdef";
    std::string result;
    // get_best() truncates a v2 hash to 20 bytes, as required by the protocol.
    const auto& selected = hashes.has_v1() ? hashes.v1 : hash;
    for (int i = 0; i < 20; ++i) {
        auto byte = static_cast<unsigned char>(selected[i]);
        result += hex[byte >> 4];
        result += hex[byte & 15];
    }
    return result;
}

Persistence::Persistence(fs::path directory) : directory_(std::move(directory)) {
    fs::create_directories(directory_);
    if (chmod(directory_.c_str(), 0700) != 0)
        throw std::system_error(errno, std::generic_category(), "chmod state-dir");
    lock_fd_ = open((directory_ / "lock").c_str(), O_CREAT | O_RDWR | O_CLOEXEC, 0600);
    if (lock_fd_ < 0) throw std::system_error(errno, std::generic_category(), "open lock");
    locked_ = flock(lock_fd_, LOCK_EX | LOCK_NB) == 0;
    if (!locked_) return;
    for (const char* name : {"resume", "meta", "broken"}) fs::create_directories(directory_ / name);
}

Persistence::~Persistence() {
    if (lock_fd_ >= 0) close(lock_fd_);
}

bool Persistence::locked() const {
    return locked_;
}

void Persistence::log(const std::string& message) {
    std::cerr << message << '\n';
    try {
        auto path = directory_ / "torrentd.log";
        if (fs::exists(path) && fs::file_size(path) > 5 * 1024 * 1024) {
            fs::rename(path, directory_ / "torrentd.log.1");
        }
        std::ofstream output(path, std::ios::app);
        output.exceptions(std::ios::failbit | std::ios::badbit);
        output << unix_time() << " " << message << '\n';
    } catch (const std::exception& error) {
        std::cerr << "Cannot append log: " << error.what() << '\n';
    }
}

std::vector<lt::add_torrent_params> Persistence::restore() {
    std::vector<lt::add_torrent_params> result;
    for (const auto& entry : fs::directory_iterator(directory_ / "resume")) {
        if (entry.path().extension() != ".resume") continue;
        try {
            std::ifstream input(entry.path(), std::ios::binary);
            if (!input) throw std::runtime_error("Cannot read resume file");
            std::vector<char> buffer((std::istreambuf_iterator<char>(input)), {});
            lt::error_code error;
            auto params = lt::read_resume_data(lt::span<char const>(buffer), error);
            if (error) throw std::runtime_error(error.message());
            if (params.ti) params.info_hashes = params.ti->info_hashes();
            if ((!params.info_hashes.has_v1() && !params.info_hashes.has_v2())
                || torrent_id(params.info_hashes) != entry.path().stem().string())
                throw std::runtime_error("Resume info-hash does not match its filename");
            absolute_path(params.save_path);
            result.push_back(std::move(params));
        } catch (const std::exception& error) {
            log("Broken resume " + entry.path().filename().string() + ": " + error.what());
            auto destination = directory_ / "broken" / entry.path().filename();
            if (fs::exists(destination)) destination += "." + std::to_string(unix_time());
            fs::rename(entry.path(), destination);
        }
    }
    return result;
}

Metadata Persistence::load_meta(const std::string& id) {
    Metadata metadata;
    metadata.added_at = unix_time();
    auto path = directory_ / "meta" / (id + ".json");
    if (!fs::exists(path)) return metadata;
    try {
        std::ifstream input(path);
        std::string text((std::istreambuf_iterator<char>(input)), {});
        auto object = json::parse(text).as_object();
        auto source = object.if_contains("source");
        if (source && (source->is_null() || source->is_string())) metadata.source = *source;
        metadata.added_at = required(object, "added_at").as_int64();
        if (auto value = object.if_contains("sequential_download"); value && value->is_bool())
            metadata.sequential_download = value->as_bool();
        if (auto value = object.if_contains("first_last_priority"); value && value->is_bool())
            metadata.first_last_priority = value->as_bool();
        if (auto value = object.if_contains("junk_pending"); value && value->is_bool())
            metadata.junk_pending = value->as_bool();
        if (auto value = object.if_contains("junk_patterns"); value && value->is_array())
            for (const auto& pattern : value->as_array())
                if (pattern.is_string()) metadata.junk_patterns.emplace_back(pattern.as_string());
        if (auto value = object.if_contains("skipped_files"); value && value->is_array())
            metadata.skipped_files = value->as_array();
        if (auto value = object.if_contains("tracker_state"); value && value->is_object())
            metadata.tracker_state = value->as_object();
        for (const auto& field : {std::make_pair("seed_inactive_seconds", &metadata.seed_inactive_seconds),
            std::make_pair("last_finished_duration", &metadata.last_finished_duration),
            std::make_pair("last_payload_total", &metadata.last_payload_total)}) {
            if (auto value = object.if_contains(field.first); value && value->is_int64() && value->as_int64() >= 0)
                *field.second = value->as_int64();
        }
        if (auto value = object.if_contains("mark_incomplete"); value && value->is_bool())
            metadata.mark_incomplete = value->as_bool();
        if (auto value = object.if_contains("original_paths"); value && value->is_object())
            metadata.original_paths = value->as_object();
        if (auto value = object.if_contains("streaming_file"); value && value->is_int64())
            metadata.streaming_file = static_cast<int>(value->as_int64());
        if (auto value = object.if_contains("streaming_previous_priority"); value && value->is_int64()
            && value->as_int64() >= 0 && value->as_int64() <= 7)
            metadata.streaming_previous_priority = static_cast<int>(value->as_int64());
        for (const auto& field : {std::make_pair("user_download_limit", &metadata.user_download_limit),
            std::make_pair("user_upload_limit", &metadata.user_upload_limit),
            std::make_pair("policy_upload_limit", &metadata.policy_upload_limit)}) {
            if (auto value = object.if_contains(field.first); value && value->is_int64()
                && value->as_int64() >= 0 && value->as_int64() <= 2147483647)
                *field.second = static_cast<int>(value->as_int64());
        }
        auto completed = object.if_contains("completed_at");
        if (completed && (completed->is_null() || completed->is_int64())) metadata.completed_at = *completed;
    } catch (const std::exception& error) {
        log("Cannot read metadata " + id + ": " + error.what());
    }
    return metadata;
}

void Persistence::atomic_write(const fs::path& destination, const char* data, std::size_t size) {
    auto temporary = destination;
    temporary += ".tmp";
    int descriptor = open(temporary.c_str(), O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0600);
    if (descriptor < 0) throw std::system_error(errno, std::generic_category(), "open temporary file");
    try {
        while (size > 0) {
            auto count = write(descriptor, data, size);
            if (count < 0 && errno == EINTR) continue;
            if (count <= 0) throw std::system_error(errno, std::generic_category(), "write temporary file");
            data += count;
            size -= static_cast<std::size_t>(count);
        }
        if (fsync(descriptor) != 0) throw std::system_error(errno, std::generic_category(), "fsync");
        close(descriptor);
        descriptor = -1;
        fs::rename(temporary, destination);
    } catch (...) {
        if (descriptor >= 0) close(descriptor);
        std::error_code ignored;
        fs::remove(temporary, ignored);
        throw;
    }
}

void Persistence::save_meta(const std::string& id, const Metadata& metadata) {
    auto text = json::serialize(json::object{{"source", metadata.source}, {"added_at", metadata.added_at},
        {"completed_at", metadata.completed_at}, {"sequential_download", metadata.sequential_download},
        {"first_last_priority", metadata.first_last_priority},
        {"user_download_limit", metadata.user_download_limit}, {"user_upload_limit", metadata.user_upload_limit},
        {"policy_upload_limit", metadata.policy_upload_limit},
        {"mark_incomplete", metadata.mark_incomplete}, {"original_paths", metadata.original_paths},
        {"streaming_file", metadata.streaming_file},
        {"streaming_previous_priority", metadata.streaming_previous_priority}, {"junk_pending", metadata.junk_pending},
        {"junk_patterns", json::value_from(metadata.junk_patterns)}, {"skipped_files", metadata.skipped_files},
        {"tracker_state", metadata.tracker_state}, {"seed_inactive_seconds", metadata.seed_inactive_seconds},
        {"last_finished_duration", metadata.last_finished_duration}, {"last_payload_total", metadata.last_payload_total}});
    atomic_write(directory_ / "meta" / (id + ".json"), text.data(), text.size());
}

void Persistence::save_resume(const std::string& id, const lt::add_torrent_params& params) {
    auto buffer = lt::write_resume_data_buf(params);
    atomic_write(directory_ / "resume" / (id + ".resume"), buffer.data(), buffer.size());
}

lt::session_params Persistence::load_dht() {
    auto path = directory_ / "dht.state";
    try {
        if (!fs::exists(path)) return {};
        if (fs::file_size(path) > 4 * 1024 * 1024) throw std::runtime_error("DHT state is too large");
        std::ifstream input(path, std::ios::binary);
        if (!input) throw std::runtime_error("Cannot read DHT state");
        std::vector<char> buffer((std::istreambuf_iterator<char>(input)), {});
        auto node = lt::bdecode(lt::span<char const>(buffer));
        if (node.data_section().size() != static_cast<std::ptrdiff_t>(buffer.size())
            || node.type() != lt::bdecode_node::dict_t || !node.dict_find_dict("dht state"))
            throw std::runtime_error("Missing DHT state dictionary");
        auto state = node.dict_find_dict("dht state");
        for (const auto& key : {"node-id", "nodes", "nodes6"}) {
            auto value = state.dict_find(key);
            if (!value) continue;
            if (std::string(key) == "node-id" && value.type() == lt::bdecode_node::string_t
                && value.string_length() == 20) continue; // Legacy single node ID.
            if (value.type() != lt::bdecode_node::list_t) throw std::runtime_error("Invalid DHT list");
            for (int i = 0; i < value.list_size(); ++i) {
                auto item = value.list_at(i);
                int size = item.type() == lt::bdecode_node::string_t ? item.string_length() : 0;
                bool valid = std::string(key) == "node-id" ? size == 24 || size == 36
                    : std::string(key) == "nodes" ? size == 6 : size == 18;
                if (!valid) throw std::runtime_error("Invalid DHT node encoding");
            }
        }
        auto params = lt::read_session_params(node, lt::session_handle::save_dht_state);
        log("Loaded DHT state: " + std::to_string(params.dht_state.nids.size()) + " node IDs, "
            + std::to_string(params.dht_state.nodes.size() + params.dht_state.nodes6.size()) + " bootstrap nodes");
        return params;
    } catch (const std::exception& error) {
        log(std::string("Ignoring damaged DHT state: ") + error.what());
        return {};
    }
}

void Persistence::save_dht(const lt::session_params& params) {
    auto buffer = lt::write_session_params_buf(params, lt::session_handle::save_dht_state);
    atomic_write(directory_ / "dht.state", buffer.data(), buffer.size());
}

json::object Persistence::load_filters() {
    auto path = directory_ / "ip-filters.json";
    if (!fs::exists(path)) return {};
    std::ifstream input(path);
    std::string text((std::istreambuf_iterator<char>(input)), {});
    return json::parse(text).as_object();
}

void Persistence::save_filters(const json::object& filters) {
    auto text = json::serialize(filters);
    atomic_write(directory_ / "ip-filters.json", text.data(), text.size());
}

void Persistence::write_torrent(const fs::path& path, const std::vector<char>& buffer) {
    if (fs::exists(path)) throw RequestError("conflict", "Destination already exists");
    atomic_write(path, buffer.data(), buffer.size());
}

void Persistence::remove(const std::string& id) {
    for (const auto& path : {directory_ / "resume" / (id + ".resume"), directory_ / "meta" / (id + ".json")}) {
        fs::remove(path);
        fs::remove(path.string() + ".tmp");
    }
}
}
