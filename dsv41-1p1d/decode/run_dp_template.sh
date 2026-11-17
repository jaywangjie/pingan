#!/usr/bin/env bash
# =============================================================================
# DeepSeek-V4.1-Flash-1017 1P1D —— Decode 模板（DP8/TP2）
# 由 launch_online_dp.py 按 7 个位置参数调用：
#   $1: 本 rank 可见 NPU ID（如 0,1）  $2: API 端口（8100-8107）
#   $3: 全局 DP size（8）              $4: 全局 DP rank（0-7）
#   $5: DP 协调地址（D 节点 IP）       $6: DP 协调端口（13321）
#   $7: TP size（2）
# KV Pool 实验矩阵见 prefill/run_dp_template.sh 头部注释。
# 本模板池化时使用 mooncake_d.json（纯消费者 0/0，官方 11-11 配方）
# =============================================================================
set -euo pipefail
unset https_proxy http_proxy
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:+$LD_LIBRARY_PATH:}/usr/local/lib/"

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=/dev/null
source "$DEPLOY_DIR/config.sh"

NIC_NAME="${NIC_NAME:?set NIC_NAME in config.sh}"
LOCAL_IP="${LOCAL_IP:-$(hostname -I 2>/dev/null | awk '{print $1}')}"
MODEL_PATH="${MODEL_PATH:?set MODEL_PATH in config.sh}"

export no_proxy="127.0.0.1,localhost,${P1_IP},${D1_IP}"
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

# ---- 防 107000 雪崩（验证有效，保留）----------------------------------------
export ACL_OP_INIT_MODE=1
# 以下两项在驱动 25.2.1 与镜像 CANN 配对下会使 mooncake real_client 创建失败，
# 待驱动/镜像升级后按 DEPLOYMENT_RECORD_1P1D.md 的实验矩阵重新启用：
# export ASCEND_ENABLE_USE_FABRIC_MEM=1
# export MOONCAKE_OFFLOAD_LOCAL_BUFFER_SIZE_BYTES=1073741824
# export ASCEND_GLOBAL_RESOURCE_CONFIG='{"comm_resource_config.protocol_desc":["hccs:device"],"store.comm_resource_config.protocol_desc":["roce:device"]}'

# ---- KV Cache Pool：按 config.sh 的 ENABLE_KV_POOL 选择连接器形态 ------------
if [ "${ENABLE_KV_POOL:-0}" = "1" ]; then
    # Decode 是纯消费者：mooncake_d.json 零贡献（官方警告 D 预留池内存会
    # rtsHostRegister 失败并挤占引擎主机内存）
    export PYTHONHASHSEED=0
    export MOONCAKE_CONFIG_PATH="$DEPLOY_DIR/kv_pool/mooncake_d.json"
    KV_TRANSFER_CONFIG='{
        "kv_connector":"MultiConnector",
        "kv_role":"kv_consumer",
        "kv_port":"'"$KV_CONSUMER_PORT"'",
        "engine_id":"1",
        "kv_connector_extra_config":{
            "connectors":[
                {
                    "kv_connector":"MooncakeHybridConnector",
                    "kv_role":"kv_consumer",
                    "kv_port":"'"$KV_CONSUMER_PORT"'",
                    "kv_connector_extra_config":{
                        "prefill":{"dp_size":'"$PREFILL_DP_SIZE"',"tp_size":'"$PREFILL_TP_SIZE"'},
                        "decode":{"dp_size":'"$DECODE_DP_SIZE"',"tp_size":'"$DECODE_TP_SIZE"'}
                    }
                },
                {
                    "kv_connector":"AscendStoreConnector",
                    "kv_role":"kv_consumer",
                    "kv_connector_extra_config":{
                        "backend":"mooncake",
                        "lookup_rpc_port":"0",
                        "use_layerwise":false
                    }
                }
            ]
        }
    }'
else
    KV_TRANSFER_CONFIG='{
        "kv_connector":"MooncakeHybridConnector",
        "kv_role":"kv_consumer",
        "kv_port":"'"$KV_CONSUMER_PORT"'",
        "kv_connector_extra_config":{
            "prefill":{"dp_size":'"$PREFILL_DP_SIZE"',"tp_size":'"$PREFILL_TP_SIZE"'},
            "decode":{"dp_size":'"$DECODE_DP_SIZE"',"tp_size":'"$DECODE_TP_SIZE"'}
        }
    }'
fi

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
    --kv-transfer-config "$KV_TRANSFER_CONFIG" \
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
