# DeepSeek-V4.1-Flash-1017 昇腾 A3 4P1D 部署指导（新人从 0 到 1）

> 本文档面向第一次执行部署的同事，照着做即可从零拉起整套服务。
> 历史部署过程与踩坑复盘见同目录 `DEPLOYMENT_RECORD.md`，参数原理见 `README.md`。

---

## 0. 你要部署什么

5 台昇腾 A3 服务器组成一套 PD 分离推理服务：

```
                        ┌─────────────────────┐
 客户端 / 压测 ────────▶ │  PD 代理  :9000      │ （跑在 001 容器内）
                        └──────────┬──────────┘
        ┌──────────┬───────────────┼───────────────┬──────────┐
        ▼          ▼               ▼               ▼
   ┌─────────┐ ┌─────────┐   ┌─────────┐     ┌─────────┐
   │ 001  P  │ │ 002  P  │   │ 003  P  │     │ 004  P  │   Prefill ×4
   │ DP4/TP4 │ │ DP4/TP4 │   │ DP4/TP4 │     │ DP4/TP4 │   每台 4 引擎
   │ 7100-03 │ │ 7100-03 │   │ 7100-03 │     │ 7100-03 │
   └────┬────┘ └────┬────┘   └────┬────┘     └────┬────┘
        └────────── Mooncake KV 传输（跨机只有 KV）───┘
                                 ▼
                    ┌─────────────────────────┐
                    │ 005  D   Decode         │
                    │ DP8/TP2  8 引擎 7100-07 │
                    └─────────────────────────┘
```

| 节点编号 | IP | 角色 | 引擎数（API 端口） |
| --- | --- | --- | --- |
| 001 | 192.168.0.4 | Prefill + PD 代理 | 4（7100-7103）+ 代理 9000 |
| 002 | 192.168.0.82 | Prefill | 4（7100-7103） |
| 003 | 192.168.0.42 | Prefill | 4（7100-7103） |
| 004 | 192.168.0.129 | Prefill | 4（7100-7103） |
| 005 | 192.168.0.204 | Decode | 8（7100-7107） |

全部成功后的服务入口：**`http://192.168.0.4:9000/v1/chat/completions`**，模型名 `dsv41`。

**部署顺序铁律：先 005（D）→ 再 001-004（P）→ 最后代理。** 全程预计 1.5~2 小时（主要是权重加载）。

---

## 1. 开始前的检查清单

逐项确认，缺一不可：

| # | 检查项 | 怎么确认 | 备注 |
| --- | --- | --- | --- |
| 1 | 5 台机器互相 ping 通 | 每台 `ping` 其余 4 台 IP | |
| 2 | 每台 16 个 NPU 逻辑设备 | 宿主机 `ls /dev/davinci* \| wc -l` = 16 | |
| 3 | 权重在共享存储 | `ls /mnt/sfs_turbo/models/DeepSeek-V4.1-Flash-1017-w8a8/config.json` | 五台同路径 |
| 4 | 五台业务网卡同名 | 每台 `ip -4 -o addr` 看 192.168.0.x 挂在哪块网卡 | 当前为 `enp23s0f3` |
| 5 | 防火墙放行 | 12321、7100-7107、30000-30099、30100-30199、9000 | 五台都要 |
| 6 | 宿主机内存 ≥1.5TB | `free -g` | Engram 驻留约 196GB |

**一次性配置**（每台宿主机执行，解决 GitHub 访问不稳）：

```bash
git config --global http.version HTTP/1.1
```

---

## 2. 获取部署包（五台任一台，做一次）

部署包在 GitHub 仓库 `jaywangjie/pingan` 的 `dsv41-4p1d/` 目录。SFS 共享存储五台可见，拷一次即可：

```bash
cd /tmp
```

```bash
git clone -q --depth 1 https://github.com/jaywangjie/pingan.git /tmp/pa
```

```bash
cp -r /tmp/pa/dsv41-4p1d/. /mnt/sfs_turbo/deploy/dsv41-4p1d/
```

```bash
rm -rf /tmp/pa && ls /mnt/sfs_turbo/deploy/dsv41-4p1d/
```

> ⚠️ 注意 `cp` 命令源路径结尾的 `/.`（覆盖合并）。**永远不要 rm -rf 部署目录**——引擎运行时它的日志和工作目录在里面，SFS 会产生 `.nfs` 幽灵文件导致删除失败并破坏现场。

确认 `config.sh` 关键配置（当前集群已配好，换环境才需要改）：

```bash
grep -E "NIC_NAME=|MODEL_PATH=" /mnt/sfs_turbo/deploy/dsv41-4p1d/config.sh
# NIC_NAME="${NIC_NAME:-enp23s0f3}"
# MODEL_PATH="${MODEL_PATH:-/mnt/sfs_turbo/models/DeepSeek-V4.1-Flash-1017-w8a8}"
```

---

## 3. 预检（五台宿主机各跑一次）

```bash
bash /mnt/sfs_turbo/deploy/dsv41-4p1d/00_preflight_check.sh
```

**通过标准：FAIL=0**。WARN 项人工确认（如镜像未拉取、防火墙提示）。有 FAIL 先解决再继续。

---

## 4. 拉镜像（五台宿主机，可与预检并行）

```bash
docker pull quay.io/ascend/vllm-ascend:v0.30.0-a3
```

五台核对同一 digest（版本冻结要求）：

```bash
docker inspect --format='{{index .RepoDigests 0}}' quay.io/ascend/vllm-ascend:v0.30.0-a3
```

---

## 5. 启动容器（五台宿主机各一次）

```bash
bash /mnt/sfs_turbo/deploy/dsv41-4p1d/01_start_container.sh
```

进入容器并验证环境（**后续所有启动命令都在容器内执行**）：

```bash
docker exec -it deepseek-v41-4p1d bash
bash /mnt/sfs_turbo/deploy/dsv41-4p1d/02_verify_container.sh
```

**通过标准：全 PASS**（16 NPU 可见、torch_npu/vllm/vllm_ascend 导入正常、权重可见、节点互通）。

> 💡 容器里可能没有 `ip`、`ping`、`ss` 这些命令，验证脚本已做兼容；自己排查时可用 `python3` 的 socket 或读 `/proc/net/tcp` 代替。

---

## 6. 启动 Decode 节点（005 容器内）

```bash
docker exec -it deepseek-v41-4p1d bash
cd /mnt/sfs_turbo/deploy/dsv41-4p1d
nohup bash start_decode_node.sh > decode.log 2>&1 &
```

**1 分钟后确认进程**（必须是 8）：

```bash
ps -ef | grep -c "[v]llm serve"
```

**等待就绪**（权重加载约 10 分钟 + 图捕获数分钟，合计 15~25 分钟）：

```bash
grep -c "Application startup complete" decode.log        # 涨到 8
for p in $(seq 7100 7107); do printf "%s -> %s\n" $p $(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' http://127.0.0.1:$p/health); done
# 8 行全部 200 才算就绪
```

> 💡 进度条 100% 后日志会"安静"几分钟——那是 D 侧在做 ACL Graph 捕获，**不是卡死，不要重启**。不放心开另一终端看 `npu-smi info`，HBM 约 60GB/卡且 AICore 有活动即正常。

---

## 7. 启动 4 台 Prefill（001-004 每台容器内，同样命令）

```bash
docker exec -it deepseek-v41-4p1d bash
cd /mnt/sfs_turbo/deploy/dsv41-4p1d
nohup bash start_prefill_node.sh > prefill.log 2>&1 &
```

**1 分钟后确认进程**（必须是 4）：

```bash
ps -ef | grep -c "[v]llm serve"
```

**等待就绪**（四台并行读 SFS，比 D 稍慢，12~20 分钟；P 侧无图捕获，权重加载完很快 ready）：

```bash
grep -c "Application startup complete" prefill.log        # 涨到 4
for p in 7100 7101 7102 7103; do printf "%s -> %s\n" $p $(curl -s -o /dev/null -w '%{http_code}' --noproxy '*' http://127.0.0.1:$p/health); done
# 4 行全部 200
```

四台全部达标后进入下一步。

---

## 8. 启动 PD 代理（001 容器内）

```bash
cd /mnt/sfs_turbo/deploy/dsv41-4p1d
nohup bash start_proxy.sh > proxy.log 2>&1 &
sleep 5 && tail -5 proxy.log
```

**成功标志**：日志出现

```
Initialized 16 prefill clients and 8 decode clients ...
Uvicorn running on http://0.0.0.0:9000
```

代理启动时会自动检查 24 个后端引擎健康状态，有未就绪的会拒绝启动——**先回去把引擎补齐**。

---

## 9. 全链路验证（001 容器内）

```bash
bash verify_service.sh            # 24 个引擎全 [OK] + 代理 healthcheck 200 + 模型列表含 dsv41
bash verify_service.sh smoke      # 冒烟对话
```

**smoke 成功标志**：`HTTP 200`，`content` 为 "2"，`reasoning` 含思考过程。

或手工发一条：

```bash
curl http://192.168.0.4:9000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"dsv41","messages":[{"role":"user","content":"你好"}],"temperature":0,"max_tokens":512}'
```

**到这里部署完成。** 🎉

---

## 10. 日常运维速查

| 操作 | 命令（位置） |
| --- | --- |
| 看引擎状态 | `bash verify_service.sh`（任意节点容器内） |
| 停某节点引擎 | 容器内 `pkill -f "vllm serve"; sleep 5; pkill -9 -f "vllm serve" 2>/dev/null` |
| 重启某节点 | 停 → 确认 `ps` 归零 + `npu-smi info` HBM 回落到 ~2.9GB/卡 → 按第 6/7 节启动 |
| 更新部署包 | `bash /mnt/sfs_turbo/deploy/dsv41-4p1d/update.sh`（任意节点、引擎运行时也安全） |
| 看 D 日志 | 005 容器 `tail -f /mnt/sfs_turbo/deploy/dsv41-4p1d/decode.log` |
| 看 P 日志 | 对应节点容器 `tail -f .../prefill.log` |

**重启顺序**：先 D 后 P 最后代理（代理最后起，它要求后端全绿）。

---

## 11. 新人最容易踩的坑（真实发生过，务必读）

1. **多命令长行粘贴断行**——`rm -rf xxx git clone ...` 丢了 `&&` 会把后面的词全当 rm 参数。**长命令要么确认一行，要么拆成单条跑**
2. **引擎运行时 rm -rf 部署目录**——SFS 留 `.nfs` 幽灵文件删不掉，还破坏运行现场。更新永远用 `update.sh`（覆盖合并）
3. **加载慢就重启**——SFS 加载 10-20 分钟正常，图捕获阶段日志安静也正常。判断标准是"进程在 + HBM 在涨"，不是"日志在滚"
4. **多次启动尝试不清场**——失败的引擎可能残留进程占着设备。重启前必须 `pkill` + 确认 `ps` 归零 + HBM 释放
5. **看到 ERR99999 就慌**——它是 Python 异常退出时 CANN 的清理噪音，**真错误在它上面的 Traceback**，别盯着它查
6. **直接 curl 引擎端口（7100-7107）**——P/D 引擎只有半段能力，业务请求必须走代理 9000

## 12. 出问题怎么排查（三层法）

```bash
# 第一层：进程活着吗
ps -ef | grep -c "[v]llm serve"                # D=8 / P=4

# 第二层：端口监听了吗
python3 -c "import socket;[print(p, (lambda s:(s.settimeout(2), s.connect_ex(('127.0.0.1',p)), s.close())[1])(socket.socket())) for p in [7100,7101,7102,7103]]"
# 返回码 0 = 通

# 第三层：日志里找 Traceback（不是 ERR99999）
grep -n -B5 -A20 "Traceback" decode.log | tail -60
```

单 rank 手动复现错误（拿真实报错的最快方式，D 为例）：

```bash
cd /mnt/sfs_turbo/deploy/dsv41-4p1d/decode
bash run_dp_template.sh 0,1 7100 8 0 192.168.0.204 12321 2 2>&1 | tail -25
```

排查不动时，把 `tail -50 对应日志` 发到群里。
