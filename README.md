# Barback

[![License: Apache 2.0](https://img.shields.io/badge/license-Apache%202.0-blue.svg)](LICENSE)
![Platform](https://img.shields.io/badge/platform-macOS%2013%2B%20(Apple%20Silicon)-lightgrey)
![Swift](https://img.shields.io/badge/Swift-6-orange)

> 常驻状态栏的 App，帮你看住 Mac 上跑着的后台程序：挂了自动重启，状态一眼看清，重启和看日志两次点击搞定。

中文 · [English](README.en.md)

Barback 是一个常驻状态栏的进程管理器：把你长年跑在 Mac 上的本地服务、隧道、模型推理、同步守护进程交给它看着，挂了自动重启，状态一眼可见，重启和看日志各只要两次点击。名字取自吧台助理（barback），也双关 macOS 的 **Menu Bar**。

- **单进程**——没有守护进程、没有 IPC、没有要手工编辑的配置文件。Barback 退出，被管进程一并退出。
- **零第三方依赖**——Swift 6 + AppKit/SwiftUI，产物约 1 MB。
- **空闲零开销**——进程退出靠 kqueue 事件而非轮询；CPU/内存采样只在面板打开时进行。

## 功能

**服务**（长期运行，监管语义与 supervisor 同名同义）

- `autostart` 开机自启、`autorestart`（never / unexpected / always）自动重启
- `startSeconds` 存活门槛、`startRetries` 重试上限、指数退避、重启风暴保护（进入 `FATAL` 停止重试）
- 停止序列可配：`stopSignal` / `stopWaitSeconds` / `stopAsGroup` / `killAsGroup`，超时自动升级为 `SIGKILL`
- 崩溃接管：Barback 自身被 `kill -9` 后重启，能认领仍在运行的子进程（校验 PID + 进程启动时间，防 PID 复用误认）
- 睡眠唤醒后核对进程真实存活状态

**一次性命令**（手动触发、跑完即止）

- 超时终止、危险命令运行前确认
- 每次执行留存输出与记录（时间 / 耗时 / 退出码 / 结果），按条数上限自动清理

**其余**

- 子进程 stdout/stderr 直接落盘（不经过 Barback 主程序），按大小轮转；内置日志查看器支持跟随末尾与关键字过滤
- 从 supervisor 迁移：粘贴 `[program:x]` INI 文本，预览字段映射后逐条导入
- 事件日志与系统通知（服务失败、非预期重启、命令执行完成），通知带去抖窗口
- 开机自启（`SMAppService` 登录项）

## 状态栏面板

左键是全 App 使用频率最高的界面，所以日常动作全部落在行上，没有二级菜单：

```
┌─ 左键面板 ─────────────────────────────────────────────────┐
│ ●1 运行中  ○2 已停止  ⚠1 失败  ◌1 执行中              ⚙  │
│ 🔍 搜索程序                                （> 8 项时出现）│
├────────────────────────────────────────────────────────────┤
│ 服务 4                                                     │
│ ▎● nslocal        运行中           [■ 停止] [↻] [📄] [⌄]  │
│    PID 4821 · up 2d3h · CPU 0.3% · 48.0 MB                 │
│ ▎◑ api-server     重试 2/3         [■ 停止] [↻] [📄] [⌄]  │
│    12 秒后重试 · 上次退出 今天 22:26 · 退出码 1            │
│    ▁▁▁▁▁▁▁▁▃▃▃▃▃▃▃▃▃▃▃▃                                   │
│ ▎⚠ tunnel         启动失败         [▶ 启动] [↻] [📄] [⌄]  │
│    已重试 3 次 · 上次退出 今天 22:21 · 退出码 127          │
│    ⚠ 自动重试已停止，需要人工处理            清除状态      │
│ 一次性命令 1                                               │
│ ▎✓ backup-db      成功             [▶ 运行] [📄] [🕑] [⌄]  │
│    上次 今天 20:27 · 耗时 3.4 秒 · 共 27 次                │
├────────────────────────────────────────────────────────────┤
│ [▶ 全部启动]   [■ 全部停止]   [↻ 全部重启]                 │
└────────────────────────────────────────────────────────────┘
```

- 主按钮随状态切换：运行中给「停止」、已停止给「启动」、停止中给「强制终止」（带确认）。
- 点行任意处展开抽屉，可见命令、工作目录、日志路径、配置摘要，以及「在 Finder 中显示」「复制 PID」「编辑配置」。
- 次级按钮（重启 / 日志 / 历史 / 展开）在指针悬停或键盘选中时才显现，静息态只剩状态脊、名称、徽标与一行指标。
- 状态同时用形状、文字与颜色表达，不单靠颜色；异常态给出可直接点击的补救动作。
- **右键**（或 Control + 左键）是 Barback 自身的功能菜单：配置窗口、执行历史、事件日志、偏好设置、粘贴导入、退出——与左键面板内容完全不重叠。

## 安装

要求 **macOS 13+ · Apple Silicon**（`ARCHS="arm64 x86_64" Scripts/build.sh` 可构建 Universal 2）、Xcode 命令行工具（Swift 6）。

```bash
git clone https://github.com/oyasmi/barback.git && cd barback
make                             # 构建 dist/Barback.app 与 dist/Barback.dmg
cp -R dist/Barback.app /Applications/
```

自行构建的包未签名，首次打开会被 Gatekeeper 拦下：在 Finder 中右键 →「打开」→「打开」即可。若有 Developer ID：

```bash
DEVELOPER_ID_APPLICATION="Developer ID Application: ..." make sign   # 签名 + 公证
```

首次启动会引导注册开机自启与通知权限，并提示添加第一个程序。Barback 是 `LSUIElement` 应用——没有 Dock 图标，没有主窗口，只有状态栏图标。

## 使用

| 想做的事 | 路径 |
| --- | --- |
| 启停 / 重启某个服务 | 左键图标 → 行上的主按钮 |
| 看某个程序的日志 | 左键图标 → 行上的 📄 |
| 看 PID / 运行时长 / CPU / 内存 | 左键图标，指标就在行上（每次打开时采样，不常驻轮询） |
| 看命令、工作目录、日志路径 | 左键图标 → 点行展开抽屉 |
| 键盘操作面板 | ↑↓ 选择 · ↩ 展开详情 · ⌘↩ 执行该行主动作 · Esc 关闭；程序超过 8 项时搜索框自动聚焦 |
| 增删改程序 | 右键图标 →「打开配置窗口」（⌘,） |
| 从 supervisor 迁移 | 右键图标 →「从 supervisor 粘贴导入」 |

### 从 supervisor 迁移

粘贴一段或多段 `[program:name]` INI 文本，Barback 解析后展示映射预览（可导入字段 / 无法映射字段及原因），勾选后导入。同名字段同义：

| supervisor | Barback | 说明 |
| --- | --- | --- |
| `command` | `command` | 含 `sh -c` 前缀时自动转为 `use_shell` |
| `autostart` | `autostart` | **导入时一律强制 false**，避免与仍在跑的 supervisord 抢端口 |
| `autorestart` | `autorestart` | `true→always` / `false→never` / `unexpected→unexpected` |
| `exitcodes` `startsecs` `startretries` | 同名 | — |
| `stopsignal` `stopwaitsecs` `stopasgroup` `killasgroup` | 同名 | — |
| `stdout_logfile` `stderr_logfile` `redirect_stderr` | `log_path` `log_stderr_path` `log_merge_stderr` | `AUTO`/`NONE` 转默认路径/丢弃 |
| `user` `numprocs` `process_name` `umask` … | — | 列入"无法映射"并说明原因 |

导入是非破坏性的：不读写任何 supervisor 文件。导入完成后先 `supervisorctl stop all` 并停用 supervisord，再在 Barback 中启动。

## 数据与文件

| 位置 | 内容 |
| --- | --- |
| `~/Library/Application Support/Barback/barback.db` | 配置、运行记录、事件（SQLite，仅通过 GUI 修改） |
| `~/Library/Application Support/Barback/backups/` | 配置自动备份 |
| `~/Library/Logs/Barback/programs/` | 服务日志（按大小轮转） |
| `~/Library/Logs/Barback/runs/` | 一次性命令每次执行的输出 |
| `~/Library/Logs/Barback/barback.log` | Barback 自身日志 |

## 从源码构建

```bash
make                             # 默认目标：构建 dist/Barback.app 和 dist/Barback.dmg
make build                       # 调试构建（产物在 .build/debug/BarbackApp）
make test                        # 全部测试（纯函数单测 + 真实进程集成测试）
make run                         # 直接运行调试构建（无 .app 包，系统通知不可用）
make clean                       # 删除 .build 与 dist
```

打包产物统一放在 `dist/`（已 `.gitignore`）；`.build/` 只是 SwiftPM 的构建缓存。

### 代码结构

```
Sources/BarbackCore    监管内核，无 UI 依赖：状态机、编排（Supervisor）、进程管理、SQLite 存储、日志轮转、supervisor 导入
Sources/BarbackApp     界面层：状态栏左键面板与右键菜单、配置窗口、日志查看器、执行历史、事件日志、偏好设置
Sources/CSQLite        系统 libsqlite3 的 modulemap shim
Fixtures/testchild     行为可控的测试子进程，供进程管理集成测试使用
Tests/                 CoreTests 纯函数单测 · ProcessTests 真实进程 · IntegrationTests 驱动真实 Supervisor 的端到端场景（启停、删除中途、崩溃接管）
```

核心层运行在单一串行队列上、不 import AppKit/SwiftUI，状态变更后向主线程发布不可变快照——因此状态机与编排层都可以脱离 UI 做穷举测试。

## 已知限制

- 未打包为 `.app` 时运行（如 `make run`）会跳过系统通知：`UNUserNotificationCenter` 需要真实的 bundle identity。
- 不支持 root / 系统级服务、远程管理、定时任务（那是 launchd 的地盘）、需要 TTY 输入的交互式进程。
- 不提供命令行客户端：单进程架构下需要额外 IPC。
- 更多未决问题见[设计文档](docs/design.md) §9。

## 文档

- [需求文档](docs/requirements.md)——定位、范围、用户路径、逐条需求
- [设计文档](docs/design.md)——架构、状态机、数据模型、GUI、打包与测试策略

## 许可证

[Apache License 2.0](LICENSE) © 2026 oyasmi
