#!/usr/bin/env bash
# =============================================================================
# DeepSeek-V4.1-Flash-1017 1P1D + KV Cache Pool 集群全局配置
# 与 4P1D 包（dsv41-4p1d）完全隔离：独立目录 / 独立容器 / 独立端口段
#
# ⚠️ 资源互斥：NPU 不能同时跑两套。启动本包引擎前，需先停止所选 2 台
#    机器上运行的 4P1D 引擎（只停进程，4P1D 文件不受影响，可随时拉回）。
# =============================================================================

# ---- 节点 IP（1 台 Prefill + 1 台 Decode，按实际选择修改）-----------------
P1_IP="192.168.0.4"      # 001 Prefill（DP4/TP4）
D1_IP="192.168.0.204"    # 005 Decode（DP8/TP2）

# ---- 高速业务网口（与 4P1D 同一批机器）--------------------------------------
NIC_NAME="${NIC_NAME:-enp23s0f3}"

# ---- 模型权重（与 4P1D 共用同一份，只读）------------------------------------
MODEL_PATH="${MODEL_PATH:-/mnt/sfs_turbo/models/DeepSeek-V4.1-Flash-1017-w8a8}"
QUANTIZATION="${QUANTIZATION:-ascend}"

# ---- 镜像与容器（独立容器，可与 4P1D 容器并存）------------------------------
IMAGE="${IMAGE:-quay.io/ascend/vllm-ascend:v0.30.0-a3}"
CONTAINER_NAME="${CONTAINER_NAME:-deepseek-v41-1p1d}"

# ---- 部署包路径 ---------------------------------------------------------------
DEPLOY_ROOT="${DEPLOY_ROOT:-/mnt/sfs_turbo/deploy/dsv41-1p1d}"

# ---- 服务参数 -----------------------------------------------------------------
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-dsv41}"
VLLM_USE_V2_MODEL_RUNNER="${VLLM_USE_V2_MODEL_RUNNER:-1}"

# ---- 端口规划（全部避开 4P1D 的 7100/12321/30000/30100/9000）----------------
PROXY_PORT="${PROXY_PORT:-9100}"                 # PD 代理（4P1D 用 9000）
ENGINE_START_PORT="${ENGINE_START_PORT:-8100}"   # P: 8100-8103，D: 8100-8107
DP_RPC_PORT="${DP_RPC_PORT:-13321}"              # DP 协调（4P1D 用 12321）
KV_PRODUCER_PORT="${KV_PRODUCER_PORT:-32000}"    # Mooncake KV 生产（4P1D 用 30000）
KV_CONSUMER_PORT="${KV_CONSUMER_PORT:-32100}"    # Mooncake KV 消费（4P1D 用 30100）

# ---- KV Cache Pool（Mooncake 后端，官方 2026-11-11 更新配方）------------------
# 1=开池化（P 贡献容量 + D 纯消费者双配置）；0=回退纯 PD 分离（已验证稳定）
ENABLE_KV_POOL="${ENABLE_KV_POOL:-1}"
MOONCAKE_MASTER_IP="${MOONCAKE_MASTER_IP:-$D1_IP}"   # master 放 D 节点容器内
MOONCAKE_MASTER_PORT="${MOONCAKE_MASTER_PORT:-50088}"
MOONCAKE_SEGMENT_SIZE="${MOONCAKE_SEGMENT_SIZE:-24GB}"  # P 侧每 rank 贡献池容量（D 侧固定 0）
MOONCAKE_TENANT_ID="${MOONCAKE_TENANT_ID:-default}"     # 两侧必须一致

# ---- 并行布局（与 4P1D 的单台布局一致）----------------------------------------
PREFILL_DP_SIZE=4
PREFILL_TP_SIZE=4
DECODE_DP_SIZE=8
DECODE_TP_SIZE=2

# ---- PD 代理脚本（镜像内路径）--------------------------------------------------
PROXY_SCRIPT="${PROXY_SCRIPT:-/vllm-workspace/vllm-ascend/examples/disaggregated_prefill_v1/load_balance_proxy_server_example.py}"
