<!--
SPDX-FileCopyrightText: 2026 OpenXPlay.org
SPDX-License-Identifier: LicenseRef-OpenXPlay-Hardware-1.0
Created by riko chen on 2026-10-21
-->
<p align="center"><a href="README.md">English</a> · <b>简体中文</b></p>

# PhicommN1

斐讯 N1 电视盒子（晶晨 S905D）的支持文件，适用于从 eMMC 运行 ophub Armbian（Debian 13，内核 6.12）的设备。

`package/` 构建设备包（主机配置）以及 OpenXPlay Flasher 通过网络 SSH 安装的离线设备整合包：

```sh
sh package/build-deb.sh out
sh package/build-bundle.sh --version 0.1.0 /path/to/debs out
```

构建需要 Linux 上的 `dpkg-deb`，或已缓存的 `debian:trixie` Docker 镜像。将 `install/debs.txt` 固定版本的 Debian 包放到 `/path/to/debs`，支持 `arm64` 和 `all`。清单列出全新 ophub Debian 13 服务器镜像缺少、而设备包和中继包需要的软件包，因此整合包可以离线安装。构建和安装脚本均不下载软件包。`--sources DIR` 可带入本地 Debian 源码归档，`SOURCES.txt` 记录对应源码位置。

## 许可证

本目录全部内容与本仓库其余部分一样采用 [OpenXPlay-Hardware License](../LICENSE)。
