#!/usr/bin/env bash
# =============================================================================
# Decode 节点启动入口（在 004/005 的容器内运行，自动识别本机与 rank 偏移）
# 本机启动 8 个 DP8/TP2 引擎（API 端口 8200-8207）
# 全局 DP16：004=rank0-7（组 master）、005=rank8-15
# 启动顺序：D 组先于 P 组；组内 master（004）先起，005 随后
# =============================================================================
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DEPLOY_DIR/config.sh"

# ---- 识别本机是哪台 D，得出全局 rank 起始值 ---------------------------------
LOCAL_IPS="$({ hostname -I 2>/dev/null || true; { ip -4 addr 2>/dev/null | awk '/inet /{print $2}'; } || true; } | tr ' ' '\n' | cut -d/ -f1 | grep -v '^$' | sort -u || true)"
LOCAL_IP=""; RANK_START=""
if echo "$LOCAL_IPS" | grep -qx "$D1_IP"; then
    LOCAL_IP="$D1_IP"; RANK_START=0
elif echo "$LOCAL_IPS" | grep -qx "$D2_IP"; then
    LOCAL_IP="$D2_IP"; RANK_START="$DECODE_DP_SIZE_LOCAL"
else
    echo "[ERROR] 本机不是本部署的 Decode 节点（$D1_IP / $D2_IP）。本机 IP：$(echo $LOCAL_IPS | tr '\n' ' ')" >&2
    echo "        Prefill 节点请运行 start_prefill_node.sh" >&2
    exit 1
fi
export LOCAL_IP

echo "=============================================="
echo " 3P2D  Decode： $LOCAL_IP（全局 rank ${RANK_START}-$((RANK_START + DECODE_DP_SIZE_LOCAL - 1))）"
echo " 布局：        本机 DP${DECODE_DP_SIZE_LOCAL} / TP${DECODE_TP_SIZE}，全局 DP${DECODE_DP_SIZE} / TP${DECODE_TP_SIZE}"
echo " DP 组 master： $D1_IP:$DP_RPC_PORT"
echo " API 端口：    ${ENGINE_START_PORT}-$((ENGINE_START_PORT + DECODE_DP_SIZE_LOCAL - 1))"
echo " 模型：        $MODEL_PATH"
echo "=============================================="

cd "$DEPLOY_DIR/decode"
exec python3 launch_online_dp.py \
    --dp-size "$DECODE_DP_SIZE" \
    --tp-size "$DECODE_TP_SIZE" \
    --dp-size-local "$DECODE_DP_SIZE_LOCAL" \
    --dp-rank-start "$RANK_START" \
    --dp-address "$D1_IP" \
    --dp-rpc-port "$DP_RPC_PORT" \
    --vllm-start-port "$ENGINE_START_PORT"
