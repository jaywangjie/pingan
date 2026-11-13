#!/usr/bin/env bash
# =============================================================================
# DeepSeek-V4.1-Flash-1017 4P1D —— Prefill 节点模板（DP4/TP4）
# 由 launch_online_dp.py 按 8 个位置参数调用，也可手工执行：
#   $1: 本 rank 可见 NPU ID 列表（如 0,1,2,3）
#   $2: 本 rank API 端口（7100-7103）
#   $3: 全局 DP size（本布局固定 4）
#   $4: 全局 DP rank（0-3）
#   $5: DP 协调地址（本机 IP）
#   $6: DP 协调端口（12321）
#   $7: TP size（本布局固定 4）
# 布局依据：POC 方案 V1.4 §6.2 + 官方 A3 W8A8 PD 布局（Prefill DP4/TP4）
# =============================================================================
set -euo pipefail
unset https_proxy http_proxy
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}/usr/local/lib/"

# ---- 加载集群全局配置 ------------------------------------------------------
DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$DEPLOY_DIR/config.sh"

NIC_NAME="${NIC_NAME:?set NIC_NAME in config.sh}"
# LOCAL_IP 由 start_prefill_node.sh 识别后传入；兜底取 hostname -I 第一项
LOCAL_IP="${LOCAL_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
MODEL_PATH="${MODEL_PATH:?set MODEL_PATH in config.sh}"

# ---- 代理豁免：五台节点互访不走代理 ----------------------------------------
export no_proxy="127.0.0.1,localhost,${P1_IP},${P2_IP},${P3_IP},${P4_IP},${D1_IP}"
export NO_PROXY="$no_proxy"

# ---- 通信环境：HCCL/GLOO/TP 走同一高速网口 ----------------------------------
export HCCL_IF_IP="$LOCAL_IP"
export GLOO_SOCKET_IFNAME="$NIC_NAME"
export TP_SOCKET_IFNAME="$NIC_NAME"
export HCCL_SOCKET_IFNAME="$NIC_NAME"

# ---- vLLM-Ascend 运行环境 ---------------------------------------------------
# A3 官方教程使用 Model Runner V2；如遇算子/调度不兼容可回退 0（见 config.sh）
export VLLM_USE_V2_MODEL_RUNNER="$VLLM_USE_V2_MODEL_RUNNER"
# 权重走 SFS Turbo 共享存储，加载慢，超时放大（官方 A2 共享存储场景同款 360000）
export VLLM_ENGINE_READY_TIMEOUT_S="${VLLM_ENGINE_READY_TIMEOUT_S:-360000}"
export VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS="${VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS:-3000}"
export HCCL_BUFFSIZE="${HCCL_BUFFSIZE:-1024}"
export HCCL_CONNECT_TIMEOUT="${HCCL_CONNECT_TIMEOUT:-1200}"
export HCCL_OP_EXPANSION_MODE="${HCCL_OP_EXPANSION_MODE:-AIV}"
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export ASCEND_RT_VISIBLE_DEVICES="$1"

# ---- 启动 Prefill 引擎 ------------------------------------------------------
# 说明：
# - kv_connector_extra_config 必须与两侧实际布局一致：
#     prefill {dp_size:4, tp_size:4}，decode {dp_size:8, tp_size:2}
# - 前缀缓存只在 P 侧开启；D 侧关闭并开重算调度器
# - kv_port 30000 为基址，四台 P 各自主机复用不冲突（代理按 IP 区分）
vllm serve "$MODEL_PATH" \
    --host 0.0.0.0 \
    --port "$2" \
    --data-parallel-size "$3" \
    --data-parallel-rank "$4" \
    --data-parallel-address "$5" \
    --data-parallel-rpc-port "$6" \
    --tensor-parallel-size "$7" \
    --enable-expert-parallel \
    --seed 1024 \
    --served-model-name "$SERVED_MODEL_NAME" \
    --max-model-len 1048576 \
    --max-num-batched-tokens 8192 \
    --max-num-seqs 16 \
    --speculative-config '{"num_speculative_tokens":5,"method":"dspark"}' \
    --trust-remote-code \
    --block-size 128 \
    --tokenizer-mode deepseek_v41 \
    --reasoning-parser deepseek_v41 \
    --tool-call-parser deepseek_v41 \
    --enable-auto-tool-choice \
    --safetensors-load-strategy lazy \
    --gpu-memory-utilization 0.9 \
    --quantization "$QUANTIZATION" \
    --enforce-eager \
    --enable-prefix-caching \
    --engram-config '{"cpu_offload":true,"dp_shared_memory":true}' \
    --additional-config '{
        "enable_cpu_binding":true,
        "enable_fused_mc2":2,
        "enable_flashcomm1":false,
        "multistream_overlap_shared_expert":false
    }' \
    --kv-transfer-config '{
        "kv_connector":"MooncakeHybridConnector",
        "kv_role":"kv_producer",
        "kv_port":"'"$KV_PRODUCER_PORT"'",
        "kv_connector_extra_config":{
            "prefill":{"dp_size":4,"tp_size":4},
            "decode":{"dp_size":8,"tp_size":2}
        }
    }'
