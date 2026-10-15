#include "persistence.hpp"

#include <cerrno>
#include <ctime>
#include <fcntl.h>
#include <fstream>
#include <iostream>
#include <iterator>
#include <libtorrent/read_resume_data.hpp>
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
        {"completed_at", metadata.completed_at}});
    atomic_write(directory_ / "meta" / (id + ".json"), text.data(), text.size());
}

void Persistence::save_resume(const std::string& id, const lt::add_torrent_params& params) {
    auto buffer = lt::write_resume_data_buf(params);
    atomic_write(directory_ / "resume" / (id + ".resume"), buffer.data(), buffer.size());
}

void Persistence::remove(const std::string& id) {
    for (const auto& path : {directory_ / "resume" / (id + ".resume"), directory_ / "meta" / (id + ".json")}) {
        fs::remove(path);
        fs::remove(path.string() + ".tmp");
    }
}
}
