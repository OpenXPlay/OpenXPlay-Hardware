<!--
SPDX-FileCopyrightText: 2026 OpenXPlay.org
SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
Created by riko chen on 2026-10-21
-->
<p align="center"><a href="README.md">English</a> · <b>简体中文</b></p>

# PhicommN1

斐讯 N1 电视盒子（晶晨 S905D）的支持文件，适用于从 eMMC 运行 ophub Armbian（Debian 13，内核 6.12）的设备。

`package/` 构建设备包，以及 OpenXPlay Flasher 通过网络 SSH 安装的离线设备整合包。设备包安装主机配置，把以太网 PHY 的 ID 写入启动设备树（内核更新后会重新写入），并给 wlan0 和蓝牙控制器换成由出厂以太网 MAC 推导的地址。它还为板载 BCM43455 安装较新的 Cypress Wi-Fi 固件，使 wlan0 在 CN 监管域下可以使用 5 GHz 信道 36-48。

```sh
sh package/build-deb.sh --firmware /path/to/firmware out
sh package/build-bundle.sh --version 0.1.0 --firmware /path/to/firmware /path/to/debs out
```

构建需要 Linux 上的 `dpkg-deb`，或已缓存的 `debian:trixie` Docker 镜像。将 `install/debs.txt` 固定版本的 Debian 包放到 `/path/to/debs`，支持 `arm64` 和 `all`。将 `install/firmware.txt` 固定的未修改固件和许可证文件按上游文件名放到 `/path/to/firmware`。Debian 清单列出全新 ophub Debian 13 服务器镜像缺少、而设备包和中继包需要的软件包，因此整合包可以离线安装。构建会校验所有固件哈希；构建和安装脚本均不下载文件。`--sources DIR` 可带入本地 Debian 源码归档，`SOURCES.txt` 记录源码位置和固件来源。

## 许可证

本目录文件采用 [OpenXPlay-Hardware License](../LICENSE)。打包的 Cypress 固件采用 LICENCE.cypress，许可证全文包含在设备包中。
