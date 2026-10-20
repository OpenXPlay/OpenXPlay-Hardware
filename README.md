<p align="center"><b>English</b> · <a href="README-zh.md">简体中文</a></p>

# OpenXPlay-Hardware

Device support for running the OpenXPlay relay on specific hardware.

| Directory | Device |
| --- | --- |
| [`UFI003`](./UFI003) | UFI003 msm8916 4G USB dongle with the OpenStick Debian 11 image |

## Contributing

Contributions are accepted under the [Contributor License Agreement](./CLA.md). The CLA Assistant
check on each pull request records your acceptance.

## License

OpenXPlay-Hardware supports devices that run [OpenStick](https://github.com/OpenStick/OpenStick)
and follows its terms: fully open source, but commercial use is prohibited. It is licensed under
the [OpenXPlay-Hardware License 1.0](./LICENSE), which adds one condition: whoever distributes it
or a derivative must publish the complete source under the same license. Commercial use includes:

- selling any system image, package or bundle that contains these files, or any derivative of one;
- distributing build outputs for a fee;
- selling devices with these files installed, in batches or at scale.

Files taken from or built from the Linux kernel keep their original license, the
[GNU General Public License v2.0](./LICENSE-GPL-2.0) only; each device directory lists them.
Other software installed with these files, such as the OpenXPlay relay and Debian packages, keeps
its own license.
