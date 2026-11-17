#!/usr/bin/env bash
# =============================================================================
# Prefill 节点启动入口（在 P 节点 001 的容器内运行）
# 启动本机 DP4/TP4 引擎（4 个 vllm serve，API 端口 8100-8103）
# 前提：Mooncake master 已启动（见 kv_pool/start_mooncake_master.sh）
# =============================================================================
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DEPLOY_DIR/config.sh"

# ---- 识别本机是否为 Prefill 节点（hostname -I 兜底，分支全部 || true）------
LOCAL_IPS="$({ hostname -I 2>/dev/null || true; { ip -4 addr 2>/dev/null | awk '/inet /{print $2}'; } || true; } | tr ' ' '\n' | cut -d/ -f1 | grep -v '^$' | sort -u || true)"
LOCAL_IP=""
if echo "$LOCAL_IPS" | grep -qx "$P1_IP"; then
    LOCAL_IP="$P1_IP"
else
    echo "[ERROR] 本机 IP 不是本部署的 Prefill 节点（$P1_IP）。本机 IP：$(echo $LOCAL_IPS | tr '\n' ' ')" >&2
    echo "        Decode 节点请运行 start_decode_node.sh" >&2
    exit 1
fi
export LOCAL_IP

if [ ! -f "$DEPLOY_DIR/kv_pool/mooncake.json" ]; then
    echo "[WARN] $DEPLOY_DIR/kv_pool/mooncake.json 不存在，请先在 master 节点运行 kv_pool/start_mooncake_master.sh 生成" >&2
fi

echo "=============================================="
echo " 1P1D+KVPool  Prefill： $LOCAL_IP"
echo " 布局：        DP${PREFILL_DP_SIZE} / TP${PREFILL_TP_SIZE}（16 逻辑设备）"
echo " API 端口：    ${ENGINE_START_PORT}-$((ENGINE_START_PORT + PREFILL_DP_SIZE - 1))"
echo " KV Pool：     ${MOONCAKE_CONFIG_PATH:-$DEPLOY_DIR/kv_pool/mooncake.json}"
echo " 模型：        $MODEL_PATH"
echo "=============================================="

cd "$DEPLOY_DIR/prefill"
exec python3 launch_online_dp.py \
    --dp-size "$PREFILL_DP_SIZE" \
    --tp-size "$PREFILL_TP_SIZE" \
    --dp-size-local "$PREFILL_DP_SIZE" \
    --dp-rank-start 0 \
    --dp-address "$LOCAL_IP" \
    --dp-rpc-port "$DP_RPC_PORT" \
    --vllm-start-port "$ENGINE_START_PORT"
