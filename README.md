# Barback

[English](README.en.md) · [Apache License 2.0](LICENSE)

Barback 是面向个人开发者的本机后台进程管理器，用于管理常驻服务和一次性命令，提供启停、自动重启、日志与执行历史。

| 平台 | 状态 | 入口 |
| --- | --- | --- |
| macOS | 已有实现，Swift 6 + AppKit / SwiftUI，macOS 13+ | [使用与构建](macos/README.md) · [设计](macos/docs/design.md) |
| Windows | C# + .NET 10 LTS + WPF；已完成 v0.3.2.0 x64 Release 构建并生成未签名 MSIX，正式发布仍需证书和实机验收 | [构建与验证](windows/README.md) · [总体设计](windows/docs/design.md) |

两端遵循相同的产品目标，分别采用平台原生技术。进程生命周期、停止方式、Shell、系统集成和交互按各平台特点设计，不承诺配置或行为完全对等。

```text
macos/       macOS 源码、资源、测试、脚本和原有文档
windows/     Windows .NET 源码、设计、测试、打包与验证记录
.github/     仓库级 CI（macOS 和 Windows 独立作业）
LICENSE      全仓库许可证
```

在 macOS 上构建：

```bash
git clone https://github.com/oyasmi/barback.git
cd barback/macos
make build
make test
make                      # 打包到 macos/dist/（相对仓库根目录）
```

根目录的 `make`、`make build`、`make test`、`make run`、`make sign`、`make clean` 会转发到 `macos/`，便于沿用原有开发习惯。直接运行 SwiftPM 命令前请先进入 `macos/`。Windows 的实施与验收计划见 [windows/docs/validation.md](windows/docs/validation.md)。

在 Windows 上构建、测试和打包：

```powershell
cd windows
./scripts/build.ps1 -Architecture x64 -Configuration Release
./scripts/test.ps1
./scripts/package.ps1 -Architecture x64 -Version 0.3.2.0
```

默认生成的 x64 MSIX 位于 `windows/dist/Barback-0.3.2.0-x64.msix`，当前约 15.7 MB；它依赖目标机器已安装 .NET 10 Desktop Runtime。未传证书时为未签名构建产物；正式发布还需要签名和 Windows 实机验收。需要独立携带 .NET 运行时时，可给打包脚本加 `-SelfContained`，包体积会明显增大。
