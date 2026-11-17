#!/usr/bin/env bash
# =============================================================================
# 启动 vLLM-Ascend 容器（在 P/D 两台 A3 宿主机各运行一次）
# 独立容器 deepseek-v41-1p1d，与 4P1D 的 deepseek-v41-4p1d 互不影响
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/config.sh"

echo "[INFO] 镜像：$IMAGE"
docker pull "$IMAGE"

if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "[WARN] 容器 $CONTAINER_NAME 已存在，将删除重建"
    docker rm -f "$CONTAINER_NAME"
fi

# ---- 池化传输必需的宿主机文件（官方 pooling 要求挂载，缺失则 HCCS P2P 通道建立失败）----
EXTRA_MOUNTS=()
for f in /lib/route.conf /etc/hccl_rootinfo.json; do
    if [ -f "$f" ]; then
        EXTRA_MOUNTS+=(-v "$f:$f:ro")
        echo "[INFO] 池化挂载：$f"
    else
        echo "[WARN] $f 在宿主机不存在——若启用 KV Pool，P2P 通道可能建立失败（HixlCSClientConnect timeout）" >&2
    fi
done

echo "[INFO] 启动容器（--net=host --ipc=host，挂载 /mnt/sfs_turbo）..."
docker run -itd \
    --name "$CONTAINER_NAME" \
    --net=host \
    --ipc=host \
    --privileged=true \
    --device /dev/davinci0 \
    --device /dev/davinci1 \
    --device /dev/davinci2 \
    --device /dev/davinci3 \
    --device /dev/davinci4 \
    --device /dev/davinci5 \
    --device /dev/davinci6 \
    --device /dev/davinci7 \
    --device /dev/davinci8 \
    --device /dev/davinci9 \
    --device /dev/davinci10 \
    --device /dev/davinci11 \
    --device /dev/davinci12 \
    --device /dev/davinci13 \
    --device /dev/davinci14 \
    --device /dev/davinci15 \
    --device /dev/davinci_manager \
    --device /dev/devmm_svm \
    --device /dev/hisi_hdc \
    -v /usr/local/dcmi:/usr/local/dcmi \
    -v /usr/local/Ascend/driver/tools/hccn_tool:/usr/local/Ascend/driver/tools/hccn_tool \
    -v /usr/local/bin/npu-smi:/usr/local/bin/npu-smi \
    -v /usr/local/Ascend/driver/lib64/:/usr/local/Ascend/driver/lib64/ \
    -v /usr/local/Ascend/driver/version.info:/usr/local/Ascend/driver/version.info \
    -v /etc/ascend_install.info:/etc/ascend_install.info \
    -v /etc/hccn.conf:/etc/hccn.conf \
    -v /mnt/sfs_turbo:/mnt/sfs_turbo \
    "${EXTRA_MOUNTS[@]}" \
    "$IMAGE" bash

echo
echo "[OK] 容器已启动。进入容器："
echo "     docker exec -it $CONTAINER_NAME bash"
echo "[NEXT] 容器内执行环境验证："
echo "     bash $DEPLOY_ROOT/02_verify_container.sh"
