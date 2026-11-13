#!/usr/bin/env bash
# =============================================================================
# 容器内环境验证（01_start_container.sh 之后，在容器内运行一次）
#   docker exec -it deepseek-v41-4p1d bash
#   bash /mnt/sfs_turbo/deploy/dsv41-4p1d/02_verify_container.sh
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

section "1. NPU 可见性（容器内应见 16 个逻辑设备）"
if command -v npu-smi >/dev/null 2>&1; then
    DAVINCI_COUNT=$(ls /dev/davinci[0-9]* 2>/dev/null | wc -l)
    [ "$DAVINCI_COUNT" -eq 16 ] && ok "/dev/davinci 逻辑设备数：16" \
        || bad "逻辑设备数：$DAVINCI_COUNT（预期 16）"
    npu-smi info 2>/dev/null | head -25
else
    bad "npu-smi 不可用"
fi

section "2. vLLM / vLLM-Ascend 版本"
if command -v vllm >/dev/null 2>&1; then
    vllm --version 2>&1 | grep -vE '^INFO' | sed -n '1,5p'
else
    bad "vllm 命令不在 PATH"
fi
# 分层定位导入问题：torch_npu（CANN 运行时） -> vllm -> vllm_ascend
python3 -c "import torch_npu" >/dev/null 2>&1 \
    && ok "torch_npu 导入正常" \
    || bad "torch_npu 导入失败（CANN/驱动问题，见 README FAQ）"
python3 -c "import torch, torch_npu; print('  npu device_count =', torch.npu.device_count())" 2>/dev/null \
    && ok "NPU 运行时初始化正常" \
    || bad "NPU 运行时初始化失败（ERR99999，见 README FAQ）"
python3 -c "import vllm; print('  vllm', vllm.__version__)" 2>/dev/null \
    && ok "vllm 包导入正常" || bad "vllm 包导入失败"
python3 -c "import vllm_ascend; print('  vllm_ascend', vllm_ascend.__version__)" 2>/dev/null \
    && ok "vllm_ascend 导入正常" || bad "vllm_ascend 导入失败"

section "3. 权重可见（容器内路径与宿主机一致）"
if [ -f "$MODEL_PATH/config.json" ]; then
    ok "$MODEL_PATH 可访问"
else
    bad "$MODEL_PATH 不可访问，检查 /mnt/sfs_turbo 挂载与 config.sh 的 MODEL_PATH"
fi

section "4. 部署脚本可见"
[ -f "$SCRIPT_DIR/start_prefill_node.sh" ] && ok "部署包路径：$SCRIPT_DIR" \
    || bad "部署包路径异常：$SCRIPT_DIR"

section "5. PD 代理脚本"
if [ -f "$PROXY_SCRIPT" ]; then
    ok "$PROXY_SCRIPT"
else
    FOUND=$(find /vllm-workspace -name load_balance_proxy_server_example.py 2>/dev/null | head -1)
    if [ -n "$FOUND" ]; then
        warn "默认路径未找到，实际路径：$FOUND（请更新 config.sh 的 PROXY_SCRIPT）"
    else
        bad "镜像内未找到 load_balance_proxy_server_example.py"
    fi
fi

section "6. 节点互通（容器 --net=host）"
# 容器内可能没有 ip/ping 命令：本机识别用 hostname -I 兜底，
# 连通性用 bash 内建 /dev/tcp 探测 22 端口（五台宿主机都有 sshd）
LOCAL_IPS="$({ hostname -I 2>/dev/null || true; ip -4 addr 2>/dev/null | awk '/inet /{print $2}'; } | tr ' ' '\n' | cut -d/ -f1 | grep -v '^$' | sort -u)"
echo "  本机 IP：$(echo $LOCAL_IPS | tr '\n' ' ')"
for ip in "$P1_IP" "$P2_IP" "$P3_IP" "$P4_IP" "$D1_IP"; do
    echo "$LOCAL_IPS" | grep -qx "$ip" && continue
    if timeout 2 bash -c "exec 3<>/dev/tcp/$ip/22" 2>/dev/null; then
        ok "TCP $ip:22 可达"
    elif ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
        ok "ping $ip 可达"
    else
        bad "$ip 不可达（TCP:22 与 ping 均失败）"
    fi
done

echo
echo "=============================================="
echo " 容器验证结果： PASS=$PASS  WARN=$WARN  FAIL=$FAIL"
echo "=============================================="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
