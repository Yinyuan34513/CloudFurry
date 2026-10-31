#!/bin/bash
# Cloud LTE OS v8.1 自动构建脚本
# 内核 7.1.5 + WiFi + TUI Dashboard + Package Manager

set -e
DIR=/tmp/cloudlte-build
KERNEL_SRC=https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.1.5.tar.xz
DISTRO_DIR=/tmp/linux_distro
INITRAMFS_DIR=$DISTRO_DIR/initramfs
PKG_DIR=/tmp/deep-repo

echo "=== ☁️ Cloud LTE OS v8.1 Build ==="
mkdir -p $DIR $DISTRO_DIR

# 1. 下载内核源码
echo "[1/6] 下载内核源码..."
[ -f $DIR/linux-7.1.5.tar.xz ] || curl -L -o $DIR/linux-7.1.5.tar.xz $KERNEL_SRC
[ -d $DIR/linux-7.1.5 ] || (cd $DIR && tar xf linux-7.1.5.tar.xz)

# 2. 配置内核（启用 WiFi 支持）
echo "[2/6] 配置内核 (WiFi enabled)..."
cd $DIR/linux-7.1.5
if [ ! -f .config ]; then
    make defconfig
    # WiFi 支持
    ./scripts/config -e CONFIG_WLAN
    ./scripts/config -e CONFIG_WIRELESS
    ./scripts/config -e CONFIG_CFG80211
    ./scripts/config -e CONFIG_MAC80211
    ./scripts/config -e CONFIG_MAC80211_RC_DEFAULT_MINSTREL
    # 常见 WiFi 驱动
    ./scripts/config -e CONFIG_ATH_COMMON
    ./scripts/config -e CONFIG_ATH9K
    ./scripts/config -e CONFIG_ATH9K_HTC
    ./scripts/config -e CONFIG_ATH10K
    ./scripts/config -e CONFIG_ATH10K_PCI
    ./scripts/config -e CONFIG_BRCMFMAC
    ./scripts/config -e CONFIG_BRCMFMAC_PCIE
    ./scripts/config -e CONFIG_IWLWIFI
    ./scripts/config -e CONFIG_IWLDVM
    ./scripts/config -e CONFIG_IWLMVM
    ./scripts/config -e CONFIG_RTLWIFI
    ./scripts/config -e CONFIG_RTL8XXXU
    ./scripts/config -e CONFIG_MT7921E
    ./scripts/config -e CONFIG_RT2X00
    ./scripts/config -e CONFIG_RT2800USB
    # 压缩 initramfs
    ./scripts/config -e CONFIG_KERNEL_GZIP
    # 网桥/路由 (可选)
    ./scripts/config -e CONFIG_BRIDGE
    ./scripts/config -e CONFIG_NETFILTER
    ./scripts/config -e CONFIG_IP_NF_FILTER
    ./scripts/config -e CONFIG_NETFILTER_XT_MATCH_STATE
fi
echo "  编译内核..."
make -j$(nproc) bzImage 2>&1 | tail -3
cp arch/x86/boot/bzImage $DISTRO_DIR/

# 3. 编译 Dropbear (SSH)
echo "[3/6] 编译 Dropbear..."
cd $DIR
[ -d dropbear-2024.85 ] || (curl -L https://matt.ucc.asn.au/dropbear/releases/dropbear-2024.85.tar.bz2 | tar xj)
cd dropbear-2024.85
./configure --enable-static --disable-pam --disable-zlib 2>/dev/null
make -j$(nproc) MULTI=1 2>/dev/null
cp dropbearmulti $INITRAMFS_DIR/bin/

# 4. 组装 initramfs（glibc + coreutils + bash 用户态）
echo "[4/6] 配置 initramfs (glibc base)..."
mkdir -p $INITRAMFS_DIR/{bin,usr/bin,usr/sbin,lib,lib64,etc,var/log,var/cache/fpt} \
         $INITRAMFS_DIR/usr/share/udhcpc $INITRAMFS_DIR/www

# --- glibc 动态基座: 从宿主机复制 bash / coreutils / util-linux / git ---
copy_bin() { # copy_bin <abs-or-PATH-bin> <destdir>
    local src bin
    src=$(command -v "$1") || return 0
    cp -L "$src" "$2/$(basename "$src")" 2>/dev/null || true
}
copy_libs() { # copy_libs <binary>: 按需复制动态库
    ldd "$1" 2>/dev/null | awk '/=> \//{print $3} /^\s*linux-vdso/{next} /^\s*\/lib/{print $1}' |
    while read -r lib; do
        [ -f "$lib" ] || continue
        cp -L "$lib" $INITRAMFS_DIR/lib/ 2>/dev/null || true
    done
}

for b in bash ls cp mv rm cat echo mkdir rmdir ln chmod chown dd df grep sed awk \
         mount umount swapon mkswap tar gzip find printf sleep clear uname ps \
         hostname id true false test sync head tail wc tr cut sort uniq tee less \
         agetty login; do
    copy_bin "$b" $INITRAMFS_DIR/bin
done
# agetty 需要的额外运行时（libpam/login 相关），login 依赖 pam 库
for b in $INITRAMFS_DIR/bin/agetty $INITRAMFS_DIR/bin/login; do
    [ -f "$b" ] && copy_libs "$b"
done
# git（fpt 的下载方式完全基于 git 仓库）
copy_bin git $INITRAMFS_DIR/usr/bin
# glibc loader 放标准路径
LOADER=$(ldd /bin/bash 2>/dev/null | awk '/ld-linux/{print $1}')
[ -f "$LOADER" ] && cp -L "$LOADER" $INITRAMFS_DIR/lib64/ 2>/dev/null
for b in $INITRAMFS_DIR/bin/* $INITRAMFS_DIR/usr/bin/git; do
    [ -f "$b" ] && copy_libs "$b"
done
# busybox 保留为 applet 兜底 (udhcpc/httpd/crond 等)
[ -f $DISTRO_DIR/busybox ] && cp $DISTRO_DIR/busybox $INITRAMFS_DIR/bin/busybox

# 复制预编译的静态包
[ -f $PKG_DIR/packages/dialog/dialog ] && cp $PKG_DIR/packages/dialog/dialog $INITRAMFS_DIR/usr/bin/dialog
[ -f $PKG_DIR/packages/htop/htop ] && cp $PKG_DIR/packages/htop/htop $INITRAMFS_DIR/usr/bin/htop
[ -f $PKG_DIR/packages/iw/iw ] && cp $PKG_DIR/packages/iw/iw $INITRAMFS_DIR/usr/bin/iw
[ -f $PKG_DIR/packages/wpasupplicant/wpa_supplicant ] && cp $PKG_DIR/packages/wpasupplicant/wpa_supplicant $INITRAMFS_DIR/usr/bin/wpa_supplicant
[ -f $PKG_DIR/packages/wpa_passphrase/wpa_passphrase ] && cp $PKG_DIR/packages/wpa_passphrase/wpa_passphrase $INITRAMFS_DIR/usr/bin/wpa_passphrase

# 安装脚本到 initramfs
cp init.sh $INITRAMFS_DIR/init
chmod +x $INITRAMFS_DIR/init
cp menu.sh $INITRAMFS_DIR/usr/bin/menu 2>/dev/null || true
# fpt 包管理器（Rust, glibc 目标）替代 deep
if [ -f fpt/target/release/fpt ]; then
    cp fpt/target/release/fpt $INITRAMFS_DIR/bin/fpt
    ln -sf /bin/fpt $INITRAMFS_DIR/bin/deep 2>/dev/null || true
fi

chmod +x $INITRAMFS_DIR/init $INITRAMFS_DIR/usr/bin/* $INITRAMFS_DIR/bin/* 2>/dev/null || true

# 5. 打包 initramfs
echo "[5/6] 打包 initramfs..."
cd $INITRAMFS_DIR
find . | cpio -H newc -o 2>/dev/null | gzip > $DISTRO_DIR/initramfs.gz

# 6. 构建 UEFI 镜像
echo "[6/6] 构建 UEFI 镜像 (64MB)..."
cd $DISTRO_DIR
IMG=cloudlte_uefi.img
rm -f $IMG
echo "  构建 512MB 镜像 (128MB EFI + 384MB 数据分区)..."
dd if=/dev/zero of=$IMG bs=1M count=512 2>/dev/null
parted -s $IMG mklabel gpt 2>/dev/null
parted -s $IMG mkpart primary fat32 1MiB 129MiB 2>/dev/null
parted -s $IMG set 1 esp on 2>/dev/null
parted -s $IMG mkpart primary ext4 129MiB 511MiB 2>/dev/null

LOOP=$(losetup -Pf --show $IMG 2>/dev/null)
mkfs.vfat -F32 -n CLOUDLTE ${LOOP}p1 2>/dev/null
mkfs.ext4 -L APTROOT ${LOOP}p2 2>/dev/null
mount ${LOOP}p1 /mnt 2>/dev/null
mkdir -p /mnt/EFI/BOOT /mnt/boot/grub
grub-mkimage -o /mnt/EFI/BOOT/BOOTX64.EFI -O x86_64-efi -p /EFI/BOOT \
  fat ext2 part_gpt normal boot linux configfile loopback search help 2>/dev/null
cp $DISTRO_DIR/initramfs.gz /mnt/boot/initrd.img
cp bzImage /mnt/boot/vmlinuz
cat > /mnt/boot/grub/grub.cfg << 'GRUBEOF'
set timeout=5
set default=0
menuentry "☁️ Cloud LTE OS 7.1.5 (v8.1)" {
    linux /boot/vmlinuz quiet
    initrd /boot/initrd.img
}
menuentry "Cloud LTE OS - 救援模式" {
    linux /boot/vmlinuz single
    initrd /boot/initrd.img
}
menuentry "Cloud LTE OS - 详细日志" {
    linux /boot/vmlinuz loglevel=7
    initrd /boot/initrd.img
}
GRUBEOF
# 拷贝 apt 支持包到数据分区
echo "[7/7] 拷贝 apt 支持到数据分区..."
mkdir -p /mnt/data
mount ${LOOP}p2 /mnt/data 2>/dev/null
mkdir -p /mnt/data/apt
if [ -f /tmp/cloudlte-apt-rootfs.tar.gz ]; then
  cp /tmp/cloudlte-apt-rootfs.tar.gz /mnt/data/apt/ubuntu-rootfs.tar.gz
elif [ -f apt-ubuntu/ubuntu-rootfs.tar.gz ]; then
  cp apt-ubuntu/ubuntu-rootfs.tar.gz /mnt/data/apt/
else
  echo "⚠️  ubuntu-rootfs.tar.gz 未找到, apt 支持跳过"
fi
cp apt-ubuntu/apt /mnt/data/apt/ 2>/dev/null
cp apt-ubuntu/install-apt.sh /mnt/data/apt/ 2>/dev/null
chmod +x /mnt/data/apt/apt /mnt/data/apt/install-apt.sh 2>/dev/null
ls -la /mnt/data/apt/ 2>/dev/null
sync
umount /mnt/data 2>/dev/null
umount /mnt 2>/dev/null
losetup -d $LOOP 2>/dev/null

cp $IMG /root/.openclaw/workspace/cloudlte_v8.3.img

echo ""
echo "======================"
echo "  ☁️ 构建完成!"
echo "======================"
echo "  v8.3 更新内容:"
echo "  ✅ apt 包管理器 (Ubuntu chroot, 数据分区)"
echo "  ✅ fpt 管理器 (Rust, git 仓库下载)"
echo "  ✅ 512MB 镜像 (128MB EFI + 384MB 数据)"
echo "  ✅ WiFi + TUI + Swap + Logrotate"
echo ""
echo "  镜像: /root/.openclaw/workspace/cloudlte_v8.3.img"
ls -lh /root/.openclaw/workspace/cloudlte_v8.3.img
