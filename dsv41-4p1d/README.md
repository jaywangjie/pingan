# DeepSeek-V4.1-Flash-1017 昇腾 A3 4P1D 部署包

依据两份资料制作：

- **平安 POC 方案 V1.4**（GitHub `jaywangjie/pingan`）：4P1D 拓扑、端口规划、参数约束
- **vLLM-Ascend 官方 A3 教程**：DP 启动器、引擎模板、容器命令、PD 代理与验证方法
  （DeepSeek-V4.1-Flash §5.2 1P1D PD Disaggregated Deployment）

## 1. 架构总览

4 台 Prefill + 1 台 Decode。**每台机器跑一个完整单机引擎，跨机只走 Mooncake
KV 点对点传输，不做跨机集合通信**（专家并行的 all-to-all 全部落在单机 HCCL 内）。
PD 代理按请求选 P 做前缀亲和，KV 经 Mooncake 送 D 对应 rank，decode 在 D 完成。

```
                        ┌─────────────────────┐
 客户端 / 压测 ────────▶ │  PD 代理  :9000      │ （辅助节点优先；POC 可放任一节点容器内）
                        └──────────┬──────────┘
             按前缀命中选 P        │        按活跃序列均衡选 D
        ┌──────────┬───────────────┼───────────────┬──────────┐
        ▼          ▼               ▼               ▼
   ┌─────────┐ ┌─────────┐   ┌─────────┐     ┌─────────┐
   │ P0·001  │ │ P1·002  │   │ P2·003  │     │ P3·004  │
   │  .4     │ │  .82    │   │  .42    │     │  .129   │
   │ DP4/TP4 │ │ DP4/TP4 │   │ DP4/TP4 │     │ DP4/TP4 │
   │ 7100-03 │ │ 7100-03 │   │ 7100-03 │     │ 7100-03 │
   └────┬────┘ └────┬────┘   └────┬────┘     └────┬────┘
        │           │             │               │
        └──────── Mooncake KV（kv_producer :30000+，逐台独立）───┘
                                 │
                                 ▼
                    ┌─────────────────────────┐
                    │ D0·005   192.168.0.204  │
                    │ DP8/TP2  API 7100-7107  │
                    │ kv_consumer :30100+     │
                    └─────────────────────────┘
```

### 节点与端口

| 节点 | 角色 | IP | 布局 | API 端口 | KV 端口 |
| --- | --- | --- | --- | --- | --- |
| 001 | P0 Prefill | 192.168.0.4 | DP4/TP4 | 7100–7103 | 30000+ |
| 002 | P1 Prefill | 192.168.0.82 | DP4/TP4 | 7100–7103 | 30000+ |
| 003 | P2 Prefill | 192.168.0.42 | DP4/TP4 | 7100–7103 | 30000+ |
| 004 | P3 Prefill | 192.168.0.129 | DP4/TP4 | 7100–7103 | 30000+ |
| 005 | D0 Decode | 192.168.0.204 | DP8/TP2 | 7100–7107 | 30100+ |

其余端口：`12321` DP 协调（每台本地）、`9000` PD 代理。
**防火墙需放行：12321、7100–7107、30000–30099、30100–30199、9000**（四台 P 复用
30000 基址不冲突，落在不同主机，代理按 IP 区分）。

### 引擎席位

- P：每台 4 个 DP rank × TP4 = 16 设备，`--max-num-seqs 16` → 全机 64 席，四台合计 256 席
- D：8 个 DP rank × TP2 = 16 设备，`--max-num-seqs 72` → 全机 576 席

## 2. 部署包内容

| 文件 | 运行位置 | 用途 |
| --- | --- | --- |
| `config.sh` | 全部节点共用 | 集群全局配置（IP/网口/权重/镜像/端口） |
| `00_preflight_check.sh` | 宿主机 | 部署前预检（NPU/内存/权重/端口/互通） |
| `01_start_container.sh` | 宿主机 | 启动容器（挂载 `/mnt/sfs_turbo`） |
| `02_verify_container.sh` | 容器内 | 容器环境验证（NPU/vLLM/权重/代理脚本） |
| `start_decode_node.sh` | D 容器内 | 启动 DP8/TP2 引擎 |
| `start_prefill_node.sh` | P 容器内 | 启动 DP4/TP4 引擎 |
| `prefill/run_dp_template.sh` | P 容器内（launcher 调用） | Prefill rank 模板 |
| `decode/run_dp_template.sh` | D 容器内（launcher 调用） | Decode rank 模板 |
| `prefill|decode/launch_online_dp.py` | 容器内 | 官方 DP 启动器 |
| `start_proxy.sh` | 辅助节点/容器内 | PD 代理（16 P 端点 + 8 D 端点） |
| `verify_service.sh` | 任意节点 | wait/engines/proxy/smoke 验证 |
| `kv_pool/` | 可选第二阶段 | Mooncake KV Cache Pool（MultiConnector） |

## 3. 部署步骤

> 部署包放在 SFS Turbo 共享存储（如 `/mnt/sfs_turbo/deploy/dsv41-4p1d/`），
> 五台机器挂载后路径天然一致。先改好 `config.sh` 再开始。

```text
步骤 0  准备     修改 config.sh（NIC_NAME / MODEL_PATH 等），五台生效同一份
步骤 1  预检     五台宿主机各跑 00_preflight_check.sh，FAIL 清零再继续
步骤 2  容器     五台宿主机各跑 01_start_container.sh
步骤 3  容器验证 五台容器内各跑 02_verify_container.sh
步骤 4  Decode   005 容器内:  bash start_decode_node.sh    （先起 D）
步骤 5  Prefill  001-004 容器内:  bash start_prefill_node.sh （D 就绪后起 4 台 P）
步骤 6  等就绪   verify_service.sh wait    （等 24 个引擎全部 ready）
步骤 7  代理     start_proxy.sh
步骤 8  验证     verify_service.sh  +  verify_service.sh smoke
```

建议每个引擎节点用独立终端/tmux 会话运行步骤 4/5：

```bash
docker exec -it deepseek-v41-4p1d bash
cd /mnt/sfs_turbo/deploy/dsv41-4p1d
nohup bash start_prefill_node.sh > prefill_$(hostname).log 2>&1 &
tail -f prefill_*.log    # 等 4 个 rank 都出现 Application startup complete
```

> 权重从 SFS Turbo 加载较慢，单个引擎就绪可能要几十分钟到数小时，
> 脚本已设置 `VLLM_ENGINE_READY_TIMEOUT_S=360000`，耐心等待，不要中途重启。

### 服务调用入口

统一走 PD 代理：`http://<代理IP>:9000/v1/chat/completions`，模型名 `dsv41`。

## 4. 关键参数说明（与两份资料的对应）

| 参数 | 取值 | 来源 |
| --- | --- | --- |
| P 侧布局 | DP4/TP4 | POC §6.2；官方 A3 W8A8 布局原文 "For W8A8 weights, use Prefill DP4/TP4 and Decode DP8/TP2" |
| D 侧布局 | DP8/TP2 | POC §6.3，同上 |
| `kv_connector_extra_config` | prefill {4,4} / decode {8,2}，两侧必须一致 | POC §6.1/6.5 |
| `max-model-len` | 两侧同为 1048576（不一致会 KV 布局错位） | POC §6.5 |
| 前缀缓存 | 只在 P 开；D 关闭并开 `recompute_scheduler_enable` | POC §6.5 |
| 图模式 | `FULL_DECODE_ONLY` 只加 D；P 保持 `--enforce-eager` | POC §6.5 |
| DSpark | 两侧 `num_speculative_tokens=5`；`enforce_eager` 只作用于 D 侧 draft | POC §6.5 |
| Engram | `{"cpu_offload":true,"dp_shared_memory":true}` 必须同时开 | POC §6.5，容器已 `--ipc=host` |
| HCCL_BUFFSIZE | P=1024 / D=4096 | 官方 A3 模板（可按实测调整） |
| P 批处理 | `max-num-batched-tokens 8192`、`max-num-seqs 16` | POC §6.2 |
| D 批处理 | `max-num-batched-tokens 512`、`max-num-seqs 72`（T5 扫 48/72/96） | POC §6.3 |

### 与两份资料的差异点（重要）

1. **Model Runner 版本**：POC 方案 V1.4 写"只支持 V1（`VLLM_USE_V2_MODEL_RUNNER=0`）"，
   但官方 A3 教程（你提供的链接）所有示例均为 **V2（=1）**。本包默认取 **1**；
   若启动时报算子/调度不兼容，把 `config.sh` 中 `VLLM_USE_V2_MODEL_RUNNER` 改 0 整集群重试。
2. **KV 连接器**：POC §6.1 的完整形态是 `MultiConnector`（Mooncake + AscendStore 池化），
   需要先起 mooncake_master。本包默认模板用基础 `MooncakeHybridConnector`（P→D 传输 +
   P 本地前缀缓存），先跑通 T0–T3；池化见 `kv_pool/README.md` 第二阶段启用。
3. **权重量化**：模板默认 `--quantization ascend`（对应 W4A8/W8A8 量化权重）。若
   `/mnt/sfs_turbo` 下是官方 MXFP 权重，需将 `config.sh` 的 `QUANTIZATION` 改为
   `deepseek_v4_fp8`（00 预检会给出提示）。

## 5. 验证

```bash
bash verify_service.sh wait     # 等 24 引擎全部 200
bash verify_service.sh          # 引擎 + 代理检查
bash verify_service.sh smoke    # 文本请求（reasoning_effort=50 示例）
bash verify_service.sh image    # 多模态请求（需 IMAGE_URL 可访问）
```

预期：代理 `/healthcheck` 返回 200；`/v1/models` 含 `dsv41`；smoke 返回
`choices[0].message.content` 为 "2"，`message.reasoning` 含推理文本。
另请抽查 P/D 引擎日志中的 KV transfer 记录（T2 闸门用例，见 POC §9.3）。

## 6. FAQ

**Q: 引擎一直不 ready？**
看该 rank 日志是否还在加载权重（SFS 慢属正常）；`npu-smi info` 确认 HBM 在涨；
确认四台 P 与 D 的 `max-model-len`、`kv_connector_extra_config` 完全一致。

**Q: 请求报 KV 缺失/失败？**
确认 D 侧模板带 `recompute_scheduler_enable:true`；确认代理注册的 P/D 端口与
实际引擎端口一致；检查 30000–30099/30100–30199 是否被防火墙拦截。

**Q: NPU 不可见 / HCCL 报错？**
容器需以 `--privileged --ipc=host --net=host` 启动（01 脚本已带）；
`HCCL_IF_IP` 与三个 `SOCKET_IFNAME` 必须指向承载 192.168.0.x 的同一网卡。

**Q: 四台 P 同时向一台 D 送 KV 是否可靠？**
这是 POC 方案明确标注"唯一没有官方示例的部分"，T2 用例专门验证（命中
0/50/80/95% × 1/30 并发）；不成立时兜底形态为两组独立 1P1D + 一台备用。

**Q: 200 并发下 TPOT 超标？**
POC §1.3/§7：单台 D 在 96–135 路内满足 30ms，200 路预计 44–63ms，
按容量报告；如 200 路 × 30ms 是硬指标，按 POC §7 切 3P2D。

**Q: import / vllm --version 报 ERR99999？**
按层定位（容器内执行）：

```bash
python3 -c "import torch_npu"                                   # 第 1 层：CANN 运行时
python3 -c "import torch, torch_npu; print(torch.npu.device_count())"  # 第 2 层：设备初始化
ls -l /dev/davinci0 /dev/davinci15 /dev/davinci_manager /dev/devmm_svm /dev/hisi_hdc  # 三类设备缺一不可
npu-smi info | head -8                                          # 驱动版本（五台必须一致）
cat /etc/ascend_install.info
```

- 第 1 层就崩 → 宿主机驱动/固件与镜像内 CANN 版本不匹配，升级驱动或换匹配镜像 tag
- device_count=0 → `env | grep ASCEND` 检查 ASCEND_RT_VISIBLE_DEVICES 是否被错误设置
- 设备文件缺失 → 容器未按 01_start_container.sh 的完整 --device 列表启动，docker inspect 核对
