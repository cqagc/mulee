#pragma once

#include <boost/json.hpp>
#include <atomic>
#include <deque>
#include <mutex>
#include <string>
#include <thread>

namespace mulee {
namespace json = boost::json;

struct RequestError : std::runtime_error {
    std::string code;
    RequestError(std::string code, const std::string& message);
};

class Protocol {
public:
    ~Protocol();
    void start();
    bool pop(std::string& line);
    bool ended();
    void send(const json::object& message);
    void respond(const json::value& id, const json::object& result);
    void fail(const json::value& id, const std::string& code, const std::string& message);

private:
    void read_input();
    std::mutex input_mutex_;
    std::mutex output_mutex_;
    std::deque<std::string> lines_;
    bool eof_ = false;
    std::atomic<bool> stop_{false};
    std::thread reader_;
};

const json::value& required(const json::object& object, const char* key);
std::string string_param(const json::object& object, const char* key);
int int_param(const json::object& object, const char* key, int maximum = 2147483647);
bool bool_param(const json::object& object, const char* key);
std::string absolute_path(const std::string& path);
}
