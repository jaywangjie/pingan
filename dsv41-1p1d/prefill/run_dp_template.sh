#!/usr/bin/env bash
# =============================================================================
# DeepSeek-V4.1-Flash-1017 1P1D + KV Cache Pool —— Prefill 模板（DP4/TP4）
# 由 launch_online_dp.py 按 7 个位置参数调用：
#   $1: 本 rank 可见 NPU ID（如 0,1,2,3）  $2: API 端口（8100-8103）
#   $3: 全局 DP size（4）                  $4: 全局 DP rank（0-3）
#   $5: DP 协调地址（本机 IP）             $6: DP 协调端口（13321）
#   $7: TP size（4）
# 与 4P1D 模板的差异：
#   1) kv-transfer-config 用 MultiConnector：Mooncake 传输 + AscendStore 池化
#      （可复用前缀持久化进 Mooncake 池，任何引擎可命中 = 分布式缓存）
#   2) 增加 KV Pool 必需环境变量（PYTHONHASHSEED / MOONCAKE_CONFIG_PATH）
#   3) 端口全部换到 8100 段 / 32000 段，与 4P1D 不冲突
# 其余参数与已验证跑通的 4P1D prefill 模板完全一致
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

# ---- KV Cache Pool（Mooncake 后端）必需环境变量 -----------------------------
export PYTHONHASHSEED=0
export MOONCAKE_CONFIG_PATH="$DEPLOY_DIR/kv_pool/mooncake.json"

# ---- KV Cache Pool A3 必需（官方 kv_cache_pool_ascend_store 指南 A3 分支）----
# fabric 通信内存 + 算子初始化模式：池写入(HBM→本机DRAM segment)的 HCCS 通道依赖，
# 缺失时 aclrtIpcMemImportByKey 报 107000、ChannelCreate fail，最终击穿引擎
export ACL_OP_INIT_MODE=1
export ASCEND_ENABLE_USE_FABRIC_MEM=1
# Store/PD 流量分离：PD 传输走 HCCS，池(Store)流量走 ROCE，不抢同一物理链路
export ASCEND_GLOBAL_RESOURCE_CONFIG='{"comm_resource_config.protocol_desc":["hccs:device"],"store.comm_resource_config.protocol_desc":["roce:device"]}'

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
                        "prefill":{"dp_size":4,"tp_size":4},
                        "decode":{"dp_size":8,"tp_size":2}
                    }
                },
                {
                    "kv_connector":"AscendStoreConnector",
                    "kv_role":"kv_producer",
                    "kv_connector_extra_config":{
                        "lookup_rpc_port":"0",
                        "backend":"mooncake",
                        "use_layerwise":false
                    }
                }
            ]
        }
    }'
