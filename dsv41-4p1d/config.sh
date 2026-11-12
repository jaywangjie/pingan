#!/usr/bin/env bash
# =============================================================================
# DeepSeek-V4.1-Flash-1017 4P1D 集群全局配置
# 依据：平安 POC 方案 V1.4（4P1D，P 侧 DP4/TP4，D 侧 DP8/TP2）
#       + vLLM-Ascend 官方 A3 教程（Mooncake PD 分离）
# 所有节点（host 与容器内）共用本文件，五台机器路径必须一致。
# =============================================================================

# ---- 节点 IP（前 4 台 Prefill，最后 1 台 Decode）--------------------------
P1_IP="192.168.0.4"      # 001
P2_IP="192.168.0.82"     # 002
P3_IP="192.168.0.42"     # 003
P4_IP="192.168.0.129"    # 004
D1_IP="192.168.0.204"    # 005  Decode 节点

# ---- 高速业务网口 -----------------------------------------------------------
# 用 `ip -4 addr` 找到承载上述 192.168.0.x 地址的网卡名（常见 eth0 / bond0），
# 五台机器必须同名，且 HCCL/GLOO/TP 通信都走这个口。
NIC_NAME="${NIC_NAME:-eth0}"

# ---- 模型权重 ---------------------------------------------------------------
# SFS Turbo 共享存储上的权重目录（五台挂载同一路径）。
# A3 上机权重应为 Ascend 量化版（w4a8 或 w8a8），按实际目录名修改。
MODEL_PATH="${MODEL_PATH:-/mnt/sfs_turbo/models/DeepSeek-V4.1-Flash-1017-w8a8}"

# 权重量化方式：
#   - Ascend 量化权重（w4a8 / w8a8）: ascend
#   - 官方 MXFP 权重            : deepseek_v4_fp8
QUANTIZATION="${QUANTIZATION:-ascend}"

# ---- 镜像 -------------------------------------------------------------------
# A3 服务器专用镜像（16 逻辑设备），五台必须同一 digest。
IMAGE="${IMAGE:-quay.io/ascend/vllm-ascend:v0.30.0-a3}"
CONTAINER_NAME="${CONTAINER_NAME:-deepseek-v41-4p1d}"

# ---- 部署包在共享存储上的绝对路径 -------------------------------------------
# 整个 dsv41-4p1d 目录拷到 SFS Turbo 后，五台容器内路径一致。
DEPLOY_ROOT="${DEPLOY_ROOT:-/mnt/sfs_turbo/deploy/dsv41-4p1d}"

# ---- 服务参数 ---------------------------------------------------------------
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-dsv41}"

# ---- Model Runner ------------------------------------------------------------
# 在线官方教程（A3）全部使用 V2（VLLM_USE_V2_MODEL_RUNNER=1）。
# 若按 POC 方案 V1.4 的记载遇到算子/调度不兼容，改为 0 回退 Model Runner V1。
VLLM_USE_V2_MODEL_RUNNER="${VLLM_USE_V2_MODEL_RUNNER:-1}"

# ---- 端口规划（与 POC 方案 3.5 节一致）---------------------------------------
PROXY_PORT="${PROXY_PORT:-9000}"          # PD 代理
ENGINE_START_PORT="${ENGINE_START_PORT:-7100}"  # P: 7100-7103，D: 7100-7107
DP_RPC_PORT="${DP_RPC_PORT:-12321}"       # DP 协调端口（每台 NPU 节点本地）
KV_PRODUCER_PORT="${KV_PRODUCER_PORT:-30000}"   # Mooncake KV 生产（每台 P）
KV_CONSUMER_PORT="${KV_CONSUMER_PORT:-30100}"   # Mooncake KV 消费（D 节点）

# ---- 并行布局 ---------------------------------------------------------------
# Prefill：每台一个独立 DP4/TP4 引擎（4 个 API 端口），四台互不做跨机集合通信
PREFILL_DP_SIZE=4
PREFILL_TP_SIZE=4
# Decode：单机 DP8/TP2 引擎（8 个 API 端口）
DECODE_DP_SIZE=8
DECODE_TP_SIZE=2

# ---- PD 代理脚本（镜像内路径，找不到时脚本会自动搜索）-----------------------
PROXY_SCRIPT="${PROXY_SCRIPT:-/vllm-workspace/vllm-ascend/examples/disaggregated_prefill_v1/load_balance_proxy_server_example.py}"
