# Barback

macOS 状态栏进程管理器 — 用 supervisor 的语义管理后台服务与常用命令。见 [需求文档](docs/requirements.md) 与 [设计文档](docs/design.md)。

## 构建与运行

```bash
make                             # 默认目标：构建 dist/Barback.app 和 dist/Barback.dmg
make build                       # 调试构建（开发用，产物在 .build/debug/BarbackApp）
make test                        # 运行全部测试（纯函数单测 + 进程集成测试）
make run                         # 直接运行调试构建（无 .app 包，系统通知不可用）
DEVELOPER_ID_APPLICATION="Developer ID Application: ..." make sign   # 签名 + 公证 dist/Barback.dmg
make clean                       # 删除 .build 与 dist
```

打包产物统一放在仓库根目录的 `dist/`（已加入 `.gitignore`，不提交）；`.build/` 只是 SwiftPM 的中间构建缓存。

## 代码结构

- `Sources/BarbackCore`：无 UI 依赖的监管内核（状态机、进程管理、SQLite 存储、日志轮转、supervisor 导入）。可脱离 App 单独测试。
- `Sources/BarbackApp`：AppKit + SwiftUI 界面层（状态栏双菜单、配置窗口、日志查看器、执行历史、事件日志、偏好设置）。
- `Sources/CSQLite`：系统 libsqlite3 的 modulemap shim。
- `Fixtures/testchild`：可控行为的测试子进程，供进程管理集成测试使用。
- `Tests/{CoreTests,ProcessTests,IntegrationTests}`：分别对应纯函数单测、真实进程集成测试、崩溃恢复等端到端场景。

## 已知限制（v1.0）

- 未打包为 `.app` 时运行会跳过系统通知（`UNUserNotificationCenter` 需要真实 bundle identity）。
- 详见设计文档 §9 未决问题（日志轮转默认策略、一次性命令参数化输入、签名分发方式）。
