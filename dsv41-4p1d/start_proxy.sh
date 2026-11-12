#!/usr/bin/env bash
# =============================================================================
# PD 代理启动（在能访问全部 5 台节点的机器上运行：优先辅助/管理节点，
# 条件有限时可在任一节点容器内运行）
# 注册 4 台 P × 4 端口 = 16 个 prefill 端点 + 1 台 D × 8 端口 = 8 个 decode 端点
# 前提：全部引擎（P 16 个 + D 8 个）均已 Application startup complete
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/config.sh"

# ---- 定位代理脚本 -----------------------------------------------------------
PROXY=""
if [ -f "$PROXY_SCRIPT" ]; then
    PROXY="$PROXY_SCRIPT"
else
    PROXY=$(find /vllm-workspace "$SCRIPT_DIR" -name load_balance_proxy_server_example.py 2>/dev/null | head -1 || true)
fi
if [ -z "$PROXY" ]; then
    echo "[ERROR] 未找到 load_balance_proxy_server_example.py，请在 config.sh 的 PROXY_SCRIPT 指定正确路径" >&2
    exit 1
fi
echo "[INFO] 代理脚本：$PROXY"

# ---- 校验后端可用性（代理 /healthcheck 只报告配置数，不代表后端就绪）--------
echo "[INFO] 检查后端引擎 /health ..."
ALL_OK=1
for ip in "$P1_IP" "$P2_IP" "$P3_IP" "$P4_IP"; do
    for port in 7100 7101 7102 7103; do
        code=$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' "http://$ip:$port/health" 2>/dev/null || echo 000)
        [ "$code" = "200" ] || { echo "  [WAIT] $ip:$port -> HTTP $code"; ALL_OK=0; }
    done
done
for port in 7100 7101 7102 7103 7104 7105 7106 7107; do
    code=$(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' "http://$D1_IP:$port/health" 2>/dev/null || echo 000)
    [ "$code" = "200" ] || { echo "  [WAIT] $D1_IP:$port -> HTTP $code"; ALL_OK=0; }
done
if [ "$ALL_OK" -ne 1 ]; then
    echo "[ERROR] 存在未就绪的后端引擎，请等全部引擎 ready 后再启动代理（或忽略此检查直接运行）" >&2
    echo "        跳过检查强制启动：FORCE=1 bash $0" >&2
    [ "${FORCE:-0}" = "1" ] || exit 1
fi

# ---- 启动代理 ---------------------------------------------------------------
# 端点注册顺序：P1×4、P2×4、P3×4、P4×4（7100-7103）；D×8（7100-7107）
exec python3 "$PROXY" \
    --host 0.0.0.0 \
    --port "$PROXY_PORT" \
    --prefiller-hosts \
        "$P1_IP" "$P1_IP" "$P1_IP" "$P1_IP" \
        "$P2_IP" "$P2_IP" "$P2_IP" "$P2_IP" \
        "$P3_IP" "$P3_IP" "$P3_IP" "$P3_IP" \
        "$P4_IP" "$P4_IP" "$P4_IP" "$P4_IP" \
    --prefiller-ports 7100 7101 7102 7103 7100 7101 7102 7103 7100 7101 7102 7103 7100 7101 7102 7103 \
    --decoder-hosts \
        "$D1_IP" "$D1_IP" "$D1_IP" "$D1_IP" "$D1_IP" "$D1_IP" "$D1_IP" "$D1_IP" \
    --decoder-ports 7100 7101 7102 7103 7104 7105 7106 7107
