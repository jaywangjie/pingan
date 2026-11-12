# KV Cache Pool（第二阶段，可选）

对应 POC 方案 §6.1 的完整形态：`MultiConnector` 组合
`MooncakeHybridConnector`（P→D 实时 KV 传输）与 `AscendStoreConnector`
（可复用前缀的持久化）。基础 4P1D（本包默认模板）只含前者 + P 侧本地
前缀缓存，已可跑通全链路；本目录用于 T2 后续的前缀池化验证。

> DeepSeek-V4.1-Flash 的 CED 混合注意力结构不支持 layerwise 池化，
> `use_layerwise` 必须保持 `false`。

## 1. 步骤

1. 修改 `mooncake.json` 的 `master_server_address` 为实际 Master 所在
   机器 IP（当前默认 `192.168.0.204:50088`，即 D 节点）。
2. 把 `mooncake.json` 拷到该机器的 `/mnt/sfs_turbo/deploy/dsv41-4p1d/kv_pool/`。
3. 在该机器容器内启动 Master：

   ```bash
   bash /mnt/sfs_turbo/deploy/dsv41-4p1d/kv_pool/start_mooncake_master.sh
   # 等待初始化成功日志后保持运行
   ```

4. 修改五台节点的引擎模板，增加两个环境变量（P/D 模板 `PYTORCH_NPU_ALLOC_CONF` 之后）：

   ```bash
   export PYTHONHASHSEED=0
   export MOONCAKE_CONFIG_PATH="/mnt/sfs_turbo/deploy/dsv41-4p1d/kv_pool/mooncake.json"
   ```

5. 替换两侧模板中的 `--kv-transfer-config`（布局值与基础版一致）。

## 2. Prefill 模板替换片段

```json
{
    "kv_connector":"MultiConnector",
    "kv_role":"kv_producer",
    "kv_port":"30000",
    "engine_id":"0",
    "kv_connector_extra_config":{
        "connectors":[
            {
                "kv_connector":"MooncakeHybridConnector",
                "kv_role":"kv_producer",
                "kv_port":"30000",
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
}
```

## 3. Decode 模板替换片段

```json
{
    "kv_connector":"MultiConnector",
    "kv_role":"kv_consumer",
    "kv_port":"30100",
    "engine_id":"1",
    "kv_connector_extra_config":{
        "connectors":[
            {
                "kv_connector":"MooncakeHybridConnector",
                "kv_role":"kv_consumer",
                "kv_port":"30100",
                "kv_connector_extra_config":{
                    "prefill":{"dp_size":4,"tp_size":4},
                    "decode":{"dp_size":8,"tp_size":2}
                }
            },
            {
                "kv_connector":"AscendStoreConnector",
                "kv_role":"kv_consumer",
                "kv_connector_extra_config":{
                    "lookup_rpc_port":"0",
                    "backend":"mooncake",
                    "use_layerwise":false
                }
            }
        ]
    }
}
```

## 4. 启动顺序与验证

启动顺序：Mooncake Master → Decode 引擎 → 4 台 Prefill 引擎 → PD 代理。

验证：用同一前缀发送两次请求，P 侧日志应出现 Mooncake `lookup/get/put` 与
命中记录，D 侧日志仍应有正常的 P→D KV 传输记录。只看 P 侧本地 prefix
caching 命中不能证明池化生效。

## 5. 端口

Master 监听 `50088`，防火墙需放行。
