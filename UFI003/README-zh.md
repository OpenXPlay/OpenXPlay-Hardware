<p align="center"><a href="README.md">English</a> · <b>简体中文</b></p>

# UFI003

UFI003 msm8916 4G USB 随身 Wi-Fi 的支持文件：在 OpenStick Debian 11 镜像（内核 `5.15.0-handsomekernel+`，aarch64）上将其用作 OpenXPlay 中继。

## rfcomm

该镜像的内核以模块形式提供蓝牙，但缺少 RFCOMM，因此 BlueZ 无法提供无线 CarPlay 所需的 iAP2 profile（`RFCOMM server failed … Protocol not supported`）。`rfcomm/rfcomm.ko` 是未经修改的 Linux v5.15 中的 RFCOMM，使用设备的内核配置和符号表构建。

在设备上安装：

```sh
install -D -m 0644 rfcomm.ko /lib/modules/5.15.0-handsomekernel+/extra/rfcomm.ko
depmod -a
echo rfcomm > /etc/modules-load.d/openxplay-rfcomm.conf
modprobe rfcomm
systemctl restart bluetooth
```

重新构建：`rfcomm/build.sh <linux-5.15.tar.xz>`（需要能运行 linux/arm64 镜像的 Docker）。`SHA256SUMS` 列出模块和各构建输入。

## btqcomsmd

该镜像的 WCNSS 蓝牙驱动在开机后经常让 `hci0` 处于 DOWN 状态，地址为 00:00:00:00:00:00：5.15 蓝牙核心中存在竞态，驱动刚设置完 BD 地址，控制器的命令额度（command credit）就会丢失，导致第一条 HCI Reset 始终发不出去。`btqcomsmd/btqcomsmd.ko` 是未经修改的 v5.15 驱动加上上游提交 5d44ab9e2042（"Bluetooth: btqcomsmd: Fix command timeout after setting BD address"），构建方式与 `rfcomm` 相同。安装程序会把它放到 `updates/`，从下次开机起替换内核自带的（in-tree）模块：

```sh
install -D -m 0644 btqcomsmd.ko /lib/modules/5.15.0-handsomekernel+/updates/btqcomsmd.ko
depmod -a
```

`btqcomsmd/src/btqcomsmd.c` 是未经修改的 v5.15 驱动源码。重新构建：`btqcomsmd/build.sh <linux-5.15.tar.xz>`；脚本会检查该源码与源码包一致，并检查未修改的驱动与设备上的驱动一致（srcversion）。`SHA256SUMS` 列出模块、源码和补丁。

## bluetooth

`bluetooth/bt-guard.sh` 由 `openxplay-bt-guard.service` 运行，负责监视控制器，出现故障时重新加载驱动，并把状态写入 `/run/openxplay/bluetooth-guard.json`。

在这款控制器上，iPhone 只有在 Secure Connections 关闭时才能配对（否则报 `Simple Pairing Complete: Authentication Failure`），而已绑定的 iPhone 只有在它开启时才能重新连接。该设置由中继负责：平时开启，只在中继的配对窗口打开期间关闭。守护程序不改动它。早期版本通过 `/etc/systemd/system/bluetooth.service.d/openxplay-no-secure-connections.conf` 强制关闭它；安装程序会删除这个 drop-in。

## 一键安装程序

请严格使用 `install/debs.txt` 中已记录的 bullseye 软件包版本和 SHA-256 值。在 Mac 上组装本地构建产物（需要 POSIX sh，以及 `sha256sum` 或 `shasum`）：

```sh
sh UFI003/install/make-bundle.sh /tmp/ufi003-bundle /path/to/openxplay-relay /path/to/oxp-relay /path/to/web/dist /path/to/admin/dist /path/to/debs /path/to/OpenXPlay-Relay/rust/packaging
```

把 `<output>.tar.gz` 复制到设备上，解压到一个空目录，然后以 root 身份运行（直接从 Mac 复制目录本身可能会带上 `._*` 文件，安装程序会拒绝这些文件）：

```sh
sh /path/to/ufi003-bundle/UFI003/install/install-ufi003.sh /path/to/ufi003-bundle
```

两个脚本都可以在参数前加 `--dry-run`：只做校验，不做任何改动。相同的安装包可以重复构建；若已有输出与本次不同，则保留已有输出并拒绝本次构建。安装程序在做任何改动之前会校验完整的安装包以及独立的 deb／模块摘要；跳过已安装的软件包版本；安装 RFCOMM、修复后的蓝牙驱动和蓝牙守护程序；删除早期版本的 Secure Connections drop-in；修复未绑定接口的系统 dnsmasq；在 `wlan0` 上关闭 Wi-Fi 省电和 NetworkManager 的扫描 MAC 随机化；并启用蓝牙和时间同步。Wi-Fi 策略对之后的连接生效，条件允许时立即应用。中继部署会调用中继的通用 GPL 安装程序，该程序必须支持 `DESTDIR`。安装包校验和只保证完整性，不保证真实性；请使用可信的传输渠道。

设备端除系统和软件包工具外，还会用到 POSIX sh、awk、sha256sum、find、sort、stat 和 date；不需要 Python 和 OpenSSL。清单必须把安装包中除自身以外的每个普通文件恰好列出一次，每项包含 64 个十六进制字符的摘要和安全的 `./relative/path`；内容由 `sha256sum -c` 校验。

每次启动中继前，时钟守护程序会启用并启动 systemd-timesyncd，最多三秒内返回成功，即使本地命令卡住也是如此。中继启动从不等待时间同步或互联网连接。中继生成的证书使用 rcgen 默认有效期（1975 年至 4096 年），因此设备时钟不准也不会缩短证书的有效范围。只有在 `timedatectl` 报告 `NTPSynchronized=yes` 之后，守护程序才会删除文件系统 mtime 晚于当前时间的已生成 TLS 文件：`admin-tls.json` 单独判断；`receiver-tls/cert.pem` 和 `key.pem` 只要有一个时间在未来，就两个一起删除。其他情况下不改动 TLS 状态，包括不完整的证书／密钥对。中继会重新生成被删除的 TLS 状态；浏览器可能需要重新信任。

安装包中不允许包含符号链接和 MFi 身份凭据。请另行把你自己的 `identity.pk8` 和 `certificate.p7b` 放到 `/var/lib/openxplay/mfi` 下，权限设为 `0600`，然后启动中继。已有的身份凭据会被保留；只有两个文件都存在时，安装过程才会重启中继。

进行伪根目录（fake-root）测试时，请使用绝对路径的 `DESTDIR`，并在 `PATH` 中放入命令桩（stub）：文件和软件包操作会被重定向，主机上的运行时操作会被屏蔽。运行 `sh UFI003/install/tests/run.sh` 执行临时根目录测试套件。

## 许可证

`bluetooth/` 与本仓库其余部分一样采用 AGPL-3.0-only。`rfcomm/` 和 `btqcomsmd/` 中的全部内容都属于 Linux 内核模块，沿用内核的许可证 [GPL-2.0-only](../LICENSE-GPL-2.0)，包括：模块本身、模块源码（Linux v5.15 `net/bluetooth/rfcomm`；`btqcomsmd` 为 Linux v5.15 `drivers/bluetooth/btqcomsmd.c` 及随附补丁）、设备的内核配置和 `Module.symvers`，以及控制模块编译的 `build.sh` 脚本。完整内核源码为 kernel.org 提供的 `linux-5.15.tar.xz`（SHA-256 `57b2cf6991910e3b67a1b3490022e8a0674b6965c74c12da1e99d138d1991ee8`）。
