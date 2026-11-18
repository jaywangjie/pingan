#!/usr/bin/env bash
# =============================================================================
# 部署前预检（在 5 台 A3 宿主机各运行一次）
# 重点：本包端口（8200段/14321/34000/34100/9200）与 NPU 是否空闲
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/config.sh"

PASS=0; WARN=0; FAIL=0
ok()   { echo "  [PASS] $*"; PASS=$((PASS+1)); }
warn() { echo "  [WARN] $*"; WARN=$((WARN+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
section() { echo; echo "==== $* ===="; }

LOCAL_IP=""
for ip in "$P1_IP" "$P2_IP" "$P3_IP" "$D1_IP" "$D2_IP"; do
    ip -4 addr | grep -qw "$ip" && LOCAL_IP="$ip" && break
done

section "1. 本机识别"
[ -n "$LOCAL_IP" ] && ok "本机 IP：$LOCAL_IP（P=$P1_IP/$P2_IP/$P3_IP，D=$D1_IP/$D2_IP）" \
    || bad "本机不是本部署的 5 个节点之一"

section "2. 本包端口占用（应全部空闲）"
BUSY=0
for port in "$DP_RPC_PORT" "$PROXY_PORT" 8200 8201 8202 8203 8204 8205 8206 8207; do
    ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":$port$" && { bad "端口 $port 已被占用"; BUSY=1; }
done
[ "$BUSY" -eq 0 ] && ok "14321/8200-8207/9200 均空闲"

section "3. NPU 资源是否被其他包占用"
VLLM_CNT=$(pgrep -fc "vllm serve" 2>/dev/null || echo 0)
if [ "$VLLM_CNT" -gt 0 ]; then
    bad "本机有 $VLLM_CNT 个 vllm 进程在跑（可能是 4P1D 或 1P1D 引擎）。"
    echo "        NPU 互斥：本包占用全部 5 台，启动前需停掉所有机器上的其他引擎（不删文件）："
    echo "          docker exec -it deepseek-v41-4p1d bash -c 'pkill -f \"vllm serve\"'"
    echo "          docker exec -it deepseek-v41-1p1d bash -c 'pkill -f \"vllm serve\"'"
    echo "        等 HBM 回落后再启动本包"
else
    ok "本机无 vllm 进程，NPU 空闲"
fi

section "4. 权重与共享存储"
[ -f "$MODEL_PATH/config.json" ] && ok "权重：$MODEL_PATH" || bad "权重不可访问：$MODEL_PATH"
df -h /mnt/sfs_turbo | tail -1

section "5. 其余 4 台节点连通"
for ip in "$P1_IP" "$P2_IP" "$P3_IP" "$D1_IP" "$D2_IP"; do
    [ "$ip" = "$LOCAL_IP" ] && continue
    ping -c 1 -W 2 "$ip" >/dev/null 2>&1 && ok "ping $ip" || bad "ping $ip 不通"
done

section "6. 防火墙提醒"
echo "  需放行：8200-8207、14321、34000-34099、34100-34199、9200（5 台都要）"
systemctl is-active firewalld >/dev/null 2>&1 && warn "firewalld 运行中，确认放行" || ok "未检测到 firewalld"

echo
echo "=============================================="
echo " 预检结果： PASS=$PASS  WARN=$WARN  FAIL=$FAIL"
echo "=============================================="
[ "$FAIL" -eq 0 ] || { echo "存在 FAIL 项（第 3 项的 NPU 占用属预期，停其他引擎后重跑即可转 PASS）。"; exit 1; }
exit 0
