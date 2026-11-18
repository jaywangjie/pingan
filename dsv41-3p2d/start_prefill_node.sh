#!/usr/bin/env bash
# =============================================================================
# Prefill 节点启动入口（在 001/002/003 的容器内运行，自动识别本机与 rank 偏移）
# 本机启动 4 个 DP4/TP4 引擎（API 端口 8200-8203）
# 全局 DP12：001=rank0-3（组 master）、002=rank4-7、003=rank8-11
# 启动顺序：D 组（004→005）全部就绪后再启动本组；组内 master（001）先起
# =============================================================================
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DEPLOY_DIR/config.sh"

# ---- 识别本机是哪台 P（每台自成 DP 组，rank 都从 0 开始）--------------------
LOCAL_IPS="$({ hostname -I 2>/dev/null || true; { ip -4 addr 2>/dev/null | awk '/inet /{print $2}'; } || true; } | tr ' ' '\n' | cut -d/ -f1 | grep -v '^$' | sort -u || true)"
LOCAL_IP=""
for ip in "$P1_IP" "$P2_IP" "$P3_IP"; do
    echo "$LOCAL_IPS" | grep -qx "$ip" && LOCAL_IP="$ip" && break
done
if [ -z "$LOCAL_IP" ]; then
    echo "[ERROR] 本机不是本部署的 Prefill 节点（$P1_IP / $P2_IP / $P3_IP）。本机 IP：$(echo $LOCAL_IPS | tr '\n' ' ')" >&2
    echo "        Decode 节点请运行 start_decode_node.sh" >&2
    exit 1
fi
export LOCAL_IP

echo "=============================================="
echo " 3P2D  Prefill： $LOCAL_IP（独立 DP 组，rank 0-$((PREFILL_DP_SIZE - 1))）"
echo " 布局：        本机 DP${PREFILL_DP_SIZE} / TP${PREFILL_TP_SIZE}（EP16，与 4P1D 的 P 同构）"
echo " DP 组：       本机自组（$LOCAL_IP:$DP_RPC_PORT）"
echo " API 端口：    ${ENGINE_START_PORT}-$((ENGINE_START_PORT + PREFILL_DP_SIZE - 1))"
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
