#!/usr/bin/env bash
# =============================================================================
# DeepSeek-V4.1-Flash-1017 1P1D —— Prefill 模板（DP4/TP4）
# 由 launch_online_dp.py 按 7 个位置参数调用：
#   $1: 本 rank 可见 NPU ID（如 0,1,2,3）  $2: API 端口（8100-8103）
#   $3: 全局 DP size（4）                  $4: 全局 DP rank（0-3）
#   $5: DP 协调地址（本机 IP）             $6: DP 协调端口（13321）
#   $7: TP size（4）
# -----------------------------------------------------------------------------
# KV Pool 实验矩阵（详见 DEPLOYMENT_RECORD_1P1D.md）：
#   - 原始配置：池写入 HBM→DRAM 触发 107000/ChannelCreate，85 分钟后引擎雪崩
#   - ACL_OP_INIT_MODE=1：治好雪崩（保留）
#   - ASCEND_ENABLE_USE_FABRIC_MEM=1：与驱动 25.2.1×CANN 配对不兼容（已弃用）
#   - 2026-11-17 官方新配方重试（config.sh ENABLE_KV_POOL=1）：
#     ① D 侧改纯消费者 mooncake_d.json（0/0，官方警告 D 预留池内存会
#        rtsHostRegister 失败）② P 侧 local_buffer_size=1GB
#     ③ master 加 --client_ttl=120（防慢编译 worker 被踢）
#   - 回退：config.sh 设 ENABLE_KV_POOL=0 → 纯 PD（已验证稳定形态）
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
export HCCL_BUFFSIZE="${HCCL_BUFFSIZE:-1024}"
export HCCL_CONNECT_TIMEOUT="${HCCL_CONNECT_TIMEOUT:-1200}"
export HCCL_OP_EXPANSION_MODE="${HCCL_OP_EXPANSION_MODE:-AIV}"
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
    # 池键由块哈希派生，两侧 PYTHONHASHSEED 必须同为 0，否则查找永远不命中
    export PYTHONHASHSEED=0
    export MOONCAKE_CONFIG_PATH="$DEPLOY_DIR/kv_pool/mooncake.json"
    KV_TRANSFER_CONFIG='{
        "kv_connector":"MultiConnector",
        "kv_role":"kv_producer",
        "kv_port":"'"$KV_PRODUCER_PORT"'",
        "engine_id":"0",
        "kv_connector_extra_config":{
            "connectors":[
                {
                    "kv_connector":"MooncakeHybridConnector",
                    "kv_role":"kv_producer",
                    "kv_port":"'"$KV_PRODUCER_PORT"'",
                    "kv_connector_extra_config":{
                        "prefill":{"dp_size":'"$PREFILL_DP_SIZE"',"tp_size":'"$PREFILL_TP_SIZE"'},
                        "decode":{"dp_size":'"$DECODE_DP_SIZE"',"tp_size":'"$DECODE_TP_SIZE"'}
                    }
                },
                {
                    "kv_connector":"AscendStoreConnector",
                    "kv_role":"kv_producer",
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
        "kv_role":"kv_producer",
        "kv_port":"'"$KV_PRODUCER_PORT"'",
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
    --kv-transfer-config "$KV_TRANSFER_CONFIG"
