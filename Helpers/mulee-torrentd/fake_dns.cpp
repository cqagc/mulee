#include "fake_dns.hpp"

#include <algorithm>
#include <array>
#include <cctype>
#include <chrono>
#include <functional>
#include <iostream>
#include <limits>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <stdexcept>
#include <boost/asio.hpp>
#include <libtorrent/aux_/resolver.hpp>
#include <libtorrent/enum_net.hpp>
#include <net/if.h>
#include <netinet/in.h>

namespace mulee {
namespace {
namespace asio = boost::asio;
namespace lt = libtorrent;
using Addresses = std::vector<lt::address>;
using Bytes = std::vector<std::uint8_t>;
using Clock = std::chrono::steady_clock;
using Callback = lt::aux::resolver_interface::callback_t;
using UDP = asio::ip::udp;
using TCP = asio::ip::tcp;

std::mutex log_mutex;
std::vector<std::string> logs;

bool fake(const lt::address& address) {
    if (address.is_v6() && address.to_v6().is_v4_mapped()) {
        auto bytes = address.to_v6().to_bytes();
        lt::address_v4::bytes_type v4;
        std::copy_n(bytes.begin() + 12, 4, v4.begin());
        return fake(lt::address_v4(v4));
    }
    return address.is_v4() && (address.to_v4().to_uint() & 0xfffe0000U) == 0xc6120000U;
}

bool needs_lookup(const Addresses& addresses) {
    return !addresses.empty() && std::all_of(addresses.begin(), addresses.end(), fake);
}

std::string canonical(std::string name) {
    if (!name.empty() && name.back() == '.') name.pop_back();
    for (char& c : name) c = static_cast<char>(std::tolower(static_cast<unsigned char>(c)));
    return name;
}

void put16(Bytes& bytes, unsigned value) {
    bytes.push_back(static_cast<std::uint8_t>(value >> 8));
    bytes.push_back(static_cast<std::uint8_t>(value));
}

unsigned get16(const Bytes& bytes, std::size_t offset) {
    if (offset + 2 > bytes.size()) throw std::runtime_error("short DNS field");
    return (unsigned(bytes[offset]) << 8) | bytes[offset + 1];
}

std::uint32_t get32(const Bytes& bytes, std::size_t offset) {
    return (std::uint32_t(get16(bytes, offset)) << 16) | get16(bytes, offset + 2);
}

Bytes question(const std::string& host, unsigned type, unsigned id) {
    auto name = canonical(host);
    if (name.empty() || name.size() > 253) throw std::runtime_error("invalid DNS name");
    Bytes bytes;
    for (unsigned word : {id, 0x0100U, 1U, 0U, 0U, 0U}) put16(bytes, word);
    std::size_t start = 0;
    while (start < name.size()) {
        auto end = name.find('.', start);
        if (end == std::string::npos) end = name.size();
        auto size = end - start;
        if (size == 0 || size > 63) throw std::runtime_error("invalid DNS label");
        bytes.push_back(static_cast<std::uint8_t>(size));
        for (auto i = start; i < end; ++i) {
            unsigned char c = name[i];
            if (!(std::isalnum(c) || c == '-' || c == '_'))
                throw std::runtime_error("invalid DNS label character");
            bytes.push_back(c);
        }
        start = end + 1;
    }
    bytes.push_back(0);
    put16(bytes, type);
    put16(bytes, 1);
    return bytes;
}

std::string read_name(const Bytes& bytes, std::size_t& cursor) {
    std::string name;
    auto offset = cursor;
    bool jumped = false;
    for (unsigned hops = 0; hops < 128; ++hops) {
        if (offset >= bytes.size()) throw std::runtime_error("short DNS name");
        unsigned size = bytes[offset++];
        if ((size & 0xc0) == 0xc0) {
            if (offset >= bytes.size()) throw std::runtime_error("short DNS pointer");
            auto target = ((size & 0x3f) << 8) | bytes[offset++];
            if (target >= offset - 2) throw std::runtime_error("invalid DNS pointer");
            if (!jumped) cursor = offset;
            jumped = true;
            offset = target;
            continue;
        }
        if (size & 0xc0) throw std::runtime_error("invalid DNS label");
        if (size == 0) {
            if (!jumped) cursor = offset;
            return canonical(name);
        }
        if (offset + size > bytes.size()) throw std::runtime_error("short DNS label");
        if (!name.empty()) name += '.';
        name.append(reinterpret_cast<const char*>(bytes.data() + offset), size);
        if (name.size() > 253) throw std::runtime_error("long DNS name");
        offset += size;
    }
    throw std::runtime_error("DNS compression loop");
}

struct Answer {
    Addresses addresses;
    std::uint32_t ttl = std::numeric_limits<std::uint32_t>::max();
    bool truncated = false;
};

// Only accept the queried owner or its CNAME chain, never unrelated glue.
std::optional<Answer> answer(const Bytes& bytes, const Bytes& query) {
    try {
        if (bytes.size() < 12 || get16(bytes, 0) != get16(query, 0)
            || (get16(bytes, 2) & 0xf80f) != 0x8000 || get16(bytes, 4) != 1) return {};
        std::size_t cursor = 12;
        std::size_t query_cursor = 12;
        auto host = read_name(query, query_cursor);
        if (read_name(bytes, cursor) != host || get16(bytes, cursor) != get16(query, query_cursor)
            || get16(bytes, cursor + 2) != 1) return {};
        auto type = get16(query, query_cursor);
        cursor += 4;
        Answer result;
        result.truncated = (get16(bytes, 2) & 0x0200) != 0;
        if (result.truncated) return result;
        struct Record {
            std::string owner;
            std::string alias;
            std::optional<lt::address> address;
            std::uint32_t ttl;
        };
        std::vector<Record> records;
        auto count = get16(bytes, 6);
        if (count > 512) return {};
        for (unsigned i = 0; i < count; ++i) {
            auto owner = read_name(bytes, cursor);
            auto record_type = get16(bytes, cursor);
            auto klass = get16(bytes, cursor + 2);
            auto ttl = get32(bytes, cursor + 4);
            auto size = get16(bytes, cursor + 8);
            cursor += 10;
            auto end = cursor + size;
            if (end > bytes.size()) return {};
            Record record{owner, {}, {}, ttl};
            if (klass == 1 && record_type == 5) {
                auto alias_cursor = cursor;
                record.alias = read_name(bytes, alias_cursor);
                if (alias_cursor != end) return {};
            } else if (klass == 1 && record_type == type && type == 1 && size == 4) {
                lt::address_v4::bytes_type data;
                std::copy_n(bytes.begin() + cursor, 4, data.begin());
                record.address = lt::address_v4(data);
            } else if (klass == 1 && record_type == type && type == 28 && size == 16) {
                lt::address_v6::bytes_type data;
                std::copy_n(bytes.begin() + cursor, 16, data.begin());
                record.address = lt::address_v6(data);
            }
            records.push_back(std::move(record));
            cursor = end;
        }
        for (unsigned depth = 0; depth < 16; ++depth) {
            auto alias = std::find_if(records.begin(), records.end(), [&](const auto& record) {
                return record.owner == host && !record.alias.empty();
            });
            if (alias == records.end()) break;
            result.ttl = std::min(result.ttl, alias->ttl);
            host = alias->alias;
            if (depth == 15) return {};
        }
        for (const auto& record : records) {
            if (record.owner != host || !record.address) continue;
            // A public DNS returning another fake address is a failed bypass.
            if (fake(*record.address) || record.address->is_unspecified() || record.address->is_multicast()) return {};
            result.ttl = std::min(result.ttl, record.ttl);
            if (std::find(result.addresses.begin(), result.addresses.end(), *record.address) == result.addresses.end())
                result.addresses.push_back(*record.address);
        }
        return result;
    } catch (const std::exception&) {
        return {};
    }
}

struct Binding {
    unsigned index;
    lt::address address;
};

std::vector<Binding> physical_interfaces(lt::io_context& ios) {
    lt::error_code ec;
    auto routes = lt::enum_routes(ios, ec);
    if (ec) return {};
    auto interfaces = lt::enum_net_interfaces(ios, ec);
    if (ec) return {};
    std::vector<Binding> result;
    for (const auto& item : interfaces) {
        const auto& ip = item.interface_address;
        if (!(item.flags & lt::if_flags::up) || (item.flags & lt::if_flags::loopback)
            || (item.flags & lt::if_flags::pointopoint) || std::string(item.name).find("utun") == 0
            || !ip.is_v4() || ip.is_loopback() || ip.is_unspecified()
            || (ip.to_v4().to_uint() & 0xffff0000U) == 0xa9fe0000U
            || fake(ip) || !lt::get_gateway(item, routes)) continue;
        auto index = if_nametoindex(item.name);
        if (index) result.push_back({index, ip});
    }
    return result;
}

template <class Socket>
bool bind_physical(Socket& socket, const Binding& binding) {
    // All configured DNS servers use IPv4 transport, including AAAA queries.
    // Fail closed: never silently retry through the default (possibly TUN) route.
    if (setsockopt(socket.native_handle(), IPPROTO_IP, IP_BOUND_IF,
                   &binding.index, sizeof(binding.index)) != 0) return false;
    lt::error_code ec;
    socket.bind(typename Socket::endpoint_type(binding.address, 0), ec);
    return !ec;
}

// One 2-second budget covers UDP and a possible TCP retry. Every operation is
// asynchronous on libtorrent's io_context; closing cancels outstanding handlers.
class Exchange : public std::enable_shared_from_this<Exchange> {
public:
    using Completion = std::function<void(std::optional<Answer>)>;
    Exchange(lt::io_context& ios, Binding binding, UDP::endpoint server, Bytes query,
             std::chrono::milliseconds timeout, Completion completion)
        : udp_(ios), tcp_(ios), timer_(ios), binding_(binding), server_(server),
          query_(std::move(query)), timeout_(timeout), completion_(std::move(completion)) {}

    void start() {
        auto self = shared_from_this();
        timer_.expires_after(timeout_);
        timer_.async_wait([self](const auto& ec) {
            if (!ec) self->finish({});
        });
        lt::error_code ec;
        udp_.open(UDP::v4(), ec);
        if (ec || !bind_physical(udp_, binding_)) return finish({});
        udp_.connect(server_, ec);
        if (ec) return finish({});
        udp_.async_send(asio::buffer(query_), [self](const auto& error, std::size_t) {
            if (self->done_) return;
            if (error) self->finish({});
            else self->receive();
        });
    }

private:
    UDP::socket udp_;
    TCP::socket tcp_;
    asio::steady_timer timer_;
    Binding binding_;
    UDP::endpoint server_;
    Bytes query_;
    Bytes frame_;
    Bytes response_;
    std::array<std::uint8_t, 65536> buffer_{};
    std::chrono::milliseconds timeout_;
    Completion completion_;
    bool done_ = false;

    void finish(std::optional<Answer> result) {
        if (done_) return;
        done_ = true;
        lt::error_code ignored;
        timer_.cancel();
        udp_.close(ignored);
        tcp_.close(ignored);
        auto completion = std::move(completion_);
        completion(std::move(result));
    }

    void receive() {
        auto self = shared_from_this();
        udp_.async_receive(asio::buffer(buffer_), [self](const auto& ec, std::size_t size) {
            if (self->done_) return;
            if (ec) return self->finish({});
            auto result = answer(Bytes(self->buffer_.begin(), self->buffer_.begin() + size), self->query_);
            if (!result) return self->receive();
            if (result->truncated) self->start_tcp();
            else self->finish(std::move(result));
        });
    }

    void start_tcp() {
        lt::error_code ec;
        udp_.close(ec);
        tcp_.open(TCP::v4(), ec);
        if (ec || !bind_physical(tcp_, binding_)) return finish({});
        put16(frame_, static_cast<unsigned>(query_.size()));
        frame_.insert(frame_.end(), query_.begin(), query_.end());
        auto self = shared_from_this();
        tcp_.async_connect(TCP::endpoint(server_.address(), server_.port()), [self](const auto& error) {
            if (self->done_) return;
            if (error) return self->finish({});
            asio::async_write(self->tcp_, asio::buffer(self->frame_), [self](const auto& write_error, std::size_t) {
                if (self->done_) return;
                if (write_error) return self->finish({});
                self->read_length();
            });
        });
    }

    void read_length() {
        auto self = shared_from_this();
        asio::async_read(tcp_, asio::buffer(buffer_.data(), 2), [self](const auto& ec, std::size_t) {
            if (self->done_) return;
            if (ec) return self->finish({});
            auto size = (unsigned(self->buffer_[0]) << 8) | self->buffer_[1];
            if (size < 12) return self->finish({});
            self->response_.resize(size);
            asio::async_read(self->tcp_, asio::buffer(self->response_), [self](const auto& error, std::size_t) {
                if (self->done_) return;
                if (error) return self->finish({});
                auto result = answer(self->response_, self->query_);
                if (result && result->truncated) result.reset();
                self->finish(std::move(result));
            });
        });
    }
};

class Lookup : public std::enable_shared_from_this<Lookup> {
public:
    Lookup(lt::io_context& ios, std::vector<Binding> bindings, Bytes query, Exchange::Completion completion)
        : ios_(ios), bindings_(std::move(bindings)), query_(std::move(query)), completion_(std::move(completion)) {}

    void next() {
        static const std::array<const char*, 4> servers{"223.5.5.5", "119.29.29.29", "1.1.1.1", "8.8.8.8"};
        auto left = std::chrono::duration_cast<std::chrono::milliseconds>(deadline_ - Clock::now());
        if (bindings_.empty() || attempt_ >= servers.size() * bindings_.size() || left.count() <= 0) {
            auto completion = std::move(completion_);
            return completion({});
        }
        auto binding = bindings_[attempt_ % bindings_.size()];
        auto server = servers[attempt_ / bindings_.size()];
        ++attempt_;
        auto self = shared_from_this();
        std::make_shared<Exchange>(ios_, binding, UDP::endpoint(lt::make_address(server), 53), query_,
            std::min(left, std::chrono::milliseconds(2000)), [self](auto result) {
                if (result) {
                    auto completion = std::move(self->completion_);
                    completion(std::move(result));
                } else {
                    self->next();
                }
            })->start();
    }

private:
    lt::io_context& ios_;
    std::vector<Binding> bindings_;
    Bytes query_;
    Exchange::Completion completion_;
    std::size_t attempt_ = 0;
    Clock::time_point deadline_ = Clock::now() + std::chrono::seconds(8);
};

struct CacheEntry {
    Addresses addresses;
    Clock::time_point expires;
};

class Client : public std::enable_shared_from_this<Client> {
public:
    using Interfaces = std::function<std::vector<Binding>(lt::io_context&)>;
    explicit Client(Interfaces interfaces = physical_interfaces) : interfaces_(std::move(interfaces)) {}

    void resolve(lt::io_context& ios, const std::string& name, const Addresses& original,
                 Callback callback, bool cache_only = false) {
        if (!needs_lookup(original)) return callback({}, original);
        auto host = canonical(name);
        auto cached = cache_.find(host);
        if (cached != cache_.end() && cached->second.expires > Clock::now())
            return callback({}, cached->second.addresses);
        if (cache_only) return callback({}, original);
        // Each waiter retains its own system result for failure fallback.
        auto deliver = [original, callback = std::move(callback)](const Addresses& addresses) {
            callback({}, addresses.empty() ? original : addresses);
        };
        auto pending = pending_.find(host);
        if (pending != pending_.end()) {
            pending->second.push_back(std::move(deliver));
            return;
        }
        if (pending_.size() >= 32) return deliver({});
        Bytes a;
        Bytes aaaa;
        try {
            a = question(host, 1, arc4random_uniform(65536));
            aaaa = question(host, 28, arc4random_uniform(65536));
        } catch (const std::exception&) {
            return deliver({});
        }
        auto bindings = interfaces_(ios);
        if (bindings.empty()) return deliver({});
        pending_[host].push_back(std::move(deliver));
        struct Combined {
            Answer result;
            int remaining = 2;
        };
        auto combined = std::make_shared<Combined>();
        auto self = shared_from_this();
        auto complete = [self, host, combined](std::optional<Answer> result) {
            if (result && !result->addresses.empty()) {
                combined->result.addresses.insert(combined->result.addresses.end(),
                    result->addresses.begin(), result->addresses.end());
                combined->result.ttl = std::min(combined->result.ttl, result->ttl);
            }
            if (--combined->remaining != 0) return;
            auto& addresses = combined->result.addresses;
            if (!addresses.empty()) {
                if (self->cache_.size() >= 512) self->cache_.erase(self->cache_.begin());
                self->cache_[host] = {addresses, Clock::now() + std::chrono::seconds(combined->result.ttl)};
                std::lock_guard<std::mutex> lock(log_mutex);
                logs.push_back("检测到代理假地址，已改用公共 DNS 解析 " + host);
            }
            auto callbacks = std::move(self->pending_.at(host));
            self->pending_.erase(host);
            for (auto& callback : callbacks) callback(addresses);
        };
        std::make_shared<Lookup>(ios, bindings, std::move(a), complete)->next();
        std::make_shared<Lookup>(ios, bindings, std::move(aaaa), complete)->next();
    }

private:
    friend int mulee::test_fake_dns();
    Interfaces interfaces_;
    std::map<std::string, CacheEntry> cache_;
    std::map<std::string, std::vector<std::function<void(const Addresses&)>>> pending_;
};
}

void install_fake_ip_resolver() {
    auto client = std::make_shared<Client>();
    lt::aux::hostname_result_filter = [client](auto& ios, const auto& host, bool cache_only,
                                               const auto& addresses, auto callback) {
        client->resolve(ios, host, addresses, std::move(callback), cache_only);
    };
}

std::vector<std::string> take_dns_logs() {
    std::lock_guard<std::mutex> lock(log_mutex);
    auto result = std::move(logs);
    logs.clear();
    return result;
}

int test_fake_dns() {
    auto require = [](bool condition, const char* message) {
        if (!condition) throw std::runtime_error(message);
    };
    auto ip = [](const char* value) { return lt::make_address(value); };
    require(!needs_lookup({}), "empty result must not retry");
    require(needs_lookup({ip("198.18.0.0"), ip("198.19.255.255")}), "fake range boundaries");
    require(needs_lookup({ip("::ffff:198.18.0.1")}), "mapped fake IPv4");
    require(!needs_lookup({ip("198.17.255.255")}) && !needs_lookup({ip("198.20.0.0")}), "outside fake range");
    require(!needs_lookup({ip("198.18.0.1"), ip("192.0.2.1")}), "mixed result must not retry");
    require(!needs_lookup({ip("2001:db8::1")}), "ordinary IPv6 must not retry");

    auto query = question("Example.TEST.", 1, 0x1234);
    require(query == Bytes({0x12, 0x34, 1, 0, 0, 1, 0, 0, 0, 0, 0, 0,
        7, 'e', 'x', 'a', 'm', 'p', 'l', 'e', 4, 't', 'e', 's', 't', 0, 0, 1, 0, 1}), "query encoding");
    for (const auto& name : {std::string(), std::string("a..test"), std::string(64, 'a') + ".test", std::string("bad\n.test")}) {
        bool rejected = false;
        try { question(name, 1, 0); } catch (const std::exception&) { rejected = true; }
        require(rejected, "invalid question accepted");
    }
    auto reply = query;
    reply[2] = 0x81;
    reply[3] = 0x80;
    reply[7] = 1;
    auto record = [](Bytes& bytes, unsigned type, unsigned ttl, const Bytes& data) {
        put16(bytes, 0xc00c);
        put16(bytes, type);
        put16(bytes, 1);
        put16(bytes, ttl >> 16);
        put16(bytes, ttl);
        put16(bytes, static_cast<unsigned>(data.size()));
        bytes.insert(bytes.end(), data.begin(), data.end());
    };
    record(reply, 1, 300, {192, 0, 2, 7});
    auto parsed = answer(reply, query);
    require(parsed && parsed->addresses == Addresses{ip("192.0.2.7")} && parsed->ttl == 300, "A answer and TTL");
    for (std::size_t size = 0; size < reply.size(); ++size)
        require(!answer(Bytes(reply.begin(), reply.begin() + size), query), "short packet accepted");
    auto damaged = reply;
    damaged[0] ^= 1;
    require(!answer(damaged, query), "wrong transaction accepted");
    damaged = reply;
    damaged[13] = 'x';
    require(!answer(damaged, query), "wrong question accepted");
    damaged = reply;
    damaged[3] = 0x83;
    require(!answer(damaged, query), "NXDOMAIN accepted");
    damaged = reply;
    damaged[query.size()] = 0xff;
    damaged[query.size() + 1] = 0xff;
    require(!answer(damaged, query), "invalid compression pointer accepted");
    damaged = query;
    damaged[2] = 0x81;
    damaged[7] = 1;
    record(damaged, 1, 20, {198, 18, 0, 1});
    require(!answer(damaged, query), "fake public DNS result accepted");
    auto aaaa_query = question("example.test", 28, 42);
    auto aaaa_reply = aaaa_query;
    aaaa_reply[2] = 0x81;
    aaaa_reply[7] = 1;
    auto v6 = ip("2001:db8::7").to_v6().to_bytes();
    record(aaaa_reply, 28, 123, Bytes(v6.begin(), v6.end()));
    parsed = answer(aaaa_reply, aaaa_query);
    require(parsed && parsed->addresses == Addresses{ip("2001:db8::7")} && parsed->ttl == 123, "AAAA answer");
    auto cname = query;
    cname[2] = 0x81;
    cname[7] = 2;
    auto alias_offset = cname.size() + 12;
    record(cname, 5, 12, {3, 'c', 'd', 'n', 0xc0, 0x0c});
    put16(cname, 0xc000 | static_cast<unsigned>(alias_offset));
    put16(cname, 1);
    put16(cname, 1);
    put16(cname, 0);
    put16(cname, 600);
    put16(cname, 4);
    cname.insert(cname.end(), {203, 0, 113, 9});
    parsed = answer(cname, query);
    require(parsed && parsed->addresses == Addresses{ip("203.0.113.9")} && parsed->ttl == 12, "CNAME compression and TTL");
    auto unrelated = query;
    unrelated[2] = 0x81;
    unrelated[7] = 1;
    unrelated.insert(unrelated.end(), {3, 'c', 'd', 'n', 0xc0, 0x0c});
    auto tail = reply.begin() + query.size() + 2;
    unrelated.insert(unrelated.end(), tail, reply.end());
    parsed = answer(unrelated, query);
    require(parsed && parsed->addresses.empty(), "unrelated answer accepted");

    lt::io_context ios;
    int interfaces = 0;
    auto client = std::make_shared<Client>([&](auto&) {
        ++interfaces;
        return std::vector<Binding>{};
    });
    Addresses delivered;
    auto callback = [&](const auto& ec, const auto& addresses) {
        require(!ec, "fallback changed success status");
        delivered = addresses;
    };
    auto ordinary = Addresses{ip("192.0.2.1")};
    client->resolve(ios, "example.test", ordinary, callback);
    require(delivered == ordinary && interfaces == 0 && ios.poll() == 0, "normal DNS triggered network work");
    auto mixed = Addresses{ip("198.18.0.1"), ip("2001:db8::1")};
    client->resolve(ios, "example.test", mixed, callback);
    require(delivered == mixed && interfaces == 0, "mixed DNS triggered network work");
    auto original = Addresses{ip("198.18.0.1")};
    client->cache_["example.test"] = {ordinary, Clock::now() + std::chrono::seconds(30)};
    client->resolve(ios, "EXAMPLE.TEST.", original, callback);
    require(delivered == ordinary && interfaces == 0, "TTL cache missed");
    client->resolve(ios, "example.test", original, callback, true);
    require(delivered == ordinary && interfaces == 0, "shutdown replacement cache missed");
    client->cache_["example.test"].expires = Clock::now() - std::chrono::seconds(1);
    client->resolve(ios, "example.test", original, callback, true);
    require(delivered == original && interfaces == 0, "shutdown initiated network activity");
    client->resolve(ios, "example.test", original, callback);
    require(delivered == original && interfaces == 1, "expired cache or failure fallback");

    // Verify the patched resolver applies the hook to cached hostname results,
    // while raw IPs bypass it and shutdown requests carry the cache-only flag.
    lt::io_context resolver_loop;
    lt::aux::resolver resolver(resolver_loop);
    int filtered = 0;
    bool cache_only_seen = false;
    lt::aux::hostname_result_filter = [&](auto&, const auto&, bool cache_only, const auto& addresses, auto done) {
        ++filtered;
        cache_only_seen = cache_only_seen || cache_only;
        done({}, addresses);
    };
    bool resolved = false;
    auto resolved_callback = [&](const auto& ec, const auto& addresses) {
        resolved = !ec && !addresses.empty() && !needs_lookup(addresses);
    };
    resolver.async_resolve("localhost", {}, resolved_callback);
    resolver_loop.run();
    require(resolved && filtered == 1, "patched resolver hook not called");
    resolved = false;
    resolver_loop.restart();
    resolver.async_resolve("localhost", {}, resolved_callback);
    resolver_loop.run();
    require(resolved && filtered == 2, "system cache bypassed result hook");
    resolver_loop.restart();
    resolver.async_resolve("localhost", lt::aux::resolver_interface::cache_only, resolved_callback);
    resolver.async_resolve("192.0.2.1", {}, resolved_callback);
    resolver_loop.run();
    require(filtered == 3 && cache_only_seen, "cache-only flag or literal address handling");
    lt::aux::hostname_result_filter = {};

    // Exercise the actual UDP/TCP client with loopback servers, no public DNS.
    for (bool truncated : {false, true}) {
        lt::io_context loop;
        UDP::socket udp(loop, UDP::endpoint(ip("127.0.0.1"), 0));
        TCP::acceptor acceptor(loop, TCP::endpoint(ip("127.0.0.1"), udp.local_endpoint().port()));
        TCP::socket tcp(loop);
        std::array<std::uint8_t, 512> request{};
        UDP::endpoint sender;
        Bytes tcp_response;
        put16(tcp_response, static_cast<unsigned>(reply.size()));
        tcp_response.insert(tcp_response.end(), reply.begin(), reply.end());
        udp.async_receive_from(asio::buffer(request), sender, [&](const auto& ec, std::size_t) {
            require(!ec, "loopback UDP receive");
            auto invalid = reply;
            invalid[0] ^= 1;
            udp.send_to(asio::buffer(invalid), sender);
            auto response = truncated ? query : reply;
            if (truncated) response[2] = 0x83;
            udp.send_to(asio::buffer(response), sender);
        });
        if (truncated) {
            acceptor.async_accept(tcp, [&](const auto& ec) {
                require(!ec, "TCP accept");
                asio::async_read(tcp, asio::buffer(request.data(), query.size() + 2), [&](const auto& error, std::size_t) {
                    require(!error, "TCP request framing");
                    asio::async_write(tcp, asio::buffer(tcp_response), [](const auto& write_error, std::size_t) {
                        if (write_error) throw std::runtime_error("TCP test response");
                    });
                });
            });
        }
        bool completed = false;
        std::make_shared<Exchange>(loop, Binding{if_nametoindex("lo0"), ip("127.0.0.1")},
            udp.local_endpoint(), query, std::chrono::milliseconds(2000), [&](auto result) {
                require(result && result->addresses == Addresses{ip("192.0.2.7")}, "UDP/TCP exchange failed");
                completed = true;
            })->start();
        loop.run();
        require(completed, "exchange did not complete");
    }
    lt::io_context timeout_loop;
    UDP::socket silent(timeout_loop, UDP::endpoint(ip("127.0.0.1"), 0));
    bool timed_out = false;
    auto started = Clock::now();
    std::make_shared<Exchange>(timeout_loop, Binding{if_nametoindex("lo0"), ip("127.0.0.1")},
        silent.local_endpoint(), query, std::chrono::milliseconds(30), [&](auto result) {
            require(!result, "timeout returned an answer");
            timed_out = true;
        })->start();
    timeout_loop.run();
    require(timed_out && Clock::now() - started < std::chrono::seconds(1), "timeout was not bounded");
    std::cout << "PASS DNS encoding, A/AAAA, CNAME, malformed packets, fake detection, normal bypass, TTL, UDP/TCP and timeout\n";
    return 0;
}
}
