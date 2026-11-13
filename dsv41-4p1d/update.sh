#!/usr/bin/env bash
# =============================================================================
# 部署包更新（五台任一台执行一次即可，SFS Turbo 共享存储五台同步可见）
# 作用：从 GitHub 拉取最新 dsv41-4p1d 部署包，替换 /mnt/sfs_turbo/deploy 副本
# 前提：git 已强制 HTTP/1.1（一次性配置）：
#       git config --global http.version HTTP/1.1
# 用法：可在任何目录运行（包括部署包目录内部，脚本会自动切出）
# =============================================================================
set -euo pipefail

DEPLOY_PARENT="/mnt/sfs_turbo/deploy"
REPO="https://github.com/jaywangjie/pingan.git"

# 先切出目标目录，避免删除自身所在目录 / 自身 cwd
cd /

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "[INFO] 从 GitHub 拉取最新部署包 ..."
git clone -q "$REPO" "$TMP/pa"
COMMIT=$(git -C "$TMP/pa" rev-parse --short HEAD)

mkdir -p "$DEPLOY_PARENT"
# SFS 删除有延迟，rmdir 可能报 Directory not empty：重试两次，仍残留则容忍
rm -rf "$DEPLOY_PARENT/dsv41-4p1d" 2>/dev/null || true
sleep 1
rm -rf "$DEPLOY_PARENT/dsv41-4p1d" 2>/dev/null || true

# 直接落新副本（若旧目录因 SFS 延迟仍残留，cp 会覆盖合并，无碍）
cp -r "$TMP/pa/dsv41-4p1d" "$DEPLOY_PARENT/"
chmod +x "$DEPLOY_PARENT"/dsv41-4p1d/*.sh \
         "$DEPLOY_PARENT"/dsv41-4p1d/prefill/*.sh \
         "$DEPLOY_PARENT"/dsv41-4p1d/decode/*.sh \
         "$DEPLOY_PARENT"/dsv41-4p1d/kv_pool/*.sh 2>/dev/null || true

echo "[OK] 已更新：$DEPLOY_PARENT/dsv41-4p1d（GitHub 提交 $COMMIT）"
echo
echo "-- 配置确认（应有 NIC_NAME / MODEL_PATH 两行）："
grep -E "NIC_NAME=|MODEL_PATH=" "$DEPLOY_PARENT/dsv41-4p1d/config.sh" | head -2
echo
echo "-- 文件清单："
find "$DEPLOY_PARENT/dsv41-4p1d" -type f | sort
