#!/usr/bin/env bash
# =============================================================================
# Mooncake Master 启动（KV Cache Pool 第二阶段，可选）
# 在一台所有节点都能访问的机器上运行（默认建议 D 节点或辅助节点，
# 与 mooncake.json 的 master_server_address 保持一致）
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/../config.sh"

export PYTHONHASHSEED=0

exec mooncake_master \
    --port 50088 \
    --eviction_high_watermark_ratio 0.9 \
    --eviction_ratio 0.1 \
    --default_kv_lease_ttl 11000
