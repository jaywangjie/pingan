#!/usr/bin/env bash
# =============================================================================
# Prefill 节点启动入口（在 4 台 P 节点的容器内运行）
# 启动本机 DP4/TP4 引擎（4 个 vllm serve，API 端口 7100-7103）
# 建议在 tmux 中运行，或 nohup bash start_prefill_node.sh > prefill.log 2>&1 &
# =============================================================================
set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$DEPLOY_DIR/config.sh"

# ---- 识别本机是否为 Prefill 节点 -------------------------------------------
# 容器内可能没有 ip 命令，hostname -I 兜底；所有分支 || true 兜底，
# 避免 pipefail 把"命令不存在"的 127 传给整条管道触发 set -e 静默退出
LOCAL_IPS="$({ hostname -I 2>/dev/null || true; { ip -4 addr 2>/dev/null | awk '/inet /{print $2}'; } || true; } | tr ' ' '\n' | cut -d/ -f1 | grep -v '^$' | sort -u || true)"
LOCAL_IP=""
ROLE=""
for entry in "P1:$P1_IP" "P2:$P2_IP" "P3:$P3_IP" "P4:$P4_IP" "D1:$D1_IP"; do
    ip="${entry#*:}"
    if echo "$LOCAL_IPS" | grep -qx "$ip"; then
        LOCAL_IP="$ip"
        ROLE="${entry%%:*}"
        break
    fi
done
if [ -z "$LOCAL_IP" ]; then
    echo "[ERROR] 本机 IP 不在 config.sh 的节点列表中，请检查网络或配置。" >&2
    echo "本机当前 IP 列表：$(echo $LOCAL_IPS | tr '\n' ' ')" >&2
    exit 1
fi
if [ "$ROLE" != "P1" ] && [ "$ROLE" != "P2" ] && [ "$ROLE" != "P3" ] && [ "$ROLE" != "P4" ]; then
    echo "[ERROR] 本机（$LOCAL_IP，$ROLE）不是 Prefill 节点。Decode 节点请运行 start_decode_node.sh" >&2
    exit 1
fi
export LOCAL_IP

echo "=============================================="
echo " Prefill 节点： $ROLE  $LOCAL_IP"
echo " 布局：        DP${PREFILL_DP_SIZE} / TP${PREFILL_TP_SIZE}（16 逻辑设备）"
echo " API 端口：    ${ENGINE_START_PORT}-$((ENGINE_START_PORT + PREFILL_DP_SIZE - 1))"
echo " 模型：        $MODEL_PATH"
echo " 网卡：        $NIC_NAME"
echo "=============================================="

# ---- 启动 4 个 DP rank（launcher 前台运行，保持终端打开）--------------------
cd "$DEPLOY_DIR/prefill"
exec python3 launch_online_dp.py \
    --dp-size "$PREFILL_DP_SIZE" \
    --tp-size "$PREFILL_TP_SIZE" \
    --dp-size-local "$PREFILL_DP_SIZE" \
    --dp-rank-start 0 \
    --dp-address "$LOCAL_IP" \
    --dp-rpc-port "$DP_RPC_PORT" \
    --vllm-start-port "$ENGINE_START_PORT"
