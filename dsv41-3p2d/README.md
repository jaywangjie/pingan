# DeepSeek-V4.1-Flash-1017 昇腾 A3 3P2D 部署包

3 台 Prefill + 2 台 Decode 的 **纯 PD 分离**部署（POC 方案 §7 的 3P2D 备选形态），
从已验证的 4P1D / 1P1D 包派生。**无 KV 池化**——池化因驱动 25.2.1×CANN 配对问题
暂不可用，全程排障见 `../dsv41-1p1d/DEPLOYMENT_RECORD_1P1D.md`。

## 1. 拓扑与端口

| 节点 | 角色 | IP | 本机布局 | 全局 DP rank | 引擎 API |
| --- | --- | --- | --- | --- | --- |
| 001 | P#1（**P 组 master**） | 192.168.0.4 | DP4/TP4 | 0-3 | 8200-8203 |
| 002 | P#2 | 192.168.0.82 | DP4/TP4 | 4-7 | 8200-8203 |
| 003 | P#3 | 192.168.0.42 | DP4/TP4 | 8-11 | 8200-8203 |
| 004 | D#1（**D 组 master**） | 192.168.0.129 | DP8/TP2 | 0-7 | 8200-8207 |
| 005 | D#2 | 192.168.0.204 | DP8/TP2 | 8-15 | 8200-8207 |

- **全局布局**：Prefill **DP12/TP4**（EP48，跨 001-003）+ Decode **DP16/TP2**（EP32，跨 004-005）
- 两侧 `kv_connector_extra_config` 必须一致：`prefill{dp12,tp4} / decode{dp16,tp2}`
- 引擎共 **28 个**（P 12 + D 16）；唯一业务入口 = **001:9200** 代理

| 用途 | 本包端口 | 4P1D（不冲突） | 1P1D（不冲突） |
| --- | --- | --- | --- |
| 引擎 API | **8200-8207** | 7100 段 | 8100 段 |
| DP 协调 | **14321**（P 组=001，D 组=004） | 12321 | 13321 |
| Mooncake KV | **34000 / 34100** | 30000 / 30100 | 32000 / 32100 |
| PD 代理 | **9200**（001） | 9000 | 9100 |

容器名 `deepseek-v41-3p2d`。
**防火墙 5 台都要放行：8200-8207、14321、34000-34099、34100-34199、9200。**

## 2. 与其他包的共存关系（重要）

- **文件层完全隔离**：独立目录 `/mnt/sfs_turbo/deploy/dsv41-3p2d`、独立容器、独立端口
- **NPU 层互斥且本包吃满 5 台**：启动前需停掉**所有机器**上的 4P1D 与 1P1D 引擎（只停进程，文件不动）：

  ```bash
  # 001-003（P 节点）：停 4P1D 的 P + 1P1D 的 P/代理
  docker exec -it deepseek-v41-4p1d bash -c 'pkill -f "vllm serve"' || true
  docker exec -it deepseek-v41-1p1d bash -c 'pkill -9 -f "VLLM::Worker"; pkill -f "vllm serve"; pkill -f "load_balance_proxy"' || true
  # 004（D 节点）：停 4P1D 的 P（004 原是 4P1D 的 P 节点之一）
  docker exec -it deepseek-v41-4p1d bash -c 'pkill -f "vllm serve"' || true
  # 005（D 节点）：停 4P1D 的 D + 1P1D 的 D/master
  docker exec -it deepseek-v41-4p1d bash -c 'pkill -f "vllm serve"; pkill -f load_balance_proxy' || true
  docker exec -it deepseek-v41-1p1d bash -c 'pkill -9 -f "VLLM::Worker"; pkill -f "vllm serve"; pkill -f mooncake_master' || true
  ```

  各台 `npu-smi info` 确认 HBM 回落（~2.9GB/卡）后再启动本包
- **切回**：停本包引擎/代理 → 按对应包的 DEPLOY_GUIDE 重新拉起（配置原样未动）

## 3. 数据流

```
客户端 ──▶ 代理 001:9200 ─┬─▶ 001/002/003:8200-8203（12 个 P 引擎，算 prefill + 产出 KV）
                          │      └─ Mooncake KV（34000+ → 34100+）跨网传输
                          └─▶ 004/005:8200-8207（16 个 D 引擎，decode 流式返回）
```

- P→D KV 传输：MooncakeHybridConnector 点对点，走 enp23s0f3，与 prefill 计算重叠
- 多轮会话：P 侧本地前缀缓存（enable-prefix-caching）；跨引擎池化暂缺（见 1P1D 记录）
- **与 4P1D 的架构差异——EP 跨机**：4P1D/1P1D 的 EP 组锁在单机 16 设备内（EP16），
  本包 P 侧 EP48（跨 3 台）、D 侧 EP32（跨 2 台），MoE all-to-all 走业务网。
  Decode 每 step 都有跨机 all-to-all（004↔005），**TPOT 表现需实测验证**——
  这正是本包要回答的问题（官方 950DT 文档有 DP16 跨机宽 EP 先例）
- 代理为官方轮询示例：16→28 个后端，无会话粘性

## 4. 部署步骤

> 部署包放到 `/mnt/sfs_turbo/deploy/dsv41-3p2d/`（获取：clone/curl 仓库后 cp，
> 或首次直接 `bash update.sh`）。

```text
步骤 0  停其他包引擎   5 台按 §2 停 4P1D/1P1D，npu-smi 确认 HBM 回落
步骤 1  预检           5 台宿主机各跑 00_preflight_check.sh
步骤 2  容器           5 台各跑 01_start_container.sh
步骤 3  容器验证       5 台容器内各跑 02_verify_container.sh
步骤 4  Decode 组      004 容器内:  nohup bash start_decode_node.sh > decode.log 2>&1 &
                        （D 组 master 先起，等若干引擎开始就绪后即可起 005）
                        005 容器内:  nohup bash start_decode_node.sh > decode.log 2>&1 &
步骤 5  Prefill 组     001 容器内:  nohup bash start_prefill_node.sh > prefill.log 2>&1 &
                        002/003 同理（P 组 master 001 先起）
步骤 6  等就绪         verify_service.sh wait（28 个引擎全 200）
步骤 7  代理           001 容器内:  nohup bash start_proxy.sh > proxy.log 2>&1 &
步骤 8  验证           verify_service.sh smoke
```

启动顺序铁律：**D 组（004 先）→ P 组（001 先）→ 代理**。D 引擎 kv_consumer 起
来后 P 的 kv_producer 才能握手；DP 组内 master 节点先起（协调端口 14321 在它上面）。

## 5. 日常运维

| 操作 | 命令 |
| --- | --- |
| 状态检查 | `bash verify_service.sh` |
| 停本包引擎 | 容器内 `pkill -9 -f "VLLM::Worker"; pkill -f "vllm serve"` |
| 服务入口 | `http://192.168.0.4:9200/v1/chat/completions`（模型名 `dsv41`） |
| 更新部署包 | `bash update.sh`（注意会覆盖 config.sh） |
| 切回 4P1D/1P1D | 见 §2 |

## 6. 参数速查（相对 1P1D 的全部差异）

| 项 | 1P1D | 本包 |
| --- | --- | --- |
| 节点 | 001+005 | 001/002/003 + 004/005 |
| 全局布局 | P DP4/TP4 + D DP8/TP2 | **P DP12/TP4 + D DP16/TP2** |
| EP | 两侧各 EP16（单机） | P EP48（跨 3 台）/ D EP32（跨 2 台） |
| dp-rank-start | 固定 0 | 按节点偏移：P 0/4/8，D 0/8 |
| dp-address | 各自本机 | P 组=001，D 组=004 |
| data-parallel-size-local | 未设（默认=组大小） | 显式 P 4 / D 8（多机组必须：本地 rank=全局 rank%本机数，Engram 共享内存按本机 rank 划分） |
| 引擎/代理端口 | 8100 段 / 9100 | 8200 段 / 9200 |
| KV 池化 | ENABLE_KV_POOL 开关（当前 0） | 无（纯 PD） |
| 引擎参数 | — | 与 1P1D 稳定态完全一致（W8A8、V2 runner、DSpark5、ACL_OP_INIT_MODE=1 等） |

## 7. FAQ

**Q: 某台 P/D 起不来，报 DP 协调连接失败？**
确认组内 master（P=001，D=004）引擎先起、14321 未被占、防火墙放行；
`--data-parallel-address` 两侧必须都填 master 的 IP（不是本机 IP）。

**Q: kv 传输握手失败 / decode 收不到 KV？**
两侧 `kv_connector_extra_config` 布局必须一致（prefill dp12/tp4，decode dp16/tp2）；
KV 端口段 34000-34199 需在 5 台间放行。

**Q: 为什么没有 KV 池化？**
驱动 25.2.1 × v0.30.0-a3 CANN 配对下 Mooncake 池写必失败（-800），证据链见
`../dsv41-1p1d/DEPLOYMENT_RECORD_1P1D.md`；待驱动/镜像升级后可按 1P1D 的
ENABLE_KV_POOL 方案叠加。
