# ADR（草案）：MSIX 下目标进程的文件/注册表写虚拟化

状态：**调研未完成，无结论**。本文只固定要回答的问题、探测步骤和候选方案；在签名 MSIX 的 Windows 实机上取得证据之前，不得据此修改运行行为，也不得把候选方案当作已验证事实。来源：[评审修正方案](review-fix-plan.md) F16。

## 背景

[总体设计 §9.2](design.md) 把“MSIX 虚拟化影响开发工具”列为 M0 风险。从打包应用启动的子进程可能继承包运行环境：npm、pip、dotnet 等写入 `%APPDATA%` 或 HKCU 的内容可能被重定向到包私有位置，卸载时随包删除，包外工具也看不到。清单目前声明了 `desktop6` 命名空间但没有使用。

## 探测步骤（需要受信任测试签名的 MSIX，普通用户）

1. 通过 Barback 启动并分别记录以下命令写入的**真实落点**（真实路径，还是 `%LOCALAPPDATA%\Packages\<PFN>\LocalCache\…` 之类的包私有位置；注册表同理）：
   - `cmd /c echo x > %APPDATA%\barback-probe.txt`
   - `reg add HKCU\Software\BarbackProbe /v probe /d 1`
   - `npm config set` 与 `npm install -g`（用户级前缀）
   - `pip install --user`
   - `dotnet tool install -g`
2. 在包外（资源管理器、未打包的终端）确认这些落点是否可见；卸载包后确认是否被删除。
3. 对照非打包的开发目录版本（`%LOCALAPPDATA%\Barback\Dev`）重复，记录差异。

## 候选方案（每项采用前必须从微软官方文档核实最低系统版本与语义）

- 清单中把文件系统/注册表写虚拟化设为 disabled（清单元素、所需的受限能力和最低 Windows 版本需核实）。
- 创建目标进程时通过进程创建属性让目标脱离包运行环境（需核实与 `PROC_THREAD_ATTRIBUTE_JOB_LIST` 共存，以及 Job 树清理是否受影响）。
- 设计 §9.2 已预留的退路：评估按用户安装的传统安装包。

## 决定

待定。结论、证据路径和对 design.md §9.2 / §11 的修订在探测完成后写入本文。
