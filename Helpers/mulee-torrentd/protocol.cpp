#include "protocol.hpp"

#include <cerrno>
#include <filesystem>
#include <iostream>
#include <poll.h>
#include <unistd.h>

namespace mulee {
RequestError::RequestError(std::string error_code, const std::string& message)
    : std::runtime_error(message), code(std::move(error_code)) {}

Protocol::~Protocol() {
    stop_ = true;
    if (reader_.joinable()) reader_.join();
}

void Protocol::start() {
    reader_ = std::thread(&Protocol::read_input, this);
}

void Protocol::read_input() {
    std::string pending;
    char buffer[8192];
    while (!stop_) {
        pollfd descriptor{STDIN_FILENO, POLLIN, 0};
        int result = poll(&descriptor, 1, 100);
        if (result < 0 && errno == EINTR) continue;
        if (result == 0) continue;
        ssize_t count = result < 0 ? -1 : read(STDIN_FILENO, buffer, sizeof(buffer));
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) {
            std::lock_guard<std::mutex> guard(input_mutex_);
            if (!pending.empty()) lines_.push_back(std::move(pending));
            eof_ = true;
            return;
        }
        pending.append(buffer, static_cast<std::size_t>(count));
        std::size_t begin = 0;
        for (;;) {
            auto end = pending.find('\n', begin);
            if (end == std::string::npos) break;
            std::lock_guard<std::mutex> guard(input_mutex_);
            lines_.push_back(pending.substr(begin, end - begin));
            begin = end + 1;
        }
        pending.erase(0, begin);
    }
}

bool Protocol::pop(std::string& line) {
    std::lock_guard<std::mutex> guard(input_mutex_);
    if (lines_.empty()) return false;
    line = std::move(lines_.front());
    lines_.pop_front();
    return true;
}

bool Protocol::ended() {
    std::lock_guard<std::mutex> guard(input_mutex_);
    return eof_ && lines_.empty();
}

void Protocol::send(const json::object& message) {
    std::lock_guard<std::mutex> guard(output_mutex_);
    std::cout << json::serialize(message) << '\n' << std::flush;
}

void Protocol::respond(const json::value& id, const json::object& result) {
    send({{"id", id}, {"result", result}});
}

void Protocol::fail(const json::value& id, const std::string& code, const std::string& message) {
    send({{"id", id}, {"error", {{"code", code}, {"message", message}}}});
}

const json::value& required(const json::object& object, const char* key) {
    auto value = object.if_contains(key);
    if (!value) throw RequestError("invalid_params", std::string("Missing ") + key);
    return *value;
}

std::string string_param(const json::object& object, const char* key) {
    const auto& value = required(object, key);
    if (!value.is_string()) throw RequestError("invalid_params", std::string(key) + " must be a string");
    std::string text(value.as_string());
    if (text.find('\0') != std::string::npos) throw RequestError("invalid_params", "Embedded NUL");
    return text;
}

int int_param(const json::object& object, const char* key, int maximum) {
    const auto& value = required(object, key);
    if (!value.is_int64() || value.as_int64() < 0 || value.as_int64() > maximum)
        throw RequestError("invalid_params", std::string(key) + " must be a nonnegative integer in range");
    return static_cast<int>(value.as_int64());
}

bool bool_param(const json::object& object, const char* key) {
    const auto& value = required(object, key);
    if (!value.is_bool()) throw RequestError("invalid_params", std::string(key) + " must be a boolean");
    return value.as_bool();
}

std::string absolute_path(const std::string& path) {
    if (path.empty() || !std::filesystem::path(path).is_absolute())
        throw RequestError("invalid_params", "Path must be absolute");
    return std::filesystem::path(path).lexically_normal().string();
}
}
