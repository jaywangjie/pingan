#!/usr/bin/env bash
# =============================================================================
# DeepSeek-V4.1-Flash-1017 3P2D —— Decode 模板（本机 DP8/TP2，全局 DP16/TP2）
# 由 launch_online_dp.py 按 7 个位置参数调用：
#   $1: 本 rank 可见 NPU ID（如 0,1）  $2: API 端口（8200-8207）
#   $3: 全局 DP size（16）             $4: 全局 DP rank（004:0-7 / 005:8-15）
#   $5: DP 协调地址（D 组 master = 004 IP）  $6: DP 协调端口（14321）
#   $7: TP size（2）
# 纯 PD 形态；ACL_OP_INIT_MODE=1 保留（见 prefill/run_dp_template.sh 头部注释）
# =============================================================================
set -euo pipefail
unset https_proxy http_proxy
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}/usr/local/lib/"

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$DEPLOY_DIR/config.sh"

NIC_NAME="${NIC_NAME:?set NIC_NAME in config.sh}"
LOCAL_IP="${LOCAL_IP:?export LOCAL_IP before run (start_decode_node.sh 会设置)}"
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
export HCCL_BUFFSIZE="${HCCL_BUFFSIZE:-4096}"
export HCCL_CONNECT_TIMEOUT="${HCCL_CONNECT_TIMEOUT:-1200}"
export PYTORCH_NPU_ALLOC_CONF=expandable_segments:True
export ASCEND_RT_VISIBLE_DEVICES="$1"

# ---- 防 107000 雪崩（1P1D 排障验证有效，保留）--------------------------------
export ACL_OP_INIT_MODE=1

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
    --max-num-batched-tokens 512 \
    --max-num-seqs 72 \
    --async-scheduling \
    --block-size 128 \
    --no-enable-prefix-caching \
    --trust-remote-code \
    --tokenizer-mode deepseek_v41 \
    --reasoning-parser deepseek_v41 \
    --tool-call-parser deepseek_v41 \
    --enable-auto-tool-choice \
    --safetensors-load-strategy lazy \
    --gpu-memory-utilization 0.95 \
    --quantization "$QUANTIZATION" \
    --speculative-config '{"num_speculative_tokens":5,"method":"dspark","enforce_eager":true}' \
    --compilation-config '{"cudagraph_mode":"FULL_DECODE_ONLY"}' \
    --kv-transfer-config '{
        "kv_connector":"MooncakeHybridConnector",
        "kv_role":"kv_consumer",
        "kv_port":"'"$KV_CONSUMER_PORT"'",
        "kv_connector_extra_config":{
            "prefill":{"dp_size":'"$PREFILL_DP_SIZE"',"tp_size":'"$PREFILL_TP_SIZE"'},
            "decode":{"dp_size":'"$DECODE_DP_SIZE"',"tp_size":'"$DECODE_TP_SIZE"'}
        }
    }' \
    --engram-config '{"cpu_offload":true,"dp_shared_memory":true}' \
    --additional-config '{
        "ascend_compilation_config":{
            "enable_npugraph_ex":true,
            "enable_static_kernel":false
        },
        "enable_cpu_binding":true,
        "multistream_overlap_shared_expert":true,
        "recompute_scheduler_enable":true
    }'
