#!/usr/bin/env bash
# =============================================================================
# DeepSeek-V4.1-Flash-1017 3P2D 集群全局配置（纯 PD 分离，无 KV 池）
# 与 dsv41-4p1d / dsv41-1p1d 完全隔离：独立目录 / 独立容器 / 独立端口段
#
# 拓扑：P = 001/002/003（每台独立 DP4/TP4 组，EP16，与 4P1D 的 P 同构）
#       D = 004/005    （每台独立 DP8/TP2 组，EP16，与 4P1D 的 D 同构）
#       连接器布局 prefill{4,4}/decode{8,2}，与 4P1D/1P1D 已验证配置一致
#
# ⚠️ 资源互斥：本包占用全部 5 台的 16 卡。启动前需停掉所有机器上的
#    4P1D 与 1P1D 引擎（只停进程，文件不动，可随时拉回）。
#
# 注：KV 池化因驱动 25.2.1×CANN 配对问题暂不可用（排障全程见
#     ../dsv41-1p1d/DEPLOYMENT_RECORD_1P1D.md），本包为纯 PD 形态。
# =============================================================================

# ---- 节点 IP（P 组 DP master=001，D 组 DP master=004）-------------------------
P1_IP="192.168.0.4"       # 001 Prefill#1（DP rank 0-3）
P2_IP="192.168.0.82"      # 002 Prefill#2（DP rank 4-7）
P3_IP="192.168.0.42"      # 003 Prefill#3（DP rank 8-11）
D1_IP="192.168.0.129"     # 004 Decode#1（DP rank 0-7，D 组 master）
D2_IP="192.168.0.204"     # 005 Decode#2（DP rank 8-15）

# ---- 高速业务网口（与 4P1D/1P1D 同一批机器）----------------------------------
NIC_NAME="${NIC_NAME:-enp23s0f3}"

# ---- 模型权重（共用同一份，只读）----------------------------------------------
MODEL_PATH="${MODEL_PATH:-/mnt/sfs_turbo/models/DeepSeek-V4.1-Flash-1017-w8a8}"
QUANTIZATION="${QUANTIZATION:-ascend}"

# ---- 镜像与容器（独立容器，可与其他包容器并存）--------------------------------
IMAGE="${IMAGE:-quay.io/ascend/vllm-ascend:v0.30.0-a3}"
CONTAINER_NAME="${CONTAINER_NAME:-deepseek-v41-3p2d}"

# ---- 部署包路径 -----------------------------------------------------------------
DEPLOY_ROOT="${DEPLOY_ROOT:-/mnt/sfs_turbo/deploy/dsv41-3p2d}"

# ---- 服务参数 -------------------------------------------------------------------
SERVED_MODEL_NAME="${SERVED_MODEL_NAME:-dsv41}"
VLLM_USE_V2_MODEL_RUNNER="${VLLM_USE_V2_MODEL_RUNNER:-1}"

# ---- 端口规划（全部避开 4P1D 的 7100/12321/30000/30100/9000 与 1P1D 的 8100 段）--
PROXY_PORT="${PROXY_PORT:-9200}"                 # PD 代理（跑在 001）
ENGINE_START_PORT="${ENGINE_START_PORT:-8200}"   # 每台本地：P 8200-8203，D 8200-8207
DP_RPC_PORT="${DP_RPC_PORT:-14321}"              # DP 协调（P 组=001、D 组=004 各自监听）
KV_PRODUCER_PORT="${KV_PRODUCER_PORT:-34000}"    # Mooncake KV 生产（P 侧全局 rank 0-11）
KV_CONSUMER_PORT="${KV_CONSUMER_PORT:-34100}"    # Mooncake KV 消费（D 侧全局 rank 0-15）

# ---- 并行布局（每台自成 DP 组，与 4P1D/1P1D 同构）-------------------------------
# ⚠️ 2026-11-18 教训：CANN MoE dispatch 算子要求 moeExpertNum(128) 能被 EP 组大小
#    （=DP×TP）整除。跨机全局 DP12×TP4=EP48 不整除 → 算子拒绝（error 561002）。
#    每台独立 DP 组（EP16，128/16=8）无此问题，且免跨机 DP 协调。
PREFILL_DP_SIZE=4           # 每台 P 独立组：DP4/TP4（EP16）
PREFILL_DP_SIZE_LOCAL=4
PREFILL_TP_SIZE=4
DECODE_DP_SIZE=8            # 每台 D 独立组：DP8/TP2（EP16）
DECODE_DP_SIZE_LOCAL=8
DECODE_TP_SIZE=2

# ---- PD 代理脚本（镜像内路径）----------------------------------------------------
PROXY_SCRIPT="${PROXY_SCRIPT:-/vllm-workspace/vllm-ascend/examples/disaggregated_prefill_v1/load_balance_proxy_server_example.py}"
