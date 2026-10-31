# 包管理双引擎: deep + apt

Cloud LTE OS 现在有**两个包管理器**:

| 管理器 | 管理什么 | 用法 |
|--------|---------|------|
| **deep** | 原生静态包 (轻量) | deep install htop |
| **apt** | Ubuntu 生态 (完整) | apt install curl |

## 安装 apt

Hit:1 http://mirrors.ustc.edu.cn/ubuntu noble InRelease
Hit:2 http://mirrors.ustc.edu.cn/ubuntu noble-updates InRelease
Hit:3 http://mirrors.ustc.edu.cn/ubuntu noble-backports InRelease
Hit:4 http://mirrors.ustc.edu.cn/ubuntu noble-security InRelease
Reading package lists...
Building dependency tree...
Reading state information...
114 packages can be upgraded. Run 'apt list --upgradable' to see them.
Reading package lists...
Building dependency tree...
Reading state information...
curl is already the newest version (8.5.0-2ubuntu10.13).
0 upgraded, 0 newly installed, 0 to remove and 114 not upgraded.

## 文件

- ubuntu-rootfs.tar.gz — Ubuntu 24.04 noble minbase x86_64 (40MB)
- apt — apt 命令封装 (自动 chroot 挂载/卸载)
- install-apt.sh — 一键安装

## 历史踩坑

- v8.2 前 dpkg 损坏导致 apt 不可用 → 用独立 chroot 彻底隔离
- minbase 无证书 → 先 http 装 ca-certificates 再换 https
