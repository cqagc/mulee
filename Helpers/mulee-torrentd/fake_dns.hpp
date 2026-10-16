#pragma once

#include <string>
#include <vector>

namespace mulee {
void install_fake_ip_resolver();
std::vector<std::string> take_dns_logs();
int test_fake_dns();
}
