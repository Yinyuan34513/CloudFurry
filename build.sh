#!/bin/bash
# CloudFurry Linux 1.0 自动构建脚本
# 内核 7.8.91（本地源码树，含 XAPI 补丁）+ glibc/base + fpt + systemd stage2 + ISO

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DIR=/tmp/cloudfurry-build
KERNEL_TREE=${KERNEL_TREE:-/home/yin/Downloads/linux-7.3.1/linux-7.3.1}
KERNEL_VER=7.8.91
DISTRO_DIR=/tmp/linux_distro
INITRAMFS_DIR=$DISTRO_DIR/initramfs
PKG_DIR=/tmp/deep-repo
STAGE2=${STAGE2:-/home/yin/rootfs}
ROOTPW=${ROOTPW:-123456}

echo "=== ☁️ CloudFurry Linux 1.0 Build ==="
mkdir -p $DIR $DISTRO_DIR

# 1. 内核：使用本地 7.8.91 源码树（KERNEL_TREE 可覆盖）
echo "[1/6] 内核 $KERNEL_VER (本地树: $KERNEL_TREE)..."
if [ ! -f "$KERNEL_TREE/arch/x86/boot/bzImage" ]; then
    echo "  本地树无 bzImage, 编译中..."
    (cd "$KERNEL_TREE" && make -j$(nproc) bzImage 2>&1 | tail -3)
fi
cp "$KERNEL_TREE/arch/x86/boot/bzImage" $DISTRO_DIR/vmlinuz-$KERNEL_VER

# 2. stage2 rootfs（源码构建 glibc/bash/coreutils/util-linux/systemd）
echo "[2/6] stage2 rootfs (源码构建)..."
if [ ! -f "$STAGE2/.systemd-done" ]; then
    (cd "$(dirname "$0")" && STAGE2="$STAGE2" ROOTPW="$ROOTPW" bash stage2/src-build.sh 2>&1 | tail -5)
fi

# 3. 编译 Dropbear (SSH)
echo "[3/6] 编译 Dropbear..."
mkdir -p $INITRAMFS_DIR/bin $INITRAMFS_DIR/usr/bin
cd $DIR
[ -d dropbear-2024.85 ] || (curl -L https://matt.ucc.asn.au/dropbear/releases/dropbear-2024.85.tar.bz2 | tar xj)
cd dropbear-2024.85
./configure --enable-static --disable-pam --disable-zlib 2>/dev/null
make -j$(nproc) MULTI=1 2>/dev/null
cp dropbearmulti $INITRAMFS_DIR/bin/

# 4. 组装 initramfs（glibc + coreutils + bash 用户态）
echo "[4/6] 配置 initramfs (glibc base)..."
mkdir -p $INITRAMFS_DIR/{bin,usr/bin,usr/sbin,lib,lib64,etc,var/log,var/cache/fpt} \
         $INITRAMFS_DIR/usr/share/udhcpc $INITRAMFS_DIR/www \
         $INITRAMFS_DIR/proc $INITRAMFS_DIR/sys $INITRAMFS_DIR/dev \
         $INITRAMFS_DIR/tmp $INITRAMFS_DIR/root $INITRAMFS_DIR/run \
         $INITRAMFS_DIR/mnt/iso $INITRAMFS_DIR/mnt/stage2
chmod 1777 $INITRAMFS_DIR/tmp

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
         agetty login switch_root; do
    copy_bin "$b" $INITRAMFS_DIR/bin
done
# agetty 需要的额外运行时（libpam/login 相关），login 依赖 pam 库
for b in $INITRAMFS_DIR/bin/agetty $INITRAMFS_DIR/bin/login $INITRAMFS_DIR/bin/switch_root; do
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
cp "$SCRIPT_DIR/init.sh" $INITRAMFS_DIR/init
chmod +x $INITRAMFS_DIR/init
cp "$SCRIPT_DIR/menu.sh" $INITRAMFS_DIR/usr/bin/menu 2>/dev/null || true
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

# 6. 制作 ISO（stage2 rootfs 以 squashfs 内置，stage1 引导后 switch_root）
echo "[6/6] 制作 ISO..."
echo "  打包 stage2 rootfs (squashfs)..."
mksquashfs $STAGE2 $DISTRO_DIR/stage2.squashfs -noappend -comp zstd >/dev/null 2>&1

ISODIR=/tmp/cloudfurry-iso
rm -rf $ISODIR && mkdir -p $ISODIR/boot/grub $ISODIR/EFI/BOOT
cp $DISTRO_DIR/vmlinuz-$KERNEL_VER $ISODIR/boot/vmlinuz
cp $DISTRO_DIR/initramfs.gz $ISODIR/boot/initrd.img
cp $DISTRO_DIR/stage2.squashfs $ISODIR/
cat > $ISODIR/boot/grub/grub.cfg << GRUBEOF
set timeout=5
set default=0
menuentry "☁️ CloudFurry Linux 1.0 (x86-64) — kernel $KERNEL_VER" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200 quiet
    initrd /boot/initrd.img
}
menuentry "CloudFurry Linux - 详细日志" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200 loglevel=7
    initrd /boot/initrd.img
}
menuentry "CloudFurry Linux - 救援模式 (不进入 stage2)" {
    linux /boot/vmlinuz console=tty0 console=ttyS0,115200 single
    initrd /boot/initrd.img
}
GRUBEOF
ISO=cloudfurry-1.0-x86_64.iso
grub-mkrescue -o $DISTRO_DIR/$ISO $ISODIR 2>/dev/null

echo ""
echo "======================"
echo "  ☁️ CloudFurry Linux 1.0 构建完成!"
echo "======================"
echo "  ✅ ISO: $DISTRO_DIR/$ISO (可启动, stage2 squashfs 内置)"
echo "  ✅ 内核: $KERNEL_VER (本地树, XAPI + 启动问答门)"
echo "  ✅ stage2 rootfs: $STAGE2 (glibc/bash/coreutils/util-linux/systemd 源码构建)"
echo "  ✅ root 密码: $ROOTPW"
echo "  ✅ fpt 包管理器 (Rust, git 仓库: furrypkgs)"
ls -lh $DISTRO_DIR/$ISO
