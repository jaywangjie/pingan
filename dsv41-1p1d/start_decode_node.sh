#!/usr/bin/env bash
# =============================================================================
# Decode 节点启动入口（在 D 节点 005 的容器内运行）
# 启动本机 DP8/TP2 引擎（8 个 vllm serve，API 端口 8100-8107）
# 前提：Mooncake master 已启动（本包 master 默认就跑在 005 容器内）
# =============================================================================
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DEPLOY_DIR/config.sh"

LOCAL_IPS="$({ hostname -I 2>/dev/null || true; { ip -4 addr 2>/dev/null | awk '/inet /{print $2}'; } || true; } | tr ' ' '\n' | cut -d/ -f1 | grep -v '^$' | sort -u || true)"
LOCAL_IP=""
if echo "$LOCAL_IPS" | grep -qx "$D1_IP"; then
    LOCAL_IP="$D1_IP"
else
    echo "[ERROR] 本机 IP 不是本部署的 Decode 节点（$D1_IP）。本机 IP：$(echo $LOCAL_IPS | tr '\n' ' ')" >&2
    echo "        Prefill 节点请运行 start_prefill_node.sh" >&2
    exit 1
fi
export LOCAL_IP

if [ "${ENABLE_KV_POOL:-0}" = "1" ] && [ ! -f "$DEPLOY_DIR/kv_pool/mooncake_d.json" ]; then
    echo "[WARN] $DEPLOY_DIR/kv_pool/mooncake_d.json 不存在，请先运行 kv_pool/start_mooncake_master.sh 生成" >&2
fi

echo "=============================================="
echo " 1P1D+KVPool  Decode： $LOCAL_IP"
echo " 布局：        DP${DECODE_DP_SIZE} / TP${DECODE_TP_SIZE}（16 逻辑设备）"
echo " API 端口：    ${ENGINE_START_PORT}-$((ENGINE_START_PORT + DECODE_DP_SIZE - 1))"
echo " KV Pool：     ENABLE_KV_POOL=${ENABLE_KV_POOL:-0}（1=开，D 用 kv_pool/mooncake_d.json 纯消费者）"
echo " 模型：        $MODEL_PATH"
echo "=============================================="

cd "$DEPLOY_DIR/decode"
exec python3 launch_online_dp.py \
    --dp-size "$DECODE_DP_SIZE" \
    --tp-size "$DECODE_TP_SIZE" \
    --dp-size-local "$DECODE_DP_SIZE" \
    --dp-rank-start 0 \
    --dp-address "$LOCAL_IP" \
    --dp-rpc-port "$DP_RPC_PORT" \
    --vllm-start-port "$ENGINE_START_PORT"
