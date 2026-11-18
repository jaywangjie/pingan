#!/usr/bin/env bash
# =============================================================================
# 服务验证（任意能访问 5 台节点的机器上运行）
# 用法：
#   bash verify_service.sh wait     # 轮询等待 28 个引擎就绪（P 12 + D 16）
#   bash verify_service.sh engines  # 检查全部引擎 /health
#   bash verify_service.sh proxy    # 检查代理 /healthcheck 与模型列表
#   bash verify_service.sh smoke    # 冒烟请求
#   bash verify_service.sh          # 默认 = engines + proxy
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/config.sh"

MODE="${1:-all}"
PROXY_IP="${PROXY_IP:-$P1_IP}"
SERVICE_URL="http://$PROXY_IP:$PROXY_PORT"

# 函数封装 curl（避免 --noproxy * 被 glob 展开）
curlx() { curl -sS --noproxy '*' "$@"; }

check_engine() {
    local ip=$1 port=$2
    local code
    code=$(curlx -s -o /dev/null -w '%{http_code}' "http://$ip:$port/health" 2>/dev/null || echo 000)
    if [ "$code" = "200" ]; then
        echo "  [ OK ] $ip:$port"
        return 0
    else
        echo "  [DOWN] $ip:$port (HTTP $code)"
        return 1
    fi
}

all_engines() {
    echo "==== Prefill 引擎（$P1_IP / $P2_IP / $P3_IP × 8200-8203）===="
    local rc=0
    for ip in "$P1_IP" "$P2_IP" "$P3_IP"; do
        for port in 8200 8201 8202 8203; do check_engine "$ip" "$port" || rc=1; done
    done
    echo "==== Decode 引擎（$D1_IP / $D2_IP × 8200-8207）===="
    for ip in "$D1_IP" "$D2_IP"; do
        for port in 8200 8201 8202 8203 8204 8205 8206 8207; do check_engine "$ip" "$port" || rc=1; done
    done
    return $rc
}

wait_ready() {
    local timeout=${1:-14400}
    local start=$SECONDS
    while :; do
        if all_engines >/tmp/vs3p2d_out 2>&1; then
            echo "[READY] 全部 28 个引擎就绪（P 12 + D 16），耗时 $((SECONDS - start))s"
            cat /tmp/vs3p2d_out
            return 0
        fi
        if [ $((SECONDS - start)) -ge "$timeout" ]; then
            echo "[TIMEOUT] ${timeout}s 内未全部就绪，当前状态："
            cat /tmp/vs3p2d_out
            return 1
        fi
        sleep 30
    done
}

check_proxy() {
    echo "==== PD 代理 $SERVICE_URL ===="
    echo "-- /healthcheck:"
    curlx -w '\nHTTP %{http_code}\n' "$SERVICE_URL/healthcheck"
    echo "-- /v1/models:"
    curlx "$SERVICE_URL/v1/models"
    echo
}

smoke_text() {
    echo "==== 文本冒烟请求（$SERVICE_URL）===="
    curlx -w '\nHTTP %{http_code}\n' "$SERVICE_URL/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d '{
        "model": "'"$SERVED_MODEL_NAME"'",
        "messages": [{"role": "user", "content": "1 加 1 等于几？请简短回答。"}],
        "temperature": 0,
        "max_completion_tokens": 1024
      }'
}

case "$MODE" in
    wait)     wait_ready "${2:-14400}" ;;
    engines)  all_engines ;;
    proxy)    check_proxy ;;
    smoke)    smoke_text ;;
    all|*)    all_engines; check_proxy ;;
esac
