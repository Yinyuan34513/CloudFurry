#!/bin/sh
# ============================================================
# install-apt.sh — Cloud LTE OS 安装 apt 支持 (Ubuntu chroot)
# ============================================================
# 用法: sh install-apt.sh [rootfs.tar.gz]
# 作用:
#   1. 解压 Ubuntu rootfs 到 /opt/ubuntu-rootfs
#   2. 安装 apt 命令 (chroot 封装) 到 /usr/bin/apt
#   3. 保留 deep 管理器 (不动)
# ============================================================

set -e
SRC="${1:-/tmp/cloudlte-apt-rootfs.tar.gz}"
UBUNTU_ROOT=/opt/ubuntu-rootfs

echo "=== ☁️ Cloud LTE OS + apt (Ubuntu chroot) ==="

# 1. 解压 Ubuntu rootfs
if [ -d "$UBUNTU_ROOT/usr/bin/apt" ]; then
    echo "✅ Ubuntu rootfs 已存在, 跳过解压"
else
    echo "[1/3] 解压 Ubuntu rootfs..."
    mkdir -p "$UBUNTU_ROOT"
    tar xzf "$SRC" -C / --strip-components=1 --wildcards 'cloudlte-ubuntu-rootfs/*' 2>/dev/null || \
    tar xzf "$SRC" -C "$UBUNTU_ROOT" --strip-components=1 2>/dev/null || \
    { echo "❌ 解压失败"; exit 1; }
    echo "✅ rootfs: $(du -sh $UBUNTU_ROOT | cut -f1)"
fi

# 2. 安装 apt 命令
echo "[2/3] 安装 apt 命令 (chroot 封装)..."
install -m 755 /tmp/apt "$UBUNTU_ROOT/../../usr/bin/apt" 2>/dev/null || \
install -m 755 /tmp/apt /usr/bin/apt
ln -sf /usr/bin/apt /usr/bin/apt-get 2>/dev/null
ln -sf /usr/bin/apt /usr/bin/apt-cache 2>/dev/null
ln -sf /usr/bin/apt /usr/bin/apt-mark 2>/dev/null
echo "✅ apt 命令已安装"

# 3. 验证
echo "[3/3] 验证..."
chmod +x /usr/bin/apt 2>/dev/null || true
if [ -x "$UBUNTU_ROOT/usr/bin/apt-get" ]; then
    echo "✅ apt 就绪! 用法:"
    echo "   apt update          # 刷新软件源"
    echo "   apt install curl    # 安装软件 (Ubuntu 生态)"
    echo "   apt shell           # 进入 Ubuntu chroot"
    echo "   deep install htop   # deep 管理器照常使用"
else
    echo "⚠️  rootfs 的 apt 缺失, 请检查"
fi
