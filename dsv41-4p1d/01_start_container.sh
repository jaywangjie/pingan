#!/usr/bin/env bash
# =============================================================================
# 启动 vLLM-Ascend 容器（在 5 台 A3 服务器的宿主机上各运行一次）
# 依据官方 A3 Docker 命令 + 挂载 SFS Turbo 权重目录
# 容器 P/D 通用：角色由容器内运行的启动脚本决定
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/config.sh"

echo "[INFO] 镜像：$IMAGE"
docker pull "$IMAGE"

# 已存在同名容器则先移除（重复执行本脚本安全）
if docker ps -a --format '{{.Names}}' | grep -qx "$CONTAINER_NAME"; then
    echo "[WARN] 容器 $CONTAINER_NAME 已存在，将删除重建（引擎数据不落容器内，无损失）"
    docker rm -f "$CONTAINER_NAME"
fi

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
    "$IMAGE" bash

echo
echo "[OK] 容器已启动。进入容器："
echo "     docker exec -it $CONTAINER_NAME bash"
echo "[NEXT] 容器内执行环境验证："
echo "     bash $DEPLOY_ROOT/02_verify_container.sh"
