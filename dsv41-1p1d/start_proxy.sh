#!/usr/bin/env bash
# =============================================================================
# PD 代理启动（在 P 节点 001 容器内运行）
# 注册 1 台 P × 4 端口（8100-8103）+ 1 台 D × 8 端口（8100-8107），监听 9100
# 前提：12 个引擎全部 ready + mooncake master 运行中
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/config.sh"

PROXY=""
if [ -f "$PROXY_SCRIPT" ]; then
    PROXY="$PROXY_SCRIPT"
else
    PROXY=$(find /vllm-workspace "$SCRIPT_DIR" -name load_balance_proxy_server_example.py 2>/dev/null | head -1 || true)
fi
if [ -z "$PROXY" ]; then
    echo "[ERROR] 未找到 load_balance_proxy_server_example.py" >&2
    exit 1
fi
echo "[INFO] 代理脚本：$PROXY"

# ---- 确认 mooncake master 存活（仅 KV Pool 模式需要；纯 PD 无池不依赖 master）----
if [ "${ENABLE_KV_POOL:-0}" = "1" ]; then
    if timeout 2 bash -c "exec 3<>/dev/tcp/$MOONCAKE_MASTER_IP/$MOONCAKE_MASTER_PORT" 2>/dev/null; then
        echo "[OK] Mooncake master 可达（$MOONCAKE_MASTER_IP:$MOONCAKE_MASTER_PORT）"
    else
        echo "[ERROR] Mooncake master 不可达，请先在 ${MOONCAKE_MASTER_IP} 容器内运行 kv_pool/start_mooncake_master.sh" >&2
        exit 1
    fi
else
    echo "[INFO] ENABLE_KV_POOL=0（纯 PD），跳过 mooncake master 检查"
fi

# ---- 校验 12 个后端引擎 ------------------------------------------------------
echo "[INFO] 检查后端引擎 /health ..."
ALL_OK=1
for port in 8100 8101 8102 8103; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' "http://$P1_IP:$port/health" 2>/dev/null || echo 000)
    [ "$code" = "200" ] || { echo "  [WAIT] $P1_IP:$port -> HTTP $code"; ALL_OK=0; }
done
for port in 8100 8101 8102 8103 8104 8105 8106 8107; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' "http://$D1_IP:$port/health" 2>/dev/null || echo 000)
    [ "$code" = "200" ] || { echo "  [WAIT] $D1_IP:$port -> HTTP $code"; ALL_OK=0; }
done
if [ "$ALL_OK" -ne 1 ]; then
    echo "[ERROR] 存在未就绪的后端引擎。强制启动：FORCE=1 bash $0" >&2
    [ "${FORCE:-0}" = "1" ] || exit 1
fi

exec python3 "$PROXY" \
    --host 0.0.0.0 \
    --port "$PROXY_PORT" \
    --prefiller-hosts "$P1_IP" "$P1_IP" "$P1_IP" "$P1_IP" \
    --prefiller-ports 8100 8101 8102 8103 \
    --decoder-hosts "$D1_IP" "$D1_IP" "$D1_IP" "$D1_IP" "$D1_IP" "$D1_IP" "$D1_IP" "$D1_IP" \
    --decoder-ports 8100 8101 8102 8103 8104 8105 8106 8107
