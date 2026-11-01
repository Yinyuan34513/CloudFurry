#!/bin/bash
# CloudFurry Linux — stage2 rootfs 源码构建
# 软件包全部由源码构建：glibc / bash / coreutils / util-linux（Aliyun GNU
# 镜像）+ systemd（github release，经 gh-proxy）。构建产物安装到 stage2
# rootfs（DESTDIR 方式，无需 root），root 密码固定 123456。
set -e

GNU=https://mirrors.aliyun.com/gnu
KORG=https://mirrors.edge.kernel.org/pub/linux/utils
GHP=https://v4.gh-proxy.org/https://github.com
WORK=${WORK:-/tmp/cloudfurry-srcbuild}
STAGE2=${STAGE2:-/tmp/cloudfurry-stage2}
JOBS=$(nproc)
ROOTPW=${ROOTPW:-123456}

mkdir -p "$WORK" "$STAGE2"
cd "$WORK"
export PATH="/tmp/cloudfurry-tools/bin:$PATH"

fetch() { # fetch <url> <out>
    [ -f "$2" ] || curl -fL --connect-timeout 20 --retry 3 -o "$2" "$1"
}

# ---------- 0. 构建工具：gperf（GNU），meson（源码直跑），jinja2/markupsafe（纯 Python vendor） ----------
echo "=== [0/6] 构建工具链补齐 ==="
mkdir -p /tmp/cloudfurry-tools/bin "$WORK/pyvendor"
if [ ! -x /tmp/cloudfurry-tools/bin/gperf ]; then
    fetch "$GNU/gperf/gperf-3.1.tar.gz" gperf-3.1.tar.gz
    rm -rf gperf-3.1 && tar xf gperf-3.1.tar.gz
    (cd gperf-3.1 && ./configure --prefix=/tmp/cloudfurry-tools >/dev/null && make -j$JOBS >/dev/null && make install >/dev/null)
fi
if [ ! -d meson-src ]; then
    fetch "$GHP/mesonbuild/meson/archive/refs/tags/1.5.2.tar.gz" meson-1.5.2.tar.gz
    mkdir -p meson-src && tar xf meson-1.5.2.tar.gz -C meson-src --strip-components=1
fi
MESON="python3 $WORK/meson-src/meson.py"
# gawk（glibc configure 必需，宿主缺失时源码自建）
if ! command -v gawk >/dev/null 2>&1 && [ ! -x /tmp/cloudfurry-tools/bin/gawk ]; then
    fetch "$GNU/gawk/gawk-5.3.1.tar.xz" gawk-5.3.1.tar.xz
    rm -rf gawk-5.3.1 && tar xf gawk-5.3.1.tar.xz
    (cd gawk-5.3.1 && ./configure --prefix=/tmp/cloudfurry-tools >/dev/null && make -j$JOBS >/dev/null 2>&1 && make install >/dev/null 2>&1)
fi
# jinja2/markupsafe 纯 python 部分 vendor 进 PYTHONPATH（systemd 构建需要）
if [ ! -d "$WORK/pyvendor/jinja2" ]; then
    fetch "$GHP/pallets/jinja/archive/refs/tags/3.1.4.tar.gz" Jinja2.tar.gz
    fetch "$GHP/pallets/markupsafe/archive/refs/tags/2.1.5.tar.gz" MarkupSafe.tar.gz
    tar xf Jinja2.tar.gz && tar xf MarkupSafe.tar.gz
    cp -r jinja-3.1.4/src/jinja2 "$WORK/pyvendor/"
    cp -r markupsafe-2.1.5/src/markupsafe "$WORK/pyvendor/"
fi
export PYTHONPATH="$WORK/pyvendor"

# ---------- 1. glibc 2.40 ----------
echo "=== [1/6] glibc 2.40 ==="
if [ ! -f "$STAGE2/.glibc-done" ]; then
    fetch "$GNU/glibc/glibc-2.40.tar.xz" glibc-2.40.tar.xz
    rm -rf glibc-2.40 glibc-build && tar xf glibc-2.40.tar.xz
    mkdir glibc-build && cd glibc-build
    ../glibc-2.40/configure --prefix=/usr --disable-werror \
        --enable-kernel=5.4 --disable-profile >/dev/null
    make -j$JOBS >/dev/null 2>&1
    make install_root="$STAGE2" install >/dev/null 2>&1
    touch "$STAGE2/.glibc-done"
    cd "$WORK"
fi

# ---------- 2. bash 5.2 ----------
echo "=== [2/6] bash 5.2 ==="
if [ ! -f "$STAGE2/.bash-done" ]; then
    fetch "$GNU/bash/bash-5.2.37.tar.gz" bash-5.2.37.tar.gz
    rm -rf bash-5.2.37 && tar xf bash-5.2.37.tar.gz
    (cd bash-5.2.37 && ./configure --prefix=/usr --without-bash-malloc >/dev/null \
        && make -j$JOBS >/dev/null 2>&1 \
        && make DESTDIR="$STAGE2" install >/dev/null 2>&1)
    touch "$STAGE2/.bash-done"
fi

# ---------- 3. coreutils 9.5 ----------
echo "=== [3/6] coreutils 9.5 ==="
if [ ! -f "$STAGE2/.coreutils-done" ]; then
    fetch "$GNU/coreutils/coreutils-9.5.tar.xz" coreutils-9.5.tar.xz
    rm -rf coreutils-9.5 && tar xf coreutils-9.5.tar.xz
    (cd coreutils-9.5 && ./configure --prefix=/usr >/dev/null \
        && make -j$JOBS >/dev/null 2>&1 \
        && make DESTDIR="$STAGE2" install >/dev/null 2>&1)
    touch "$STAGE2/.coreutils-done"
fi

# ---------- 4. util-linux 2.40 ----------
echo "=== [4/6] util-linux 2.40 ==="
if [ ! -f "$STAGE2/.util-linux-done" ]; then
    fetch "$KORG/util-linux/v2.40/util-linux-2.40.2.tar.xz" util-linux-2.40.2.tar.xz
    rm -rf util-linux-2.40.2 && tar xf util-linux-2.40.2.tar.xz
    (cd util-linux-2.40.2 && PKG_CONFIG_PATH="$STAGE2/usr/lib/pkgconfig" \
        CPPFLAGS="-I$STAGE2/usr/include" LDFLAGS="-L$STAGE2/usr/lib -L$STAGE2/lib64" \
        ./configure --prefix=/usr --enable-login \
        --without-systemdsystemunitdir --disable-makeinstall-chown \
        --disable-liblastlog2 >/dev/null \
        && make -j$JOBS >/dev/null 2>&1 \
        && make DESTDIR="$STAGE2" install >/dev/null 2>&1)
    touch "$STAGE2/.util-linux-done"
fi

# ---------- 4.5 libcap（systemd 硬依赖 sys/capability.h）----------
echo "=== [4.5/6] libcap 2.71 ==="
if [ ! -f "$STAGE2/.libcap-done" ]; then
    fetch "https://mirrors.edge.kernel.org/pub/linux/libs/security/linux-privs/libcap2/libcap-2.71.tar.xz" libcap-2.71.tar.xz
    rm -rf libcap-2.71 && tar xf libcap-2.71.tar.xz
    (cd libcap-2.71 && make -j$JOBS prefix=/usr lib=lib GOLANG=no >/dev/null 2>&1 \
        && make DESTDIR="$STAGE2" prefix=/usr lib=lib GOLANG=no RAISE_SETFCAP=no install >/dev/null 2>&1)
    touch "$STAGE2/.libcap-done"
fi

# ---------- 4.6 libxcrypt（libcrypt.so.1，util-linux/shadow 依赖）----------
echo "=== [4.6/6] libxcrypt 4.4.36 ==="
if [ ! -f "$STAGE2/.libxcrypt-done" ]; then
    fetch "$GHP/besser82/libxcrypt/releases/download/v4.4.36/libxcrypt-4.4.36.tar.xz" libxcrypt-4.4.36.tar.xz
    rm -rf libxcrypt-4.4.36 && tar xf libxcrypt-4.4.36.tar.xz
    (cd libxcrypt-4.4.36 && ./configure --prefix=/usr >/dev/null \
        && make -j$JOBS >/dev/null 2>&1 \
        && make DESTDIR="$STAGE2" install >/dev/null 2>&1)
    touch "$STAGE2/.libxcrypt-done"
fi

# ---------- 4.7 Linux-PAM（util-linux login/su 的认证后端）----------
echo "=== [4.7/6] Linux-PAM 1.6.1 ==="
if [ ! -f "$STAGE2/.libpam-done" ]; then
    fetch "$GHP/linux-pam/linux-pam/releases/download/v1.6.1/Linux-PAM-1.6.1.tar.xz" Linux-PAM-1.6.1.tar.xz
    rm -rf Linux-PAM-1.6.1 && tar xf Linux-PAM-1.6.1.tar.xz
    (cd Linux-PAM-1.6.1 && PKG_CONFIG_PATH="$STAGE2/usr/lib/pkgconfig" \
        CPPFLAGS="-I$STAGE2/usr/include" LDFLAGS="-L$STAGE2/usr/lib -L$STAGE2/lib64" \
        ./configure --prefix=/usr --disable-selinux --disable-nis >/dev/null \
        && make -j$JOBS >/dev/null 2>&1 \
        && make DESTDIR="$STAGE2" install >/dev/null 2>&1)
    # 最小 PAM 配置：login/su/other 走 pam_unix
    mkdir -p "$STAGE2/etc/pam.d"
    for svc in login su other; do
        printf 'auth       required   pam_unix.so\naccount    required   pam_unix.so\npassword   required   pam_unix.so\nsession    required   pam_unix.so\n' \
            > "$STAGE2/etc/pam.d/$svc"
    done
    touch "$STAGE2/.libpam-done"
    # .la 文件引用宿主绝对路径，会导致后续 libtool 编译失败
    find "$STAGE2" -name "*.la" -delete
fi

# ---------- 4.8 ncurses（libtinfo.so.6，bash 依赖）----------
echo "=== [4.8/6] ncurses 6.5 ==="
if [ ! -f "$STAGE2/.ncurses-done" ]; then
    fetch "$GNU/ncurses/ncurses-6.5.tar.gz" ncurses-6.5.tar.gz
    rm -rf ncurses-6.5 && tar xf ncurses-6.5.tar.gz
    (cd ncurses-6.5 && ./configure --prefix=/usr --with-shared \
        --without-ada --disable-db-install --without-tests >/dev/null \
        && make -j$JOBS >/dev/null 2>&1 \
        && make DESTDIR="$STAGE2" install.libs >/dev/null 2>&1)
    touch "$STAGE2/.ncurses-done"
fi

# ---------- 4.9 pcre2 + grep ----------
echo "=== [4.9/6] pcre2 10.44 ==="
if [ ! -f "$STAGE2/.pcre2-done" ]; then
    fetch "$GHP/PCRE2Project/pcre2/releases/download/pcre2-10.44/pcre2-10.44.tar.bz2" pcre2-10.44.tar.bz2
    rm -rf pcre2-10.44 && tar xf pcre2-10.44.tar.bz2
    (cd pcre2-10.44 && ./configure --prefix=/usr --enable-pcre2-16 --enable-pcre2-32 >/dev/null \
        && make -j$JOBS >/dev/null 2>&1 \
        && make DESTDIR="$STAGE2" install >/dev/null 2>&1)
    touch "$STAGE2/.pcre2-done"
fi
echo "=== [4.10/6] grep 3.11 ==="
if [ ! -f "$STAGE2/.grep-done" ]; then
    fetch "$GNU/grep/grep-3.11.tar.xz" grep-3.11.tar.xz
    rm -rf grep-3.11 && tar xf grep-3.11.tar.xz
    (cd grep-3.11 && PKG_CONFIG_PATH="$STAGE2/usr/lib/pkgconfig" \
        CPPFLAGS="-I$STAGE2/usr/include" LDFLAGS="-L$STAGE2/usr/lib -L$STAGE2/lib64" \
        ./configure --prefix=/usr >/dev/null \
        && make -j$JOBS >/dev/null 2>&1 \
        && make DESTDIR="$STAGE2" install >/dev/null 2>&1)
    touch "$STAGE2/.grep-done"
fi

# ---------- 5. systemd 257（meson, 最小化 feature set）----------
echo "=== [5/6] systemd 257 ==="
if [ ! -f "$STAGE2/.systemd-done" ]; then
    fetch "$GHP/systemd/systemd/archive/refs/tags/v257.6.tar.gz" systemd-257.6.tar.gz
    rm -rf systemd-257.6 systemd-build && tar xf systemd-257.6.tar.gz
    mkdir systemd-build && cd systemd-build
    # 链接 stage2 里新构建的 glibc/util-linux（libmount/libblkid/libuuid）
    export PKG_CONFIG_PATH="$STAGE2/usr/lib/pkgconfig"
    export CPPFLAGS="-I$STAGE2/usr/include"
    export LDFLAGS="-L$STAGE2/usr/lib"
    $MESON setup build ../systemd-257.6 \
        -Dprefix=/usr \
        -Drootlibdir="$STAGE2/usr/lib" \
        -Dc_args="-I$STAGE2/usr/include -Wno-error -Wno-error=shift-overflow" -Dcpp_args="-I$STAGE2/usr/include -Wno-error -Wno-error=shift-overflow" \
        -Dc_link_args="-L$STAGE2/usr/lib" -Dcpp_link_args="-L$STAGE2/usr/lib" \
        -Dman=false -Defi=false -Dtests=false -Dfuzz-tests=false \
        -Dinstall-tests=false -Dpam=disabled \
        -Dselinux=disabled -Dacl=disabled -Daudit=disabled \
        -Dkmod=disabled -Dxz=disabled -Dzstd=disabled -Dlz4=disabled \
        -Dbzip2=disabled -Dgcrypt=disabled -Dgnutls=disabled \
        -Dopenssl=disabled -Dlibcurl=disabled -Dlibidn2=disabled \
        -Dlibiptc=disabled -Dmicrohttpd=disabled -Ddns-over-tls=false \
        -Dfirstboot=false -Drepart=false -Dhomed=false -Duserdb=false \
        -Dukify=false -Dbootloader=false -Dsysupdate=false \
        -Dnss-systemd=false -Dcoredump=false -Dquotacheck=false \
        -Drfkill=false -Dtpm=false >/dev/null
    ninja -C build -j$JOBS >/dev/null 2>&1
    DESTDIR="$STAGE2" ninja -C build install >/dev/null 2>&1
    touch "$STAGE2/.systemd-done"
    cd "$WORK"
fi

# ---------- 4.11 dbus（system 总线，systemd-logind 依赖）----------
echo "=== [4.11/6] dbus 1.13.6 ==="
if [ ! -f "$STAGE2/.dbus-done" ]; then
    fetch "https://dbus.freedesktop.org/releases/dbus/dbus-1.13.6.tar.gz" dbus-1.13.6.tar.gz
    rm -rf dbus-1.13.6 && tar xf dbus-1.13.6.tar.gz
    (cd dbus-1.13.6 && ./configure --prefix=/usr \
        --disable-doxygen --disable-selinux --disable-apparmor \
        --disable-libsystemd --disable-systemd-inhibit --disable-elsa \
        --disable-inotifysupport --disable-udev >/dev/null \
        && make -j$JOBS >/dev/null 2>&1 \
        && make DESTDIR="$STAGE2" install >/dev/null 2>&1)
    touch "$STAGE2/.dbus-done"
fi

# ---------- 4.12 kbd（loadkeys/fixfont，systemd-vconsole-setup 依赖）----------
echo "=== [4.12/6] kbd 2.7.1 ==="
if [ ! -f "$STAGE2/.kbd-done" ]; then
    fetch "https://mirrors.edge.kernel.org/pub/linux/utils/kbd/kbd-2.7.1.tar.xz" kbd-2.7.1.tar.xz
    rm -rf kbd-2.7.1 && tar xf kbd-2.7.1.tar.xz
    (cd kbd-2.7.1 && PKG_CONFIG_PATH="$STAGE2/usr/lib/pkgconfig" \
        CPPFLAGS="-I$STAGE2/usr/include" LDFLAGS="-L$STAGE2/lib64" \
        ./configure --prefix=/usr --sysconfdir=/etc --disable-tests >/dev/null \
        && make -j$JOBS >/dev/null 2>&1 \
        && make DESTDIR="$STAGE2" install >/dev/null 2>&1)
    touch "$STAGE2/.kbd-done"
fi

# ---------- 4.13 libselinux + expat（coreutils/dbus 运行时依赖）----------
echo "=== [4.13/6] libselinux 3.11 + expat 2.6.4 ==="
if [ ! -f "$STAGE2/.libselinux-done" ]; then
    fetch "$GHP/SELinuxProject/selinux/releases/download/3.11/libselinux-3.11.tar.gz" libselinux-3.11.tar.gz
    rm -rf libselinux-3.11 && tar xf libselinux-3.11.tar.gz
    (cd libselinux-3.11 && make -j$JOBS PKG_CONFIG_PATH="$STAGE2/usr/lib/pkgconfig" DISABLE_X11=y \
        && make install DESTDIR="$STAGE2" PREFIX=/usr LIBDIR=/usr/lib SHLIBDIR=/usr/lib)
    touch "$STAGE2/.libselinux-done"
fi
if [ ! -f "$STAGE2/.expat-done" ]; then
    fetch "$GHP/libexpat/libexpat/releases/download/R_2_6_4/expat-2.6.4.tar.xz" expat-2.6.4.tar.xz
    rm -rf expat-2.6.4 expat-2.6.4-build && tar xf expat-2.6.4.tar.xz
    (mkdir expat-2.6.4-build && cd expat-2.6.4-build \
        && cmake ../expat-2.6.4 -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib \
             -DBUILD_SHARED_LIBS=ON -DEXAT_BUILD_TESTS=OFF >/dev/null \
        && make -j$JOBS >/dev/null 2>&1 \
        && make DESTDIR="$STAGE2" install >/dev/null 2>&1)
    touch "$STAGE2/.expat-done"
fi

# ---------- 6. rootfs 收尾：/etc、root 密码、systemd 引导符号 ----------
echo "=== [6/6] rootfs 收尾 ==="
mkdir -p "$STAGE2/etc" "$STAGE2/dev" "$STAGE2/proc" "$STAGE2/sys" "$STAGE2/tmp" \
         "$STAGE2/root" "$STAGE2/run" "$STAGE2/run/lock" "$STAGE2/var/log" "$STAGE2/mnt" "$STAGE2/opt"
chmod 1777 "$STAGE2/tmp"
# systemd 首启要求：/etc/machine-id 存在且可写根下会自动填充
rm -f "$STAGE2/etc/machine-id"
: > "$STAGE2/etc/machine-id"

cat > "$STAGE2/etc/passwd" <<'EOF'
root:x:0:0:root:/root:/bin/bash
daemon:x:1:1:daemon:/usr/sbin:/usr/bin/false
nobody:x:65534:65534:nobody:/:
systemd-network:x:100:100:systemd-network:/:
systemd-resolve:x:101:101:systemd-resolve:/:
EOF
cat > "$STAGE2/etc/group" <<'EOF'
root:x:0:
daemon:x:1:
tty:x:5:
systemd-journal:x:102:
EOF
# root 密码: 123456（SHA512-crypt，离线生成，无需 chroot）
PW_HASH=$(python3 -c "import crypt,os; print(crypt.crypt('$ROOTPW', '\$6\$' + os.urandom(8).hex()))" 2>/dev/null \
          || openssl passwd -6 "$ROOTPW" 2>/dev/null \
          || perl -e 'print crypt($ARGV[0], "\$6\$" . substr(rand,2,16))' "$ROOTPW")
cat > "$STAGE2/etc/shadow" <<EOF
root:$PW_HASH:19000:0:99999:7:::
daemon:!:19000:0:99999:7:::
nobody:!:19000:0:99999:7:::
EOF
chmod 600 "$STAGE2/etc/shadow"
chmod 644 "$STAGE2/etc/passwd" "$STAGE2/etc/group"

cat > "$STAGE2/etc/os-release" <<'EOF'
NAME="CloudFurry Linux"
VERSION="1.0 (x86-64)"
ID=cloudfurry
PRETTY_NAME="CloudFurry Linux 1.0 (x86-64)"
EOF
# NSS：显式 files 优先（缺失时 login 的 getpwnam/getspnam 可能失败）
cat > "$STAGE2/etc/nsswitch.conf" <<'EOF'
passwd: files
group: files
shadow: files
hosts: files dns
EOF
echo "cloudfurry" > "$STAGE2/etc/hostname"
cat > "$STAGE2/etc/fstab" <<'EOF'
# stage2 rootfs — 挂载点由 stage1 保证
EOF
# systemd 为 PID1
mkdir -p "$STAGE2/sbin"
ln -sf ../usr/lib/systemd/systemd "$STAGE2/sbin/init"
# usrmerge：agetty 等按 /bin/login 路径调用
for d in bin sbin lib; do
    [ -e "$STAGE2/$d" ] || ln -s "usr/$d" "$STAGE2/$d"
done
[ -L "$STAGE2/bin" ] || (cp -a "$STAGE2/bin/." "$STAGE2/usr/bin/" 2>/dev/null; rm -rf "$STAGE2/bin"; ln -s usr/bin "$STAGE2/bin")
# systemd 外部挂载单元（dev-hugepages 等）调用 mount(8)：setuid 保证有 CAP_SYS_ADMIN
chmod 4755 "$STAGE2/usr/bin/mount" 2>/dev/null || true
# stage2 包由宿主 gcc 编译，运行时依赖宿主的 libgcc_s.so.1（ABI 稳定，直接复用）
for lsrc in /usr/lib/x86_64-linux-gnu/libgcc_s.so.1 /lib/x86_64-linux-gnu/libgcc_s.so.1 /usr/lib64/libgcc_s.so.1; do
    [ -f "$lsrc" ] && cp -a "$lsrc" "$STAGE2/lib64/" && break
done
# uuidd-tmpfiles.conf 引用 uuidd 用户
grep -q "^uuidd:" "$STAGE2/etc/passwd" 2>/dev/null || \
    printf 'uuidd:x:65:65:uuidd daemon:/var/lib/uuid:/usr/sbin/nologin\n' >> "$STAGE2/etc/passwd"
grep -q "^uuidd:" "$STAGE2/etc/group" 2>/dev/null || \
    printf 'uuidd:x:65:\n' >> "$STAGE2/etc/group"
# 串口控制台无 VT，loadkeys 无法工作：mask vconsole-setup（禁用为正确状态）
ln -sf /dev/null "$STAGE2/etc/systemd/system/systemd-vconsole-setup.service"

# ---------- 6.1 D-Bus 系统总线：system.conf + messagebus 用户 + /run/dbus 路径链 ----------
grep -q "^messagebus:" "$STAGE2/etc/passwd" 2>/dev/null || \
    printf 'messagebus:x:101:102:System Message Bus:/nonexistent:/usr/sbin/nologin\n' >> "$STAGE2/etc/passwd"
grep -q "^messagebus:" "$STAGE2/etc/group" 2>/dev/null || \
    printf 'messagebus:x:102:\n' >> "$STAGE2/etc/group"
# systemd tmpfiles 的 d /usr/var/run/dbus/containers 需要 /usr/var/run 可解析到 /run
# （run 目录是纯运行时目录，可能已被某包建成真实目录——清空替换为符号链接）
mkdir -p "$STAGE2/usr/var" "$STAGE2/var/lib/dbus"
if [ -e "$STAGE2/usr/var/run" ]; then rm -rf "$STAGE2/usr/var/run"; fi
if [ -e "$STAGE2/var/run" ]; then rm -rf "$STAGE2/var/run"; fi
ln -s /run "$STAGE2/usr/var/run"
ln -s /run "$STAGE2/var/run"
# dbus-daemon 读 machine-id（/var/lib/dbus/machine-id → /etc/machine-id）
ln -sf /etc/machine-id "$STAGE2/var/lib/dbus/machine-id"
mkdir -p "$STAGE2/etc/dbus-1/system.d"
cat > "$STAGE2/etc/dbus-1/system.conf" <<'DBUSEOF'
<!DOCTYPE busconfig PUBLIC "-//freedesktop//DTD D-Bus Bus Configuration 1.0//EN" "http://www.freedesktop.org/standards/dbus/1.0/busconfig.dtd">
<busconfig>
  <type>system</type>
  <user>messagebus</user>
  <fork/>
  <standard_system_servicedirs/>
  <servicehelper>/usr/libexec/dbus-daemon-launch-helper</servicehelper>
  <pidfile>/run/dbus/pid</pidfile>
  <syslog/>
  <auth>EXTERNAL</auth>
  <listen>unix:path=/run/dbus/system_bus_socket</listen>
  <policy context="default">
    <allow user="*"/>
    <deny own="*"/>
    <deny send_type="method_call"/>
    <allow send_type="signal"/>
    <allow send_requested_reply="true" send_type="method_return"/>
    <allow send_requested_reply="true" send_type="error"/>
    <allow receive_type="method_call"/>
    <allow receive_type="method_return"/>
    <allow receive_type="error"/>
    <allow receive_type="signal"/>
    <allow send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus"/>
    <allow send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus.Introspectable"/>
    <allow send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus.Properties"/>
    <allow send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus.Containers1"/>
  </policy>
  <policy user="root">
    <allow send_destination="org.freedesktop.DBus" send_interface="org.freedesktop.DBus.Monitoring"/>
  </policy>
  <includedir>system.d</includedir>
</busconfig>
DBUSEOF
# bash 链接非宽 libtinfo.so.6/libncurses.so.6；ncurses 非宽构建产出 libncurses.so.6
# 放进 ld.so 默认搜索目录 /lib64，不依赖 ld.so.cache
for base in tinfo ncurses; do
    ln -sfn "/usr/lib/libncurses.so.6" "$STAGE2/lib64/lib${base}.so.6"
done
# 动态库搜索路径：util-linux/systemd 的库在 /usr/lib，生成 ld.so.cache
printf '/usr/lib\n/usr/lib64\n/lib64\n/usr/lib64/systemd\n' > "$STAGE2/etc/ld.so.conf"
ldconfig -r "$STAGE2" 2>/dev/null || true
[ -f "$STAGE2/etc/ld.so.cache" ] && echo "  ld.so.cache: OK"
# bash 为默认 shell 可用性检查
[ -x "$STAGE2/usr/bin/bash" ] && echo "  bash: OK"
[ -x "$STAGE2/usr/bin/ls" ] && echo "  coreutils: OK"
[ -x "$STAGE2/usr/lib/systemd/systemd" ] && echo "  systemd: OK"

echo ""
echo "======================"
echo " stage2 rootfs 构建完成: $STAGE2"
echo " root 密码: $ROOTPW"
echo "======================"
