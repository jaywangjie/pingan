#!/usr/bin/env bash
# =============================================================================
# Decode 节点启动入口（在 D 节点 005 的容器内运行）
# 启动本机 DP8/TP2 引擎（8 个 vllm serve，API 端口 7100-7107）
# 建议在 tmux 中运行，或 nohup bash start_decode_node.sh > decode.log 2>&1 &
# 启动顺序：先 Decode 后 Prefill（对齐官方 PD 教程）
# =============================================================================
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DEPLOY_DIR/config.sh"

# ---- 识别本机是否为 Decode 节点 ---------------------------------------------
# 容器内可能没有 ip 命令，hostname -I 兜底；所有分支 || true 兜底，
# 避免 pipefail 把"命令不存在"的 127 传给整条管道触发 set -e 静默退出
LOCAL_IPS="$({ hostname -I 2>/dev/null || true; { ip -4 addr 2>/dev/null | awk '/inet /{print $2}'; } || true; } | tr ' ' '\n' | cut -d/ -f1 | grep -v '^$' | sort -u || true)"
LOCAL_IP=""
for ip in "$D1_IP"; do
    if echo "$LOCAL_IPS" | grep -qx "$ip"; then LOCAL_IP="$ip"; break; fi
done
if [ -z "$LOCAL_IP" ]; then
    echo "[ERROR] 本机 IP 不是 Decode 节点（$D1_IP）。Prefill 节点请运行 start_prefill_node.sh" >&2
    echo "本机当前 IP 列表：$(echo $LOCAL_IPS | tr '\n' ' ')" >&2
    exit 1
fi
export LOCAL_IP

echo "=============================================="
echo " Decode 节点： D0  $LOCAL_IP"
echo " 布局：        DP${DECODE_DP_SIZE} / TP${DECODE_TP_SIZE}（16 逻辑设备）"
echo " API 端口：    ${ENGINE_START_PORT}-$((ENGINE_START_PORT + DECODE_DP_SIZE - 1))"
echo " 模型：        $MODEL_PATH"
echo " 网卡：        $NIC_NAME"
echo "=============================================="

# ---- 启动 8 个 DP rank（launcher 前台运行，保持终端打开）--------------------
cd "$DEPLOY_DIR/decode"
exec python3 launch_online_dp.py \
    --dp-size "$DECODE_DP_SIZE" \
    --tp-size "$DECODE_TP_SIZE" \
    --dp-size-local "$DECODE_DP_SIZE" \
    --dp-rank-start 0 \
    --dp-address "$LOCAL_IP" \
    --dp-rpc-port "$DP_RPC_PORT" \
    --vllm-start-port "$ENGINE_START_PORT"
