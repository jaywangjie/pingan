#!/usr/bin/env bash
# =============================================================================
# Mooncake Master 启动（KV Cache Pool 的元数据/调度中枢）
# 在 MOONCAKE_MASTER_IP 对应节点的容器内运行（本包默认 005/D 节点）
# 作用：1) 从 config.sh 生成 mooncake.json  2) 启动 mooncake_master
# 必须最先启动（顺序：master → Decode 引擎 → Prefill 引擎 → 代理）
# =============================================================================
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$DEPLOY_DIR/config.sh"

# ---- 从 config.sh 生成 mooncake.json（无需手工编辑）------------------------
cat > "$DEPLOY_DIR/kv_pool/mooncake.json" <<EOF
{
    "metadata_server": "P2PHANDSHAKE",
    "protocol": "ascend",
    "device_name": "",
    "master_server_address": "${MOONCAKE_MASTER_IP}:${MOONCAKE_MASTER_PORT}",
    "global_segment_size": "${MOONCAKE_SEGMENT_SIZE}",
    "preferred_segment": false,
    "prefer_alloc_in_same_node": true
}
EOF
echo "[OK] 已生成 $DEPLOY_DIR/kv_pool/mooncake.json"
echo "     master = ${MOONCAKE_MASTER_IP}:${MOONCAKE_MASTER_PORT}，每节点池容量 = ${MOONCAKE_SEGMENT_SIZE}"

export PYTHONHASHSEED=0

if ! command -v mooncake_master >/dev/null 2>&1; then
    echo "[ERROR] 容器内无 mooncake_master 命令，请确认镜像版本" >&2
    exit 1
fi

exec mooncake_master \
    --port "$MOONCAKE_MASTER_PORT" \
    --eviction_high_watermark_ratio 0.9 \
    --eviction_ratio 0.1 \
    --default_kv_lease_ttl 11000
