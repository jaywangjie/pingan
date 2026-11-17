#!/usr/bin/env bash
# =============================================================================
# 服务验证（任意能访问 P/D 两台节点的机器上运行）
# 用法：
#   bash verify_service.sh wait     # 轮询等待 12 个引擎就绪
#   bash verify_service.sh engines  # 检查全部引擎 /health
#   bash verify_service.sh proxy    # 检查代理 /healthcheck 与模型列表
#   bash verify_service.sh smoke    # 冒烟请求
#   bash verify_service.sh pooltest # KV 池化缓存命中测试（同前缀发两次）
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
    echo "==== Prefill 引擎（$P1_IP × 8100-8103）===="
    local rc=0
    for port in 8100 8101 8102 8103; do check_engine "$P1_IP" "$port" || rc=1; done
    echo "==== Decode 引擎（$D1_IP × 8100-8107）===="
    for port in 8100 8101 8102 8103 8104 8105 8106 8107; do check_engine "$D1_IP" "$port" || rc=1; done
    return $rc
}

wait_ready() {
    local timeout=${1:-14400}
    local start=$SECONDS
    while :; do
        if all_engines >/tmp/vs1p1d_out 2>&1; then
            echo "[READY] 全部 12 个引擎就绪（P 4 + D 8），耗时 $((SECONDS - start))s"
            cat /tmp/vs1p1d_out
            return 0
        fi
        if [ $((SECONDS - start)) -ge "$timeout" ]; then
            echo "[TIMEOUT] ${timeout}s 内未全部就绪，当前状态："
            cat /tmp/vs1p1d_out
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

# ---- KV 池化命中测试：同一前缀发送两次，第二次应命中池 ----------------------
# 固定一段长前缀（约 1500 token），确保值得缓存；两次请求内容完全相同
POOL_PREFIX="在分布式推理系统的设计中，预填充与解码分离是一种重要的架构模式。预填充阶段负责处理输入序列的全部前向计算，生成键值缓存；解码阶段则在已有键值缓存的基础上逐个生成输出词元。两个阶段的计算特征截然不同：预填充是计算密集型任务，可以充分利用硬件的并行计算能力；解码是访存密集型任务，每一步都需要读取全部模型权重。将两个阶段部署在不同的硬件上，可以让各自选择最适合的并行策略与配置参数，同时避免相互干扰。键值缓存在两个阶段之间的传输通过高速网络完成，传输开销通常可以被计算时间掩盖。此外，前缀缓存技术可以显著降低多轮对话场景下的首词元延迟，因为相同前缀的键值缓存可以被重复利用，无需重新计算。缓存命中率的提升依赖于会话亲和性调度或者分布式缓存池的部署，后者允许任意引擎命中任意节点缓存的前缀，从而在轮询负载均衡下依然保持高命中率。"
pooltest() {
    echo "==== KV 池化命中测试：同前缀发送两次（$SERVICE_URL）===="
    REQ='{"model":"'"$SERVED_MODEL_NAME"'","messages":[{"role":"user","content":"'"$POOL_PREFIX"'\n\n请用一句话概括上文。"}],"temperature":0,"max_tokens":64}'
    for i in 1 2; do
        echo "-- 第 $i 次请求:"
        curlx -s -o /tmp/pooltest_$i.json -w 'HTTP %{http_code}  耗时 %{time_total}s\n' \
          "$SERVICE_URL/v1/chat/completions" -H 'Content-Type: application/json' -d "$REQ"
        sleep 3
    done
    echo
    echo "-- P 引擎缓存指标（关注 hits/queries 或 prefix_cache 相关计数是否增长）:"
    for port in 8100 8101 8102 8103; do
        echo "[$P1_IP:$port]"
        curlx -s "http://$P1_IP:$port/metrics" | grep -iE "prefix.*(hit|quer)|external_prefix" | head -4
    done
    echo
    echo "判读：第 2 次请求耗时应明显低于第 1 次；上方指标 hits 在两次请求间应增长。"
    echo "如需进一步确认，看 P 引擎日志中的 mooncake lookup/get/put 记录："
    echo "  PID=\$(pgrep -f 'vllm serve' | head -1); grep -iE 'mooncake|lookup|put|get' /proc/\$PID/fd/1 | tail -20"
}

case "$MODE" in
    wait)     wait_ready "${2:-14400}" ;;
    engines)  all_engines ;;
    proxy)    check_proxy ;;
    smoke)    smoke_text ;;
    pooltest) pooltest ;;
    all|*)    all_engines; check_proxy ;;
esac
