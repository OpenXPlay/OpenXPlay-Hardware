<!--
SPDX-FileCopyrightText: 2026 OpenXPlay.org
SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
Created by riko chen on 2026-10-21
-->
<p align="center"><a href="README.md">English</a> · <b>简体中文</b></p>

# PhicommN1

斐讯 N1 电视盒子（晶晨 S905D）的支持文件，适用于从 eMMC 运行 ophub Armbian（Debian 13，内核 6.12）的设备。

## 安装

从写入 Armbian 到打开 CarPlay 的分步教程见 [openxplay.org/phicomm-n1](https://openxplay.org/phicomm-n1)（英文：[openxplay.org/en/phicomm-n1](https://openxplay.org/en/phicomm-n1)）。

发布版的标签为 `phicomm-n1-device-vX.Y.Z[-beta.N]`，附带整合包 `openxplay-phicomm-n1-device-<版本>.tar.gz` 和 `SHA256SUMS`。在 N1 上解压整合包，以 root 身份运行其中的安装程序，不需要联网。解压出的文件夹名使用 Debian 版本号，例如 `0.1.1~beta.1`：

```sh
sudo sh openxplay-phicomm-n1-device-<版本>/install-device.sh --dry-run   # 只做检查
sudo sh openxplay-phicomm-n1-device-<版本>/install-device.sh
sudo reboot
sudo sh openxplay-phicomm-n1-device-<版本>/install-device.sh --verify
```

安装程序只接受设备树型号为 `Phicomm N1` 的 Debian 13 arm64 系统（否则以 2 退出），按 `SHA256SUMS` 校验每个文件，然后按顺序安装固定版本的 Debian 软件包，最后安装 `openxplay-phicomm-n1`；已装同版本或更新版本的软件包会跳过。最后一行输出 `OXP-STAGE device preflight-ok`、`ok … reboot=required` 或 `verified`，并带有版本号。之后用 `.deb` 安装中继（`OpenXPlay/OpenXPlay-Relay`，标签 `linux-v…`），它的依赖已包含在整合包中。

`apt-get remove openxplay-phicomm-n1` 会还原原来的启动设备树，Wi-Fi 和蓝牙地址在下次开机时恢复为共用的默认值；`purge` 还会删除 `/var/lib/openxplay-phicomm-n1`。

## 构建

`package/` 构建设备包和离线设备整合包，由上面的安装程序或 OpenXPlay Flasher（通过网络 SSH）安装。设备包安装主机配置，把以太网 PHY 的 ID 写入启动设备树（内核更新后会重新写入），并给 wlan0 和蓝牙控制器换成由出厂以太网 MAC 推导的地址。它还为板载 BCM43455 安装较新的 Cypress Wi-Fi 固件，使 wlan0 在 CN 监管域下可以使用 5 GHz 信道 36-48。

```sh
sh package/build-deb.sh --firmware /path/to/firmware out
sh package/build-bundle.sh --version 0.1.0 --firmware /path/to/firmware /path/to/debs out
```

构建需要 Linux 上的 `dpkg-deb`，或已缓存的 `debian:trixie` Docker 镜像。将 `install/debs.txt` 固定版本的 Debian 包放到 `/path/to/debs`，支持 `arm64` 和 `all`。将 `install/firmware.txt` 固定的未修改固件和许可证文件按上游文件名放到 `/path/to/firmware`。Debian 清单列出全新 ophub Debian 13 服务器镜像缺少、而设备包和中继包需要的软件包，因此整合包可以离线安装。构建会校验所有固件哈希；构建和安装脚本均不下载文件。`--sources DIR` 可带入本地 Debian 源码归档，`SOURCES.txt` 记录源码位置和固件来源。

## 许可证

本目录文件采用 [OpenXPlay-Hardware License](../LICENSE)。打包的 Cypress 固件采用 LICENCE.cypress，许可证全文包含在设备包中。
