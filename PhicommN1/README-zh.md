<!--
SPDX-FileCopyrightText: 2026 OpenXPlay.org
SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
Created by riko chen on 2026-10-21
-->
<p align="center"><a href="README.md">English</a> · <b>简体中文</b></p>

# PhicommN1

斐讯 N1 电视盒子（晶晨 S905D）的支持文件，适用于从 eMMC 运行 ophub Armbian（Debian 13，内核 6.12）的设备。

`package/` 构建设备包（主机配置和 USB 管理设备）及供 OpenXPlay Flasher 通过 SSH 安装的离线设备整合包：

```sh
sh package/build-deb.sh out
sh package/build-bundle.sh --version 0.1.0 /path/to/debs out
```

构建需要 Linux 上的 `dpkg-deb`，或已缓存的 `debian:trixie` Docker 镜像。将 `install/debs.txt` 固定版本的 Debian 包放到 `/path/to/debs`，支持 `arm64` 和 `all`。清单列出全新 ophub Debian 13 服务器镜像缺少、而设备包和中继包需要的软件包，因此整合包可以离线安装。构建和安装脚本均不下载软件包。`--sources DIR` 可带入本地 Debian 源码归档，`SOURCES.txt` 记录对应源码位置。

## usb-gadget

把靠近 HDMI 的 USB 口切换为 USB 设备，电脑通过 USB 双公头线即可管理盒子：

- CDC-NCM 网卡：盒子地址为 `192.168.201.1`；电脑通过 DHCP 获得 `192.168.201.2`-`.9` 中的地址，不下发网关和 DNS，电脑原有的默认路由保持不变。
- CDC-ACM 串口终端：`ttyGS0` 上的登录提示（macOS 上为 `/dev/cu.usbmodem*`，Windows 上为一个 COM 口）。

Windows 10/11、macOS 和 Linux 均无需安装驱动。服务运行期间，这个口不能再作为 USB 主机使用，另一个口不受影响。设备树中这个口没有可控的 VBUS，应假定盒子在这个口上输出 5V：请使用剪断 VBUS 的双公头线，或带 VBUS 隔离的转接头。

设备包会安装并启用它。如需手动安装，请以 root 执行（`dnsmasq-base` 提供 DHCP 服务）：

```sh
apt-get install --no-install-recommends dnsmasq-base
install -D -m 0755 usb-gadget.sh /usr/local/libexec/openxplay-usb-gadget
install -m 0644 openxplay-usb-gadget.service openxplay-usb-dhcp.service /etc/systemd/system/
install -D -m 0644 serial-getty-ttyGS0.conf /etc/systemd/system/serial-getty@ttyGS0.service.d/openxplay-usb-gadget.conf
systemctl daemon-reload
systemctl enable --now openxplay-usb-gadget.service
```

执行 `systemctl disable --now openxplay-usb-gadget.service` 可将这个口恢复为主机模式。

## 许可证

本目录全部内容与本仓库其余部分一样采用 [OpenXPlay-Hardware License](../LICENSE)。
