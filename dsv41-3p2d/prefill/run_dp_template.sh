#!/usr/bin/env bash
# =============================================================================
# DeepSeek-V4.1-Flash-1017 3P2D —— Prefill 模板（本机 DP4/TP4，全局 DP12/TP4）
# 由 launch_online_dp.py 按 7 个位置参数调用：
#   $1: 本 rank 可见 NPU ID（如 0,1,2,3）  $2: API 端口（8200-8203）
#   $3: 全局 DP size（12）                 $4: 全局 DP rank（001:0-3 / 002:4-7 / 003:8-11）
#   $5: DP 协调地址（P 组 master = 001 IP） $6: DP 协调端口（14321）
#   $7: TP size（4）
# -----------------------------------------------------------------------------
# 纯 PD 形态（无 KV 池）——池化因驱动 25.2.1×CANN 配对问题暂不可用，
# 见 ../dsv41-1p1d/DEPLOYMENT_RECORD_1P1D.md
# ACL_OP_INIT_MODE=1 为 1P1D 排障验证的稳定性参数（防 107000 雪崩），保留
# =============================================================================
set -euo pipefail
unset https_proxy http_proxy
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}/usr/local/lib/"

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$DEPLOY_DIR/config.sh"

NIC_NAME="${NIC_NAME:?set NIC_NAME in config.sh}"
LOCAL_IP="${LOCAL_IP:?export LOCAL_IP before run (start_prefill_node.sh 会设置)}"
MODEL_PATH="${MODEL_PATH:?set MODEL_PATH in config.sh}"

export no_proxy="127.0.0.1,localhost,${P1_IP},${P2_IP},${P3_IP},${D1_IP},${D2_IP}"
export NO_PROXY="$no_proxy"

export HCCL_IF_IP="$LOCAL_IP"
export GLOO_SOCKET_IFNAME="$NIC_NAME"
export TP_SOCKET_IFNAME="$NIC_NAME"
export HCCL_SOCKET_IFNAME="$NIC_NAME"

export VLLM_USE_V2_MODEL_RUNNER="$VLLM_USE_V2_MODEL_RUNNER"
export VLLM_ENGINE_READY_TIMEOUT_S="${VLLM_ENGINE_READY_TIMEOUT_S:-360000}"
export VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS="${VLLM_EXECUTE_MODEL_TIMEOUT_SECONDS:-3000}"
export HCCL_BUFFSIZE="${HCCL_BUFFSIZE:-1024}"
export HCCL_CONNECT_TIMEOUT="${HCCL_CONNECT_TIMEOUT:-1200}"
export HCCL_OP_EXPANSION_MODE="${HCCL_OP_EXPANSION_MODE:-AIV}"
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export ASCEND_RT_VISIBLE_DEVICES="$1"

# ---- 防 107000 雪崩（1P1D 排障验证有效，保留）--------------------------------
export ACL_OP_INIT_MODE=1

vllm serve "$MODEL_PATH" \
    --host 0.0.0.0 \
    --port "$2" \
    --data-parallel-size "$3" \
    --data-parallel-size-local "$PREFILL_DP_SIZE_LOCAL" \
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
            "prefill":{"dp_size":'"$PREFILL_DP_SIZE"',"tp_size":'"$PREFILL_TP_SIZE"'},
            "decode":{"dp_size":'"$DECODE_DP_SIZE"',"tp_size":'"$DECODE_TP_SIZE"'}
        }
    }'
