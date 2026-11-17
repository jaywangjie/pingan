#!/usr/bin/env bash
# =============================================================================
# 部署包更新（P/D 任一台执行一次即可，SFS 共享）
# 与 4P1D 包的 update.sh 相同原则：浅克隆 + 只覆盖合并不删除
# =============================================================================
set -euo pipefail

DEPLOY_PARENT="/mnt/sfs_turbo/deploy"
PKG="dsv41-1p1d"
REPO="https://github.com/jaywangjie/pingan.git"

cd /

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

echo "[INFO] 从 GitHub 拉取最新部署包（浅克隆）..."
git clone -q --depth 1 "$REPO" "$TMP/pa"
COMMIT=$(git -C "$TMP/pa" rev-parse --short HEAD)

mkdir -p "$DEPLOY_PARENT/$PKG"
cp -r "$TMP/pa/$PKG/." "$DEPLOY_PARENT/$PKG/"
chmod +x "$DEPLOY_PARENT"/$PKG/*.sh \
         "$DEPLOY_PARENT"/$PKG/prefill/*.sh \
         "$DEPLOY_PARENT"/$PKG/decode/*.sh \
         "$DEPLOY_PARENT"/$PKG/kv_pool/*.sh 2>/dev/null || true

echo "[OK] 已更新：$DEPLOY_PARENT/$PKG（GitHub 提交 $COMMIT）"
echo
echo "-- 配置确认："
grep -E "^P1_IP=|^D1_IP=|NIC_NAME=|MODEL_PATH=" "$DEPLOY_PARENT/$PKG/config.sh" | head -4
echo
echo "-- 文件清单："
find "$DEPLOY_PARENT/$PKG" -type f | sort
