# DeepSeek-V4.1-Flash-1017 昇腾 A3 1P1D + KV Cache Pool 部署包

1 台 Prefill + 1 台 Decode，**开启分布式 KV 缓存池**（Mooncake 后端）。
基于已验证跑通的 4P1D 包（`dsv41-4p1d`）派生，仅三处变化：

1. **`kv-transfer-config` 换成 `MultiConnector`**：`MooncakeHybridConnector`（P→D 实时 KV 传输）+ `AscendStoreConnector`（前缀持久化进 Mooncake 池）——可复用前缀存池，**任何引擎都能命中 = 分布式缓存 + 缓存命中**
2. **增加 Mooncake Master**（元数据中枢，跑在 D 节点容器内）
3. **端口全部错开**（见下表），与 4P1D 可共存于同一批机器（但 NPU 互斥，见 §2）

## 1. 拓扑与端口

| 节点 | 角色 | IP | 布局 | 引擎 API | KV 端口 |
| --- | --- | --- | --- | --- | --- |
| 001 | P Prefill | 192.168.0.4 | DP4/TP4 | 8100-8103 | 32000+ |
| 005 | D Decode | 192.168.0.204 | DP8/TP2 | 8100-8107 | 32100+ |

| 用途 | 本包端口 | 4P1D 端口（不冲突） |
| --- | --- | --- |
| 引擎 API | **8100-8107** | 7100-7107 |
| DP 协调 | **13321** | 12321 |
| Mooncake KV | **32000 / 32100** | 30000 / 30100 |
| PD 代理 | **9100** | 9000 |
| Mooncake Master | **50088** | — |

容器名 `deepseek-v41-1p1d`（独立于 4P1D 的 `deepseek-v41-4p1d`）。
**防火墙两台都要放行：8100-8107、13321、32000-32099、32100-32199、9100、50088。**

## 2. 与 4P1D 的共存关系（重要）

- **文件层完全隔离**：独立目录 `/mnt/sfs_turbo/deploy/dsv41-1p1d`、独立容器、独立端口；4P1D 的包/配置/容器一个字节都不动
- **NPU 层互斥**：4P1D 已占满两台的 16 卡。启动本包前，先停这两台的 4P1D 引擎（**只停进程**）：

  ```bash
  # 001 与 005 各执行（停止 4P1D 在本机的引擎，文件不动）
  docker exec -it deepseek-v41-4p1d bash -c 'pkill -f "vllm serve"'
  # 顺带停掉 001 上的 4P1D 代理（它已无可用后端）
  pkill -f load_balance_proxy_server_example
  ```

  `npu-smi info` 确认 HBM 回落（~2.9GB/卡）后再启动本包
- **切回 4P1D**：停本包引擎/代理 → 按 `dsv41-4p1d/DEPLOY_GUIDE.md` 重新拉起（其配置原样未动）
- 002/003/004 上的 4P1D 引擎不受影响（4P1D 服务整体降级但文件完好）

## 3. 数据流（与 4P1D 的差异）

```
客户端 ──▶ 代理 :9100 ──▶ P:8100-8103（算 prefill + 产出 KV）
                             │
                             ├─▶ Mooncake 传输 ──▶ D:8100-8107（decode，流式返回）
                             └─▶ AscendStore 池化（前缀写入 Mooncake 共享池）
                                        ▲
   同前缀请求再次到达（无论代理分给哪个引擎）──命中池──┘（缓存命中）
```

- P→D 传输与 4P1D 相同（MooncakeHybridConnector）
- **新增**：可复用前缀同时写入 Mooncake 池（每节点 `24GB`，可在 config.sh 调）
- 下次同前缀请求：P 先查池 → 命中则跳过大部分 prefill → TTFT 大幅下降
- **代理无需会话粘性**：池是全引擎共享的，轮询分发也能命中（这是池化相对本地前缀缓存的核心优势）
- `use_layerwise` 必须保持 `false`（V4.1-Flash 的 CED 混合注意力不支持 layerwise）

## 4. 部署步骤

> 部署包放到 `/mnt/sfs_turbo/deploy/dsv41-1p1d/`（获取方式同 4P1D：clone 仓库后 cp，
> 或直接用本包 `update.sh` 首次拉取流程）。

```text
步骤 0  停 4P1D 引擎   001/005 按 §2 停引擎+代理，npu-smi 确认 HBM 回落
步骤 1  预检           两台宿主机各跑 00_preflight_check.sh
步骤 2  容器           两台各跑 01_start_container.sh
步骤 3  容器验证       两台容器内各跑 02_verify_container.sh（含 mooncake_master 检查）
步骤 4  Mooncake Master 005 容器内:  nohup bash kv_pool/start_mooncake_master.sh > master.log 2>&1 &
                        等日志出现初始化成功后保持运行
步骤 5  Decode         005 容器内:  nohup bash start_decode_node.sh > decode.log 2>&1 &
步骤 6  Prefill        001 容器内:  nohup bash start_prefill_node.sh > prefill.log 2>&1 &
步骤 7  等就绪         verify_service.sh wait（12 个引擎全 200）
步骤 8  代理           001 容器内:  nohup bash start_proxy.sh > proxy.log 2>&1 &（会校验 master 存活）
步骤 9  验证           verify_service.sh smoke    # 基本冒烟
                        verify_service.sh pooltest # 池化命中测试（关键！）
```

启动顺序铁律：**Master → D → P → 代理**（Master 必须最先，引擎连接器要注册到它）。

## 5. 验证池化生效（pooltest 的判读）

`verify_service.sh pooltest` 用同一段 ~1500 token 前缀连续发两次：

1. **第 2 次请求耗时应显著低于第 1 次**（TTFT 下降）
2. P 引擎 `/metrics` 里 prefix/external 命中计数在两次之间**增长**
3. P 引擎日志出现 mooncake `lookup/get/put` 记录（命令在 pooltest 输出尾部）

只看 P 本地 prefix cache 命中不能证明池化生效——本地缓存在 4P1D 也有；**池化的证据是"换一个引擎端口重发也命中"或日志里的外部池访问记录**。

## 6. 日常运维

| 操作 | 命令 |
| --- | --- |
| 状态检查 | `bash verify_service.sh` |
| 池化命中测试 | `bash verify_service.sh pooltest` |
| 停本包引擎 | 容器内 `pkill -f "vllm serve"` |
| 停 Master | `pkill -f mooncake_master`（引擎也要停，重启顺序从步骤 4 重来） |
| 服务入口 | `http://192.168.0.4:9100/v1/chat/completions`（模型名 `dsv41`） |
| 更新部署包 | `bash update.sh` |
| 切回 4P1D | 见 §2 |

## 7. 参数速查（相对 4P1D 的全部差异）

| 项 | 4P1D | 本包 |
| --- | --- | --- |
| kv_connector | MooncakeHybridConnector | **MultiConnector**（Mooncake + AscendStore(mooncake)） |
| engine_id | 无 | P="0" / D="1" |
| 池化后端 | — | mooncake（master :50088，segment 24GB/节点） |
| PYTHONHASHSEED | — | 0（两侧模板均已设） |
| 引擎/代理端口 | 7100 段 / 9000 | 8100 段 / 9100 |
| 引擎参数 | — | 与 4P1D 完全一致（W8A8、V2 runner、DSpark5、Engram 等） |

## 8. FAQ

**Q: mooncake_master 命令不存在？**
镜像不含该组件时无法开池化。确认镜像 tag；也可在不带池化的 4P1D 形态下先跑（回归 `dsv41-4p1d`）。

**Q: 引擎起来但 pooltest 第二次不提速？**
按顺序查：① master 进程活着且两台都能 telnet 50088；② 两侧引擎日志有无 mooncake 报错；③
`MOONCAKE_CONFIG_PATH` 指向的 mooncake.json 与 master 地址一致；④ 防火墙 50088。

**Q: 引擎报 kv connector 相关错误？**
两侧 `kv_connector_extra_config` 的 prefill/decode 布局必须一致（4/4 与 8/2）；`use_layerwise` 必须 false。

**Q: 想调池大小？**
`config.sh` 的 `MOONCAKE_SEGMENT_SIZE`（默认 24GB/节点）→ 重新生成配置并**整体重启**（master + 引擎）。
