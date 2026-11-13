#!/usr/bin/env bash
# =============================================================================
# 服务验证（任意能访问 5 台节点的机器上运行）
# 用法：
#   bash verify_service.sh wait    # 轮询等待全部引擎就绪（部署后先跑这个）
#   bash verify_service.sh engines # 检查全部引擎 /health
#   bash verify_service.sh proxy   # 检查 PD 代理 /healthcheck 与模型列表
#   bash verify_service.sh smoke   # 冒烟请求（文本）
#   bash verify_service.sh image   # 冒烟请求（多模态，需可访问外网图片）
#   bash verify_service.sh         # 默认 = engines + proxy
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/config.sh"

MODE="${1:-all}"
PROXY_IP="${PROXY_IP:-$P1_IP}"          # 代理所在机器 IP，按实际修改
SERVICE_URL="http://$PROXY_IP:$PROXY_PORT"

# 用函数而非变量存 curl 命令：变量展开会让 --noproxy * 被 glob 成文件名
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
    echo "==== Prefill 引擎（4 台 × 7100-7103）===="
    local rc=0
    for ip in "$P1_IP" "$P2_IP" "$P3_IP" "$P4_IP"; do
        for port in 7100 7101 7102 7103; do check_engine "$ip" "$port" || rc=1; done
    done
    echo "==== Decode 引擎（$D1_IP × 7100-7107）===="
    for port in 7100 7101 7102 7103 7104 7105 7106 7107; do check_engine "$D1_IP" "$port" || rc=1; done
    return $rc
}

wait_ready() {
    local timeout=${1:-14400}   # 默认等 4 小时（权重从 SFS 加载较慢）
    local start=$SECONDS
    while :; do
        if all_engines >/tmp/vs_out 2>&1; then
            echo "[READY] 全部 24 个引擎就绪（P 16 + D 8），耗时 $((SECONDS - start))s"
            cat /tmp/vs_out
            return 0
        fi
        if [ $((SECONDS - start)) -ge "$timeout" ]; then
            echo "[TIMEOUT] ${timeout}s 内未全部就绪，当前状态："
            cat /tmp/vs_out
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
        "chat_template_kwargs": {"reasoning_effort": 50},
        "temperature": 0,
        "max_completion_tokens": 1024
      }'
}

smoke_image() {
    echo "==== 多模态冒烟请求（$SERVICE_URL）===="
    local image_url="${IMAGE_URL:-https://upload.wikimedia.org/wikipedia/commons/thumb/d/dd/Gfp-wisconsin-madison-the-nature-boardwalk.jpg/2560px-Gfp-wisconsin-madison-the-nature-boardwalk.jpg}"
    curlx -w '\nHTTP %{http_code}\n' "$SERVICE_URL/v1/chat/completions" \
      -H 'Content-Type: application/json' \
      -d '{
        "model": "'"$SERVED_MODEL_NAME"'",
        "messages": [{
          "role": "user",
          "content": [
            {"type": "image_url", "image_url": {"url": "'"$image_url"'"}},
            {"type": "text", "text": "描述这张图片。"}
          ]
        }],
        "temperature": 0,
        "max_completion_tokens": 1024
      }'
}

case "$MODE" in
    wait)    wait_ready "${2:-14400}" ;;
    engines) all_engines ;;
    proxy)   check_proxy ;;
    smoke)   smoke_text ;;
    image)   smoke_image ;;
    all|*)   all_engines; check_proxy ;;
esac
