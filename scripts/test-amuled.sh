#!/bin/bash
# 离线 EC / 生命周期测试；先运行 scripts/build-amuled.sh --standalone。
set -euo pipefail
export LANG=en_US.UTF-8
export LC_ALL=en_US.UTF-8
exec python3 -I "$(dirname "$0")/test-amuled.py" "$@"
