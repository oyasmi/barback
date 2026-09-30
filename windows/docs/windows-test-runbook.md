# Windows 实机验证操作手册

本手册用于补齐 [验收矩阵](validation.md)，不是已通过的证明。使用专属测试目录和持有句柄，禁止按进程名批量结束 Node/Python/dotnet。

## 自动化

1. 使用 Windows 11 普通用户，记录版本、补丁、架构、默认终端和构建版本：`./scripts/record-environment.ps1`。
2. 执行 `./scripts/build.ps1` 和 `./scripts/test.ps1`。后者发布同架构 fixtures，设置仅本次进程有效的路径，finally 恢复环境变量。
3. 归档 `TestResults/<architecture>/*.trx`、环境文件和失败用例目录。每个进程用例在独立 Job 内执行；创建时崩溃探针只结束本次创建的 supervisor 测试进程。
4. ARM64 必须在 ARM64 机器原生重复；x64 runner 的交叉构建只说明能生成代码。

## M0 必须先取得的证据

- Job：分别验证 suspended、恢复线程后、主进程先退出、有多层后代和嵌套父 Job；记录 PID + 创建时间。重复 100 次并确认整树退出。拒绝 breakaway 或嵌套失败时不得降级无 Job。
- 控制台：把默认终端分别设为 Windows Terminal、Windows Console Host，录制启动/停止过程，确认无闪窗。并行运行两个目标，停止一项只使该项目收到 Ctrl+Break；测试 Node、Python、dotnet 与 PowerShell 实际目标的清理处理。
- MSIX：使用匹配 Publisher 的受信任测试签名，验证安装、开始菜单、通知点击、任务管理器禁用登录项、LocalState 实际位置及卸载；对 Node/Python/dotnet/PowerShell 用户配置和缓存路径留证据。不得把开发目录运行等同于签名包运行。
- 桌面：Narrator、高对比度、中文输入、200% DPI、双屏混合 DPI、Explorer 重启和显示器拔出。检查焦点、关闭草稿和保存栏可达。

## 手工用户路径

首次启动创建服务 → 启动 → 查看两个流 → 停止 → 重启 → 关闭驻留 → 从开始菜单重开。添加一次性命令，覆盖成功、失败、超时、取消、崩溃中断后人工重跑。编辑时保留空行和非法环境草稿；测试保存失败、保存并重启的先保存次序、禁用仍运行的任务、复制、删除和 INI 重名处理。

托盘右键、单击快捷面板、双击主窗口、Esc、失焦、Shift+F10、Ctrl+N/Ctrl+Shift+N/Ctrl+S/Ctrl+F/Ctrl+D/Delete/Enter/Alt+F4 均须实际检查。列表 Enter 只编辑，不执行任务。

注入数据库写锁/磁盘满后，已有任务的停止必须仍能及时接受。注入日志写失败后目标继续输出，内存保持有界，缺口可见；恢复后 `.gaps` 累计丢弃量正确。验证业务输出不会进入默认诊断包，DPAPI 换账户无法解密时配置禁用并可重新输入。

## 发布

普通 PR 作业不接触签名私钥。完成 M0 和全部 W 用例后，按架构签名并验证包；记录 SHA-256、包身份、依赖清单、SQLite/schema 版本和 SBOM。检查干净机器安装、从上一版升级、迁移失败、旧版拒绝高 schema、备份恢复、卸载和长期运行预算。

填写 [开发验证记录](implementation-status.md) 中每项的“通过/失败/阻塞”、环境、日期和证据路径。缺少证据时保留阻塞状态。
