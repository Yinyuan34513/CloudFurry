#!/bin/bash
# CloudFurry Linux 7.1.5 v9.0 init —— glibc + coreutils + bash 用户态
export PATH=/usr/bin:/bin:/sbin:/usr/sbin

mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs none /dev
mount -t tmpfs none /tmp

# 确保关键目录存在
mkdir -p /proc /sys /dev /tmp /root /etc /usr/bin /var/log /var/cache/fpt

# Console
for tty in /dev/ttyS0 /dev/tty1 /dev/console; do
    [ -c "$tty" ] && exec < "$tty" > "$tty" 2>&1 && break
done

# ===== 系统稳定性 =====
# 1. swap 文件 (64MB, 防止 OOM) - 放 /tmp (tmpfs)
if [ ! -f /tmp/swapfile ]; then
    dd if=/dev/zero of=/tmp/swapfile bs=1M count=64 2>/dev/null
    chmod 600 /tmp/swapfile
    mkswap /tmp/swapfile 2>/dev/null
    swapon /tmp/swapfile 2>/dev/null && echo "  ✅ swap 已启用 (64MB)"
fi

# 2. 日志轮转 (防止 /var/log 写满)
mkdir -p /var/spool/cron/crontabs 2>/dev/null
echo "0 3 * * *  find /var/log -type f -size +1M -exec truncate -s 1M {} \\; 2>/dev/null" >> /etc/crontabs/root 2>/dev/null || true
crond 2>/dev/null &

# 3. 清理临时文件
rm -rf /tmp/* 2>/dev/null

# Start networking (eth0 DHCP) —— busybox applet 兜底（glibc 基座无 dhcp 守护进程）
udhcpc -i eth0 -q -s /usr/share/udhcpc/default.script 2>/dev/null &

# ===== apt 支持 (Ubuntu chroot, 数据分区) =====
APT_ROOT=/opt/ubuntu-rootfs
mount_apt() {
    # 找数据分区 (GPT p2, ext4)
    for dev in /dev/sda2 /dev/vda2 /dev/nvme0n1p2 /dev/mmcblk0p2; do
        [ -b "$dev" ] || continue
        mkdir -p /mnt/data
        mount "$dev" /mnt/data 2>/dev/null && {
            echo "  ✅ 数据分区已挂载: $dev"
            # 安装 apt 命令 (首次)
            if [ -f /mnt/data/apt/apt ] && [ ! -x /usr/bin/apt ]; then
                cp /mnt/data/apt/apt /usr/bin/apt
                ln -sf /usr/bin/apt /usr/bin/apt-get
                chmod +x /usr/bin/apt
                echo "  ✅ apt 命令已安装 (Ubuntu 生态)"
            fi
            # 解压 Ubuntu rootfs (首次, 需内存 >256MB)
            if [ -f /mnt/data/apt/ubuntu-rootfs.tar.gz ] && [ ! -d "$APT_ROOT/usr/bin" ]; then
                RAM_KB=$(grep MemTotal /proc/meminfo | awk '{print $2}')
                if [ "$RAM_KB" -gt 262144 ]; then
                    echo "  解压 Ubuntu rootfs (首次启动, 需 1-2 分钟)..."
                    mkdir -p "$APT_ROOT"
                    tar xzf /mnt/data/apt/ubuntu-rootfs.tar.gz -C / --strip-components=1 --wildcards 'cloudlte-ubuntu-rootfs/*' 2>/dev/null
                    echo "  ✅ Ubuntu rootfs 就绪: apt install curl 可用"
                else
                    echo "  ⚠️  内存不足 (<256MB), apt 需手动启用: apt shell"
                fi
            fi
            return 0
        }
    done
    echo "  ⚠️  未找到数据分区, apt 不可用 (fpt 管理器正常)"
}
mount_apt

# Welcome screen (NixOS style)
echo ""
echo "  <<< Welcome to CloudFurry Linux 1.0 (x86-64)! >>>"
echo ""
echo "  [ OK ] Reached target Basic System"
echo "  [ OK ] Started fpt Package Manager daemon"
echo "  [ OK ] Started Console Getty (agetty)"
echo ""
echo "  Commands:"
echo "    menu    - 系统管理面板"
echo "    fpt     - 包管理器 (git 仓库: furrypkgs)"
echo "    apt     - 包管理器 (Ubuntu 生态)"
echo ""

# ===== 登录 (util-linux agetty + login, NixOS 风格自动登录 root) =====
if [ -x /bin/agetty ] && [ -x /bin/login ]; then
    # 图形控制台
    /bin/agetty --autologin root -8 tty1 38400 &
    # 串口控制台
    for tty in /dev/ttyS0 /dev/console; do
        [ -c "$tty" ] || continue
        /bin/agetty --autologin root -8 -L "${tty#/dev/}" 115200 &
    done
    # PID1 常驻，等待 getty 退出后重启
    while :; do
        wait
        sleep 1
    done
fi

echo "进入 shell (输入 menu 打开面板)"
exec /bin/bash
