# DeepSeek-V4.1-Flash-1017 昇腾 A3 4P1D 部署记录

- **日期**：2026-11-12 ~ 2026-11-13
- **结果**：✅ 部署成功，24/24 引擎就绪，PD 代理与全链路冒烟通过
- **服务入口**：`http://192.168.0.4:9000/v1/chat/completions`（模型名 `dsv41`）

---

## 1. 集群与部署结果总览

| 节点 | 角色 | IP | 布局 | 引擎数 | API 端口 | 状态 |
| --- | --- | --- | --- | --- | --- | --- |
| 001 | P0 Prefill | 192.168.0.4 | DP4/TP4 | 4 | 7100-7103 | ✅（兼跑 PD 代理 :9000） |
| 002 | P1 Prefill | 192.168.0.82 | DP4/TP4 | 4 | 7100-7103 | ✅ |
| 003 | P2 Prefill | 192.168.0.42 | DP4/TP4 | 4 | 7100-7103 | ✅（经历一次清场重启） |
| 004 | P3 Prefill | 192.168.0.129 | DP4/TP4 | 4 | 7100-7103 | ✅ |
| 005 | D0 Decode | 192.168.0.204 | DP8/TP2 | 8 | 7100-7107 | ✅ |

- 跨机只走 Mooncake KV 点对点传输（P 侧 kv_producer :30000+ → D 侧 kv_consumer :30100+），无跨机集合通信
- PD 代理跑在 001 容器内，注册 16 个 P 端点 + 8 个 D 端点

## 2. 软硬件清单

| 项目 | 取值 |
| --- | --- |
| 服务器 | 5 × Atlas A3（8 × 910C 128GB = 16 个 64GB 逻辑设备/台，单机 1TB HBM） |
| NPU 驱动 | npu-smi 25.2.1 |
| 镜像 | `quay.io/ascend/vllm-ascend:v0.30.0-a3`（五台同 tag） |
| vLLM / vLLM-Ascend | v0.30.0 |
| 权重 | `/mnt/sfs_turbo/models/DeepSeek-V4.1-Flash-1017-w8a8`（ModelScope 预转换 W8A8，**无需再量化**，`--quantization ascend`） |
| 共享存储 | SFS Turbo，挂载 `/mnt/sfs_turbo`，五台同路径（部署包 `/mnt/sfs_turbo/deploy/dsv41-4p1d`） |
| 业务网卡 | `enp23s0f3`（五台一致，HCCL/GLOO/TP 全走此口） |
| 关键参数 | `VLLM_USE_V2_MODEL_RUNNER=1`；`max-model-len 1048576`；DSpark `num_speculative_tokens=5`；Engram `cpu_offload+dp_shared_memory`；connector `prefill{dp:4,tp:4}/decode{dp:8,tp:2}` |

## 3. 实际部署步骤回顾

1. **方案准备**（11-12）：从 GitHub `jaywangjie/pingan` 获取 POC 方案 V1.4（4P1D：P DP4/TP4 ×4 + D DP8/TP2 ×1），对照 vLLM-Ascend 官方 A3 教程（W8A8 布局与方案一致）制作部署包 `dsv41-4p1d` 并推送 GitHub
2. **配置确认**：网卡 `enp23s0f3`、权重路径（`/models/` 子目录）、W8A8 量化形态写入 `config.sh`
3. **镜像**：五台 `docker pull quay.io/ascend/vllm-ascend:v0.30.0-a3`
4. **容器**：五台跑 `01_start_container.sh`（--net=host --ipc=host --privileged，16 设备 + 驱动挂载 + `/mnt/sfs_turbo`）
5. **容器验证**：`02_verify_container.sh`（经历两轮脚本修复后全 PASS，见 §4 P1/P2）
6. **启动 Decode（005）**：`nohup bash start_decode_node.sh > decode.log 2>&1 &`，权重加载 142 分片约 10 分钟，图捕获数分钟，8 × `Application startup complete`，7100-7107 全 200
7. **启动 Prefill（001-004）**：`nohup bash start_prefill_node.sh > prefill.log 2>&1 &`，四台并行加载约 12-15 分钟（共享 SFS 带宽），各 4 × startup complete；003 因进程混杂清场重启一次（§4 P7）
8. **启动 PD 代理（001 容器内）**：`nohup bash start_proxy.sh > proxy.log 2>&1 &`，日志确认 `Initialized 16 prefill clients and 8 decode clients`，监听 `0.0.0.0:9000`
9. **验证**：`verify_service.sh` 全 24 引擎 [OK] + 代理 healthcheck 200；`smoke` 冒烟通过

## 4. 问题与解决记录（按时间序）

### P1. 验证脚本误报：head 函数遮蔽系统命令 + 容器缺 ip/ping
- **现象**（11-13 02:14）：`02_verify_container.sh` 7 个 FAIL：vllm 输出被吞、节点互通全挂
- **根因**：脚本自定义日志函数 `head()` 遮蔽了 `head` 命令（管道输出全被吞）；容器镜像无 `ip`/`ping` 命令
- **解决**：函数改名 `section()`；本机识别改 `hostname -I` 兜底；连通性改 bash 内建 `/dev/tcp` 探测 22 端口

### P2. "vllm_ascend 导入失败 ERR99999"——虚惊一场
- **现象**（02:14/02:41）：`import vllm_ascend` 报 `ERR99999 UNKNOWN application exception`
- **根因**：模块没有 `__version__` 属性 → `AttributeError` → 进程异常退出；**ERR99999 是 CANN 在 Python 异常退出时的清理噪音，出现在真实报错之后，不是故障本身**。torch_npu/设备初始化/vllm 全部正常
- **解决**：版本改用 `importlib.metadata` 读取；教训——**看到 ERR99999 往上找 Python Traceback**

### P3. 启动脚本静默 Exit 127
- **现象**（005，03:41）：`nohup bash start_decode_node.sh` 立即退出，日志仅一行 `nohup: ignoring input`
- **根因**：容器无 `ip` 命令（退出码 127）→ `set -o pipefail` 把 127 传给整条管道 → `set -e` 对赋值语句非零状态**静默退出**，退出码恰为 127
- **解决**：IP 探测所有分支加 `|| true` 兜底；用 `bash -x` 定位到死在 LOCAL_IPS 赋值行

### P4. 多命令长行粘贴断行 → 部署包被删（发生两次）
- **现象**：`rm -rf dsv41-4p1d` 与后续参数拼成一行丢失 `&&`，`rm` 把 `git`/`clone`/URL 全当参数吃掉，目录被删且未恢复
- **解决**：关键操作改为单条执行；形成规矩——**长命令要么确认一行，要么拆开跑**

### P5. `--no-swa-bounded-replay` 参数 v0.30.0 不识别
- **现象**（03:59）：8 个 rank 全部 exit 2，手动跑模板现形 `vllm: error: unrecognized arguments: --no-swa-bounded-replay`
- **根因**：官方文档跟 main 分支，v0.30.0 镜像尚无该参数（argparse 报错退出码即 2）；D 侧默认本就不开
- **解决**：从 decode 模板删除该参数（argparse 一次性报全，其余参数均通过）

### P6. SFS `.nfs` 幽灵文件：update.sh 自删 + 删除失败
- **现象**：`rm: cannot remove ... Directory not empty` / `Device or resource busy`（`.nfsXXXX` 文件）；在部署目录内运行 update.sh 会自删脚本
- **根因**：SFS/NFS 对进程占用文件做 silly-rename；**运行中引擎的 cwd 和日志在部署目录内**，rm 永远删不净
- **解决**：update.sh 先 `cd /`；最终定型为**只覆盖合并（`cp -r 源/. 目标/`）、绝不删除目标目录** + `--depth 1` 浅克隆加速

### P7. 003 P 节点"startup complete 但端口不监听"
- **现象**（07:34）：日志 4 × `Application startup complete`（PID 718-721），但 7100-7103 连接拒绝；`ps` 里存活的却是 PID 436-439
- **根因**：当天多轮启动尝试残留——**打印 complete 的那批进程已死，活着的这批没走到启动完成**，新旧进程混杂
- **解决**：`pkill -f "vllm serve"` 清场（确认 `ps` 归零、HBM 释放）后单次干净重启，4 × complete + 端口 200
- **旁证**：001/002/004 同配置全部正常（外部探测 7100 OPEN），排除版本/配置通病

### P8. verify_service.sh `--noproxy *` 被 glob 展开
- **现象**（08:13 后）：验证输出大量 `Could not resolve host: 01_start_container.sh`、nginx 301
- **根因**：`CURL="curl -sS --noproxy *"` 变量展开时 `*` 被 glob 成当前目录文件名，curl 拿文件名当 URL（`decode`/`prefill` 恰被内网 DNS 解析到 nginx → 301）
- **解决**：改用函数封装 `curlx() { curl -sS --noproxy '*' "$@"; }`；引擎与代理全程健康

## 5. 日常运维命令速查

```bash
# 启动（顺序：先 D 后 P，代理最后；均在各节点容器内 docker exec -it deepseek-v41-4p1d bash）
cd /mnt/sfs_turbo/deploy/dsv41-4p1d
nohup bash start_decode_node.sh  > decode.log  2>&1 &    # 005
nohup bash start_prefill_node.sh > prefill.log 2>&1 &    # 001-004
nohup bash start_proxy.sh        > proxy.log   2>&1 &    # 001（等 24 引擎全 200 后）

# 停止（对应节点容器内）
pkill -f "vllm serve"; sleep 5; pkill -9 -f "vllm serve" 2>/dev/null

# 状态检查（任意节点）
bash verify_service.sh            # 24 引擎 + 代理总检
bash verify_service.sh smoke      # 冒烟对话
for p in $(seq 7100 7107); do printf "%s -> %s\n" $p $(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' http://127.0.0.1:$p/health); done

# 就绪进度
grep -c "Application startup complete" decode.log   # D: 涨到 8
grep -c "Application startup complete" prefill.log  # P: 每台涨到 4

# 更新部署包（任意节点、引擎运行时也安全：只覆盖合并不删除）
bash /mnt/sfs_turbo/deploy/dsv41-4p1d/update.sh

# 单发请求
curl http://192.168.0.4:9000/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"model":"dsv41","messages":[{"role":"user","content":"你好"}],"temperature":0,"max_tokens":512}'
```

## 6. 经验教训

1. **ERR99999 是"果"不是"因"**——只出现在 Python 异常退出之后，排查时找它上面的 Traceback
2. **引擎运行时不 rm -rf 部署目录**——SFS 会留 `.nfs` 幽灵文件，更新只做覆盖合并
3. **`set -e` + `pipefail` 会静默退出**——管道里任何命令"不存在"(127) 都可能杀死整个脚本且零输出；兜底分支要 `|| true`
4. **文档跟随 main 分支，镜像按发布版**——参数以镜像实际校验为准（本次 `--no-swa-bounded-replay` 即例证）；argparse 退出码 2 = 参数不识别，且一次报全
5. **shell 函数别用系统命令名**（`head`/`cd` 等），会遮蔽管道中的同名命令
6. **多轮失败尝试后重启前先清场**——`ps` 归零 + HBM 释放再启动，避免新旧进程混杂（003 的教训）
7. **SFS 加载预期**：单台独占约 10 分钟/142 分片，五台并行约 12-15 分钟；图捕获再需数分钟（D 侧），`VLLM_ENGINE_READY_TIMEOUT_S=360000` 已留足
8. **bash 内建 `/dev/tcp` 探测端口**不依赖 ss/nc/ping，容器里最通用

## 7. 后续待办

- [ ] T0-T7 测试方案执行（POC §9.3；T2"四 P 对一 D 链路"为闸门用例）
- [ ] 200 并发下 TPOT 按容量口径报告（预期 44-63ms；96-135 路内可达 30ms，硬指标则切 3P2D，POC §7）
- [ ] KV Cache Pool 二阶段（`kv_pool/`，MultiConnector + mooncake_master）
- [ ] 五台镜像 digest 与驱动版本一致性归档（POC §4.4 版本冻结）
- [ ] 引擎重启后注意：旧 nohup 日志已成 `.nfs` 幽灵，新日志正常生成于部署目录
