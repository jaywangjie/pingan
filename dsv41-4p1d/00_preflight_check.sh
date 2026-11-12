#!/usr/bin/env bash
# =============================================================================
# 部署前预检（在 5 台 A3 服务器的宿主机上各运行一次）
# 检查 NPU / 驱动 / 内存 / 磁盘 / 权重 / 端口 / 节点连通 / 网卡
# =============================================================================
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/config.sh"

PASS=0; WARN=0; FAIL=0
ok()   { echo "  [PASS] $*"; PASS=$((PASS+1)); }
warn() { echo "  [WARN] $*"; WARN=$((WARN+1)); }
bad()  { echo "  [FAIL] $*"; FAIL=$((FAIL+1)); }
head() { echo; echo "==== $* ===="; }

LOCAL_IP=""
for ip in "$P1_IP" "$P2_IP" "$P3_IP" "$P4_IP" "$D1_IP"; do
    ip -4 addr | grep -qw "$ip" && LOCAL_IP="$ip" && break
done

head "1. 本机识别"
if [ -n "$LOCAL_IP" ]; then
    ok "本机 IP：$LOCAL_IP"
else
    bad "本机 IP 不在节点列表（$P1_IP $P2_IP $P3_IP $P4_IP $D1_IP），请检查网络"
    ip -4 addr | grep inet
fi

head "2. NPU 设备（预期 16 个逻辑设备）"
if command -v npu-smi >/dev/null 2>&1; then
    NPU_COUNT=$(npu-smi info -l 2>/dev/null | grep -c "Total Count" || true)
    DAVINCI_COUNT=$(ls /dev/davinci[0-9]* 2>/dev/null | wc -l)
    if [ "$DAVINCI_COUNT" -eq 16 ]; then
        ok "/dev/davinci 逻辑设备数：16"
    else
        bad "/dev/davinci 逻辑设备数：$DAVINCI_COUNT（预期 16，8 卡 × 2 die）"
    fi
    npu-smi info 2>/dev/null | head -25
else
    bad "未找到 npu-smi 命令，驱动未安装或不在 PATH"
fi

head "3. 内存（Engram 驻留约 196GB + 加载缓冲，建议 ≥1.5TB）"
free -g | head -3
MEM_GB=$(free -g | awk '/^Mem:/{print $2}')
[ "${MEM_GB:-0}" -ge 1500 ] && ok "内存 ${MEM_GB}GB" || warn "内存 ${MEM_GB}GB，低于建议值 1.5TB"

head "4. SFS Turbo 共享存储与权重"
if mountpoint -q /mnt/sfs_turbo 2>/dev/null || [ -d /mnt/sfs_turbo ]; then
    ok "/mnt/sfs_turbo 存在"
    df -h /mnt/sfs_turbo | tail -1
    if [ -f "$MODEL_PATH/config.json" ]; then
        ok "权重配置存在：$MODEL_PATH/config.json"
        ST_COUNT=$(ls "$MODEL_PATH"/*.safetensors 2>/dev/null | wc -l)
        ok "safetensors 分片数：$ST_COUNT"
        du -sh "$MODEL_PATH" 2>/dev/null | tail -1
        # 量化形态提示
        if grep -q "deepseek_v4_fp8\|mxfp" "$MODEL_PATH/config.json" 2>/dev/null; then
            warn "config.json 疑似官方 MXFP 权重：需将 config.sh 的 QUANTIZATION 改为 deepseek_v4_fp8"
        elif grep -qi "w8a8\|w4a8\|ascend" "$MODEL_PATH/config.json" 2>/dev/null; then
            ok "config.json 疑似 Ascend 量化权重（QUANTIZATION=ascend 正确）"
        else
            warn "无法从 config.json 判断量化形态，请人工确认 QUANTIZATION 取值"
        fi
    else
        bad "权重目录缺失 config.json：$MODEL_PATH —— 请修改 config.sh 的 MODEL_PATH"
        ls /mnt/sfs_turbo 2>/dev/null | head -20
    fi
else
    bad "/mnt/sfs_turbo 不存在或未挂载"
fi

head "5. 端口占用（应全部空闲）"
BUSY=0
for port in "$DP_RPC_PORT" 9000 7100 7101 7102 7103 7104 7105 7106 7107; do
    if ss -tln 2>/dev/null | awk '{print $4}' | grep -qE ":$port$"; then
        bad "端口 $port 已被占用：$(ss -tlnp 2>/dev/null | grep -E ":$port\b" | head -1)"
        BUSY=1
    fi
done
[ "$BUSY" -eq 0 ] && ok "12321/7100-7107/9000 均空闲"

head "6. 防火墙（需放行 12321、7100-7107、30000-30099、30100-30199、9000）"
if systemctl is-active firewalld >/dev/null 2>&1; then
    warn "firewalld 运行中，请确认已放行上述端口："
    firewall-cmd --list-ports 2>/dev/null
elif iptables -L -n >/dev/null 2>&1 && [ "$(iptables -S 2>/dev/null | grep -cvE '^(-P|:)')" -gt 0 ]; then
    warn "iptables 存在自定义规则，请人工确认放行情况"
else
    ok "未检测到活跃防火墙"
fi

head "7. 节点互通（ping 其余 4 台）"
for ip in "$P1_IP" "$P2_IP" "$P3_IP" "$P4_IP" "$D1_IP"; do
    [ "$ip" = "$LOCAL_IP" ] && continue
    if ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
        ok "ping $ip"
    else
        bad "ping $ip 不通"
    fi
done

head "8. 网卡（$NIC_NAME 应承载 192.168.0.x 业务 IP）"
if ip link show "$NIC_NAME" >/dev/null 2>&1; then
    NIP=$(ip -4 addr show "$NIC_NAME" | awk '/inet /{print $2}' | head -1)
    if [ -n "$NIP" ]; then
        ok "$NIC_NAME 携带 $NIP"
    else
        warn "$NIC_NAME 无 IPv4，请修改 config.sh 的 NIC_NAME"
    fi
else
    bad "网卡 $NIC_NAME 不存在，请修改 config.sh 的 NIC_NAME。当前网卡："
    ip -4 -o addr | awk '{print $2, $4}'
fi

head "9. Docker"
if command -v docker >/dev/null 2>&1; then
    ok "docker $(docker --version 2>/dev/null | awk '{print $3}' | tr -d ,)"
    if docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -q "^$IMAGE$"; then
        ok "镜像已存在：$IMAGE"
    else
        warn "镜像未拉取：$IMAGE（01_start_container.sh 会自动 pull，若内网需先配镜像源/代理）"
    fi
else
    bad "未安装 docker"
fi

echo
echo "=============================================="
echo " 预检结果： PASS=$PASS  WARN=$WARN  FAIL=$FAIL"
echo "=============================================="
[ "$FAIL" -eq 0 ] || { echo "存在 FAIL 项，请先处理后继续部署。"; exit 1; }
[ "$WARN" -eq 0 ] || echo "存在 WARN 项，请人工确认。"
exit 0
