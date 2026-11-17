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

# ---- 从 config.sh 生成两份配置（官方 11-11 配方：P/D 分离）------------------
# mooncake.json   → Prefill rank：贡献池 DRAM（segment + 1GB 本地缓冲）
# mooncake_d.json → Decode rank：纯消费者（0/0）。
#   官方警告：D 侧预留池 DRAM 可能因 rtsHostRegister 内存不足失败，且挤占引擎主机内存
# SSD 卸载层本次重试先不开（最小化变量），如需开启：两侧 enable_ssd_offload 改 true
# 并按官方 5.4.2 补 MOONCAKE_OFFLOAD_* 环境变量
cat > "$DEPLOY_DIR/kv_pool/mooncake.json" <<EOF
{
    "metadata_server": "P2PHANDSHAKE",
    "protocol": "ascend",
    "device_name": "",
    "master_server_address": "${MOONCAKE_MASTER_IP}:${MOONCAKE_MASTER_PORT}",
    "global_segment_size": "${MOONCAKE_SEGMENT_SIZE}",
    "local_buffer_size": "1GB",
    "preferred_segment": false,
    "prefer_alloc_in_same_node": true,
    "enable_ssd_offload": false,
    "tenant_id": "${MOONCAKE_TENANT_ID}"
}
EOF
cat > "$DEPLOY_DIR/kv_pool/mooncake_d.json" <<EOF
{
    "metadata_server": "P2PHANDSHAKE",
    "protocol": "ascend",
    "device_name": "",
    "master_server_address": "${MOONCAKE_MASTER_IP}:${MOONCAKE_MASTER_PORT}",
    "global_segment_size": "0",
    "local_buffer_size": "0",
    "preferred_segment": false,
    "prefer_alloc_in_same_node": true,
    "enable_ssd_offload": false,
    "tenant_id": "${MOONCAKE_TENANT_ID}"
}
EOF
echo "[OK] 已生成 Prefill 配置 $DEPLOY_DIR/kv_pool/mooncake.json（贡献 ${MOONCAKE_SEGMENT_SIZE}/rank + buffer 1GB）"
echo "[OK] 已生成 Decode  配置 $DEPLOY_DIR/kv_pool/mooncake_d.json（纯消费者 0/0）"
echo "     master = ${MOONCAKE_MASTER_IP}:${MOONCAKE_MASTER_PORT}"

export PYTHONHASHSEED=0

if ! command -v mooncake_master >/dev/null 2>&1; then
    echo "[ERROR] 容器内无 mooncake_master 命令，请确认镜像版本" >&2
    exit 1
fi

# --client_ttl=120：防止编译慢的 worker 在启动期（图捕获十几分钟）被 master 踢出池
exec mooncake_master \
    --port "$MOONCAKE_MASTER_PORT" \
    --eviction_high_watermark_ratio 0.9 \
    --eviction_ratio 0.1 \
    --default_kv_lease_ttl 11000 \
    --client_ttl 120
