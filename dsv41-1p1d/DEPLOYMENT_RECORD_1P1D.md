# 1P1D + KV Cache Pool 部署与排障全程记录

> 日期：2026-11-17（全程一天闭环）｜节点：P=001（192.168.0.4）、D=005（192.168.0.204）
> 配套阅读：`README.md`（架构与用法）、`dsv41-4p1d/DEPLOYMENT_RECORD.md`（4P1D 部署复盘）

---

## 0. 环境信息

| 项 | 值 |
| --- | --- |
| 硬件 | Atlas A3 × 2（每台 8×910C 128GB = 16 逻辑设备） |
| 驱动 | npu-smi 25.2.1（后文根因的关键变量） |
| 镜像 | `quay.io/ascend/vllm-ascend:v0.30.0-a3`（vLLM-Ascend v0.30.0） |
| 权重 | `/mnt/sfs_turbo/models/DeepSeek-V4.1-Flash-1017-w8a8`（`--quantization ascend`） |
| 布局 | P：DP4/TP4（4 引擎 16 worker）；D：DP8/TP2（8 引擎 16 worker） |
| 端口 | 引擎 8100-8107 / DP RPC 13321 / KV 32000·32100 / 代理 9100 / master 50088（metrics 9003） |
| 容器 | `deepseek-v41-1p1d`（与 4P1D 的容器/目录/端口完全隔离，NPU 互斥） |

---

## 1. 背景与目标

4P1D 集群 11-13 验收后立项第二阶段：**1P1D + 分布式 KV 缓存池**——可复用前缀写入
Mooncake 共享池，任意引擎可命中（分布式缓存/缓存命中），目标把长上下文多轮场景的
TTFT 显著拉低。约束：不破坏 4P1D 文件与环境。

## 2. 方案设计与出包（上午）

以官方教程 **§5.4 Mooncake KV Cache Pool 1P1D** 为蓝本（当时参考的英文版）：

- 连接器：`MultiConnector` = `MooncakeHybridConnector`（P→D 实时 KV 传输）
  + `AscendStoreConnector`（`backend=mooncake`，`use_layerwise=false`——V4.1-Flash
  的 CED 混合注意力不支持 layerwise）
- 池服务：`mooncake.json`（P2PHANDSHAKE / protocol ascend / master :50088 /
  每端 24GB segment / prefer_alloc_in_same_node）+ `mooncake_master`
- 两侧 `PYTHONHASHSEED=0`（池键由块哈希派生，两侧不一致则永不命中）、
  `MOONCAKE_CONFIG_PATH` 指向配置
- 启动顺序铁律：**master → D → P → 代理**

首次部署小坑：启动脚本在 `set -u` 下报 `MOONCAKE_CONFIG_PATH: unbound`——横幅引用
未定义变量，加 `:-` 默认值修复。之后全链路拉起，冒烟 200 通过。

## 3. 首跑雪崩（下午）

**现象**：64K 压测运行约 **85 分钟**后 12 个引擎连环死亡，代理随之下线。

**日志完整错误链**（本日排障的核心线索）：

```
rtsIpcMemImportByKey 返回 107000            ← 内存 IPC 导入失败（起点）
 └▶ ChannelCreate fail                      ← HixlCS（灵衢）通道创建失败
     └▶ HixlClient Connect timeout 33064ms
         └▶ HCCL EL0003
             └▶ mooncake put 返回 -800      ← 池写入失败
                 └▶ Worker 死亡 → EngineDeadError → 全集群雪崩
```

## 4. 根因排查

1. 先查官方要求的宿主机挂载 `/lib/route.conf`、`/etc/hccl_rootinfo.json`——A3 上
   不存在。复核文档确认：**这两个挂载是 950PR/DT 专属，A3 本就没有**，排除。
2. 从 vllm-ascend 仓库调出 A3 专属指南 `kv_cache_pool_ascend_store.md`，获得三个
   A3 专属变量：
   - `ACL_OP_INIT_MODE=1`
   - `ASCEND_ENABLE_USE_FABRIC_MEM=1`（要求
     `MOONCAKE_OFFLOAD_LOCAL_BUFFER_SIZE_BYTES` 按 1GB 对齐，默认 1280MB 不合规）
   - `ASCEND_GLOBAL_RESOURCE_CONFIG`（comm 走 hccs:device、store 走 roce:device）

## 5. 对照实验矩阵（下午—傍晚）

master 侧同期观察：`Clients: 32`（P 16 + D 16 worker 全部注册成功）、
`Mem Storage: 768GB`（两侧各 24GB×16）——**注册/元数据面正常，坏在数据面通道建立**。

| # | 配置 | 结果 | 结论 |
| --- | --- | --- | --- |
| A | 原始配置 | ~85 分钟后雪崩 | 基线 |
| B | +`ACL_OP_INIT_MODE=1` | **不再雪崩**；64K 回归 20/20 通过；但 put 仍 -800、Keys 恒 0 | 治"死"未治"写" |
| C | B + FABRIC_MEM 三件套 | 引擎 init 阶段 `real_client` 创建 **20 连败**，起不来（已排除 master 不通：进程活、端口可达） | **驱动 25.2.1 × CANN 配对不兼容**，此路封死 |

**决策：退池保服务**——回退纯 `MooncakeHybridConnector`（与 4P1D 已验证形态一致），
保留 `ACL_OP_INIT_MODE=1`（提交 ebea524 / f5900af）。

## 6. 降级稳定与回归验证

- 64K 回归：20/20 通过，0 失败（A 实验的雪崩已由 ACL_OP_INIT_MODE 根除）
- 本地前缀缓存：四引擎合计命中 ~46.6%，TTFT 20s → 12s
- 外部/池命中：0（池已关）；与 90% 设计值的差距归因于代理轮询分发 + 引擎冷启动，
  提出改进项：会话粘性代理

## 7. 压测（傍晚—夜）

`vllm bench serve` 阶梯复测 c4/8/16/32（160 请求 × 64K 输入 / 512 输出），结果落盘
`dsv41-64k-512-c{4,8,16,32}.json`。期间 SSH 掉线一次：确认进程存活，结果文件完整
（掉线恢复经验：看 `ps` 找 bench 进程、日志走 `/proc/<PID>/fd/1`）。

## 8. 官方新配方重试（16:00-16:30）

**转机**：官方 **zh-cn 文档 §5.4** 于 11-11 更新（比出包时参考的英文版新一版），
多出三个未试变量：

1. **D 侧纯消费者**：独立 `mooncake_d.json`（segment/buffer 均 0）——官方明示
   *D 侧预留池 DRAM 可能因 rtsHostRegister 失败*
2. **P 侧显式 `local_buffer_size: 1GB`**（此前走默认 1280MB）
3. **master `--client_ttl=120`**（防编译慢的 worker 启动期被踢）

据此出重试包（提交 a9963ac）：双配置自动生成、master 新参数、池化收敛为
`config.sh` 的 **`ENABLE_KV_POOL` 开关**（1=池化 / 0=一键回退稳定形态），SSD 卸载层
暂不开（最小化变量）。本地完成 6 脚本 `bash -n` + 4 种开关组合 JSON 校验后推送。

**上机**（16:07 master 生成双配置 → 16:09 `service_ready=true` → D 8 引擎 →
P 4 引擎 → 代理，全部就绪），**16:21 验证——重试失败**：

- smoke 200 ✅；pooltest 两次 200（1.55s / 1.57s，无提速）❌
- `error_codes=[-800]` 原样复现，错误链与 A/B 完全一致；且 remote_engine 全是
  **192.168.0.4（P 节点自身）**——机内自连的 HixlCS 通道都建不起来，
  证明与 D 侧贡献内存无关
- 引擎全程稳定（ACL_OP_INIT_MODE 兜底有效）、本地缓存 24.9%、External hit 0%

```
Call ExchangeEndpointAndCreateChannel(timeout_ms) fail. [HixlClient] ...
Call new_client->Connect(timeout_in_millis) fail. Failed to connect client,
  remote_engine:192.168.0.4:20167, timeout:33064 ms
(Worker_DP0_TP0_EP0) ERROR [mooncake_backend.py:448] Failed to put 1 keys out
  of 1. error_codes=[-800]. Check memory and store capacity.
```

## 9. 最终结论

| 维度 | 结论 |
| --- | --- |
| 池化目标 | ❌ 未达成。官方文档配置组合**穷尽**（A/B/C/D 四行矩阵），与配置无关 |
| 根因定性 | **驱动 25.2.1 × v0.30.0-a3 镜像 CANN 配对下，HixlCS P2P 通道创建缺陷**：不加 FABRIC_MEM → put -800；加 FABRIC_MEM → real_client 创建失败。待驱动/镜像升级后翻案 |
| 服务本身 | ✅ 1P1D 稳定可用（不雪崩 + 本地前缀缓存生效），当前按需切 `ENABLE_KV_POOL` |
| 证据链 | 四组对照 + 两条错误链 + master 注册面正常/数据面失败 —— 报障材料现成 |

## 10. 运维坑清单（当日新增）

| 坑 | 现象 | 解法 |
| --- | --- | --- |
| `pkill -f` 自匹配 | `bash -c 'pkill A; pkill B; ...'` 的包装 shell 命令行含关键字，第一条 `pkill -9` 把自己杀掉，后面的没执行（代理/旧 master 残活） | 方括号技巧 `pkill -f "[V]LLM::Worker"`，或 `docker exec <c> pkill -f xxx` 直连不经包装 |
| worker 改名 | `pkill -f "vllm serve"` 杀不到 worker（proctitle 已改为 `VLLM::Worker`） | `pkill -9 -f "VLLM::Worker"` |
| git 慢 | GitHub HTTP/2 链路不稳 | codeload tarball 直下：`curl -L https://codeload.github.com/jaywangjie/pingan/tar.gz/refs/heads/main` |
| master 端口占用 | 重启报 9003 Address already in use | 先 `pkill -f mooncake_master` |
| 代理端口占用 | 9100 bind 冲突 | 先 pkill 旧代理 |
| SFS .nfs 幽灵 | rm 报错、update.sh 自删 | 永远 merge-copy（`cp -r src/. dst/`），引擎运行中不 rm |
| grep 模式想当然 | 找 `-800` 用了 `retcode=-800`，实际文本是 `error_codes=[-800]` | 先看原文再定 pattern |

## 11. 当前状态与操作指引

- **回退纯 PD（稳定形态）**：两台停净进程 → 001 执行
  `sed -i 's/^ENABLE_KV_POOL=1/ENABLE_KV_POOL=0/' config.sh` → D → P → 代理（无需 master）
- **驱动/镜像升级后再试**：改回 `ENABLE_KV_POOL=1`，从 master 起整体重启；
  验收三判据：master `Keys > 0`、`grep -c 'error_codes=\[-800\]' prefill.log` 为 0、
  pooltest 第二次提速且 external 命中增长
- **备选路线**：A3 官方认证的池化后端是 **Memcache**（教程 §5.3.2，device_sdma，
  需 `memcache_hybrid` 包 + 灵衢计算网络 ≥1.5），可探测可行性
- **报障**：凭 §9 证据链向 vllm-ascend / 华为提 issue

## 12. 提交记录

| 提交 | 内容 |
| --- | --- |
| cd4a6b7 | mooncake.json 默认值 / 池化初始包 |
| 651b560 | A3 专属环境变量（ACL_OP_INIT_MODE 等） |
| ebea524 | 稳定化：暂关池化，回退纯 MooncakeHybridConnector |
| f5900af | DEPLOY_DIR `/..` 修复 |
| a9963ac | 官方 11-11 新配方重试包：双配置 + client_ttl + ENABLE_KV_POOL 开关 |

## 参考

- 官方教程（zh-cn，11-11 更新）：DeepSeek-V4.1-Flash §5.4 Mooncake KV Cache Pool 1P1D
- vllm-ascend 仓库：`docs/feature_guide/kv_cache_pool_ascend_store.md`（A3 专属变量）
- 4P1D 全程：`../dsv41-4p1d/DEPLOYMENT_RECORD.md`
