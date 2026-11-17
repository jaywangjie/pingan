#!/usr/bin/env bash
# =============================================================================
# 部署前预检（在 P/D 两台 A3 宿主机各运行一次）
# 重点：本包端口（8100段/13321/32000/32100/9100/50088）与 NPU 是否空闲
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
for ip in "$P1_IP" "$D1_IP"; do
    ip -4 addr | grep -qw "$ip" && LOCAL_IP="$ip" && break
done

section "1. 本机识别"
[ -n "$LOCAL_IP" ] && ok "本机 IP：$LOCAL_IP（P=$P1_IP / D=$D1_IP）" \
    || bad "本机不是本部署的 P/D 节点"

section "2. 本包端口占用（应全部空闲）"
BUSY=0
for port in "$DP_RPC_PORT" "$PROXY_PORT" "$MOONCAKE_MASTER_PORT" 8100 8101 8102 8103 8104 8105 8106 8107; do
    ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":$port$" && { bad "端口 $port 已被占用"; BUSY=1; }
done
[ "$BUSY" -eq 0 ] && ok "13321/8100-8107/9100/50088 均空闲"

section "3. NPU 资源是否被 4P1D 占用"
VLLM_CNT=$(pgrep -fc "vllm serve" 2>/dev/null || echo 0)
if [ "$VLLM_CNT" -gt 0 ]; then
    bad "本机有 $VLLM_CNT 个 vllm 进程在跑（大概率是 4P1D 引擎）。"
    echo "        NPU 互斥：启动 1P1D 前需先停 4P1D 本机引擎（不删除任何文件）："
    echo "          docker exec -it deepseek-v41-4p1d bash -c 'pkill -f \"vllm serve\"'"
    echo "        等 HBM 回落后再启动本包（恢复 4P1D：按其 DEPLOY_GUIDE 重新拉起即可）"
else
    ok "本机无 vllm 进程，NPU 空闲"
fi

section "4. 权重与共享存储"
[ -f "$MODEL_PATH/config.json" ] && ok "权重：$MODEL_PATH" || bad "权重不可访问：$MODEL_PATH"
df -h /mnt/sfs_turbo | tail -1

section "5. 对端节点连通"
PEER="$D1_IP"; [ "$LOCAL_IP" = "$D1_IP" ] && PEER="$P1_IP"
ping -c 1 -W 2 "$PEER" >/dev/null 2>&1 && ok "ping $PEER" || bad "ping $PEER 不通"

section "6. 防火墙提醒"
echo "  需放行：8100-8107、13321、32000-32099、32100-32199、9100、50088（两台都要）"
systemctl is-active firewalld >/dev/null 2>&1 && warn "firewalld 运行中，确认放行" || ok "未检测到 firewalld"

echo
echo "=============================================="
echo " 预检结果： PASS=$PASS  WARN=$WARN  FAIL=$FAIL"
echo "=============================================="
[ "$FAIL" -eq 0 ] || { echo "存在 FAIL 项（第 3 项的 NPU 占用属预期，停 4P1D 引擎后重跑即可转 PASS）。"; exit 1; }
exit 0
