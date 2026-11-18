#!/usr/bin/env bash
# =============================================================================
# PD 代理启动（在 P1 节点 001 容器内运行）
# 注册 3 台 P × 4 端口（8200-8203）+ 2 台 D × 8 端口（8200-8207），监听 9200
# 前提：28 个引擎全部 ready（本包纯 PD，无 mooncake master 依赖）
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

# ---- 校验 28 个后端引擎 -------------------------------------------------------
echo "[INFO] 检查后端引擎 /health ..."
ALL_OK=1
for ip in "$P1_IP" "$P2_IP" "$P3_IP"; do
    for port in 8200 8201 8202 8203; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' "http://$ip:$port/health" 2>/dev/null || echo 000)
        [ "$code" = "200" ] || { echo "  [WAIT] $ip:$port -> HTTP $code"; ALL_OK=0; }
    done
done
for ip in "$D1_IP" "$D2_IP"; do
    for port in 8200 8201 8202 8203 8204 8205 8206 8207; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' "http://$ip:$port/health" 2>/dev/null || echo 000)
        [ "$code" = "200" ] || { echo "  [WAIT] $ip:$port -> HTTP $code"; ALL_OK=0; }
    done
done
if [ "$ALL_OK" -ne 1 ]; then
    echo "[ERROR] 存在未就绪的后端引擎。强制启动：FORCE=1 bash $0" >&2
    [ "${FORCE:-0}" = "1" ] || exit 1
fi

exec python3 "$PROXY" \
    --host 0.0.0.0 \
    --port "$PROXY_PORT" \
    --prefiller-hosts "$P1_IP" "$P1_IP" "$P1_IP" "$P1_IP" \
                      "$P2_IP" "$P2_IP" "$P2_IP" "$P2_IP" \
                      "$P3_IP" "$P3_IP" "$P3_IP" "$P3_IP" \
    --prefiller-ports 8200 8201 8202 8203 8200 8201 8202 8203 8200 8201 8202 8203 \
    --decoder-hosts  "$D1_IP" "$D1_IP" "$D1_IP" "$D1_IP" "$D1_IP" "$D1_IP" "$D1_IP" "$D1_IP" \
                     "$D2_IP" "$D2_IP" "$D2_IP" "$D2_IP" "$D2_IP" "$D2_IP" "$D2_IP" "$D2_IP" \
    --decoder-ports  8200 8201 8202 8203 8204 8205 8206 8207 8200 8201 8202 8203 8204 8205 8206 8207
