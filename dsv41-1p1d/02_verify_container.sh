#!/usr/bin/env bash
# =============================================================================
# 容器内环境验证（在 deepseek-v41-1p1d 容器内运行）
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

section "1. NPU 可见性"
DAVINCI_COUNT=$(ls /dev/davinci[0-9]* 2>/dev/null | wc -l)
[ "$DAVINCI_COUNT" -eq 16 ] && ok "逻辑设备数：16" || bad "逻辑设备数：$DAVINCI_COUNT（预期 16）"

section "2. vLLM / vLLM-Ascend"
if command -v vllm >/dev/null 2>&1; then
    vllm --version 2>&1 | grep -vE '^INFO' | sed -n '1,3p'
else
    bad "vllm 命令不在 PATH"
fi
python3 -c "import torch_npu" >/dev/null 2>&1 && ok "torch_npu 导入正常" || bad "torch_npu 导入失败"
python3 -c "import torch, torch_npu; print('  npu device_count =', torch.npu.device_count())" 2>/dev/null \
    && ok "NPU 运行时初始化正常" || bad "NPU 运行时初始化失败"
python3 -c "import vllm_ascend" 2>/dev/null && ok "vllm_ascend 导入正常" || bad "vllm_ascend 导入失败"

section "3. KV Pool 依赖"
command -v mooncake_master >/dev/null 2>&1 \
    && ok "mooncake_master 命令存在" \
    || bad "mooncake_master 不在 PATH（镜像无该命令则无法开池化，检查镜像版本）"
[ -f "$SCRIPT_DIR/kv_pool/mooncake.json" ] \
    && ok "mooncake.json 已生成：$SCRIPT_DIR/kv_pool/mooncake.json" \
    && grep master_server_address "$SCRIPT_DIR/kv_pool/mooncake.json" \
    || warn "mooncake.json 未生成（先跑 kv_pool/start_mooncake_master.sh，不阻塞引擎启动会阻塞池化）"

section "4. 权重与部署包"
[ -f "$MODEL_PATH/config.json" ] && ok "$MODEL_PATH 可访问" || bad "$MODEL_PATH 不可访问"
[ -f "$SCRIPT_DIR/start_prefill_node.sh" ] && ok "部署包路径：$SCRIPT_DIR" || bad "部署包路径异常"

section "5. 节点互通（容器 --net=host）"
LOCAL_IPS="$({ hostname -I 2>/dev/null || true; { ip -4 addr 2>/dev/null | awk '/inet /{print $2}'; } || true; } | tr ' ' '\n' | cut -d/ -f1 | grep -v '^$' | sort -u)"
echo "  本机 IP：$(echo $LOCAL_IPS | tr '\n' ' ')"
for ip in "$P1_IP" "$D1_IP"; do
    echo "$LOCAL_IPS" | grep -qx "$ip" && continue
    if timeout 2 bash -c "exec 3<>/dev/tcp/$ip/22" 2>/dev/null; then
        ok "TCP $ip:22 可达"
    else
        bad "$ip 不可达"
    fi
done

echo
echo "=============================================="
echo " 容器验证结果： PASS=$PASS  WARN=$WARN  FAIL=$FAIL"
echo "=============================================="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
