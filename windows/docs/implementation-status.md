# Windows 开发验证记录

日期：2026-09-30。初始验证环境：Linux x86_64；.NET SDK 10.0.401。随后补充 Windows 10 x64 兼容验证，见下节。当前交付仍是首版开发候选源码，**不是 Windows 发布验收通过的版本**。四项 M0 关卡尚未取得完整证据，签名安装、ARM64 实机和长期运行仍待验证，M4 不通过。

## Windows 10 兼容验证

2026-09-30，在 Windows 10 专业版 22H2（`10.0.19045`）、x64、普通用户会话、.NET SDK `10.0.401` 上验证：

- 将启动检查及 MSIX `MinVersion` 从 Windows 11（22000）统一为 Windows 10 2004（19041），保持现有 `net10.0-windows10.0.19041.0` API 基线。Windows 10 19041 以下仍明确拒绝。
- `./scripts/build.ps1` 与 `./scripts/build.ps1 -Architecture arm64` 均通过，0 警告、0 错误。ARM64 仅为交叉构建，未实机运行。
- `./scripts/test.ps1`：Core 51、Storage 13、Windows 12，共 76 通过，0 失败、0 跳过。Windows 用例实际覆盖 Job 树清理、定向 Ctrl+Break、挂起/运行阶段宿主崩溃、DWORD 退出码、中文/空参数和双流输出。
- 实机暴露并修复测试基础设施问题：临时 SQLite 检查连接禁用池化，关闭后释放 Windows 文件句柄；进程退出测试最多等待五秒，逐一核对整个树的 PID + 创建时间，避免根已退出但后代退出状态尚未稳定时立即断言。
- 已重新发布 `artifacts/dev/x64/` 的自包含 App / ConsoleHost，使用 Windows 应用窗口接口观察到正常中文主窗口、程序列表和“0 运行中 · 0 停止 / 清理中”，原 Windows 11 拒绝提示消失。未取得可用截图，未验证可视布局、托盘操作或完整编辑/启停 UI 路径。
- 使用已锁定的 `Microsoft.Windows.SDK.BuildTools` 中 `makeappx.exe` 验证清单并成功生成 x64 未签名 MSIX；读取包内清单确认 `MinVersion=10.0.19041.0`，App 与 ConsoleHost 均已包含。该包使用开发构建，只作为打包验证证据，不表示签名安装已验证。

本地证据（不提交源码）：`TestResults/x64/{Core,Storage,Windows}.trx`；`artifacts/evidence/win10-compatibility/` 下的系统/补丁记录、主窗口可访问性记录、未签名 MSIX、打包日志及包内最低版本/内容/SHA-256 记录。最低版本 19041、LTSC 2021、Windows 11 回归、ARM64 原生运行，以及签名 MSIX 的安装/升级/通知/登录项仍需按[实机操作手册](windows-test-runbook.md)补齐；以下 W01–W40 的完整验收状态仍保留待验收，不能将上述部分自动化覆盖等同于通过全部场景。

## Windows 工作台实现验证

2026-09-30，沿用上述 Windows 10 x64 环境完成工作台替换：

- 原生 WPF Fluent 外壳；程序/活动与侧栏设置；状态主动作、上下文菜单、分组/类型/需要处理筛选；并排列表与详情和窄窗钻取。
- 内嵌日志、受保护的内嵌编辑草稿、固定保存栏；只读执行历史与明确的当前配置重跑；托盘复用状态动作规则；浅/深色/系统主题与高对比颜色分支。
- `scripts/test.ps1`：Core 64、Storage 13、Windows 12，共 89 通过，0 失败、0 跳过。新增动作规则、禁用仍持有 Run、停止/清理优先级、历史重跑、元数据变化与不可变运行配置快照的回归。
- `scripts/test-ui.ps1 -Configuration Release`：28 项真实 WPF 控件与 Dispatcher 回归通过，使用隔离 SQLite 和模拟宿主；未执行用户命令。检查状态刷新保留选择、缺失 stderr 与无 Run 清空旧日志、失败原因、待生效提示、历史操作归属、最小窗口保存栏、托盘状态按钮等。
- 检查 9 张真实控件 PNG：主工作台浅/深色、失败详情、窄窗列表/详情、活动、设置、窄窗编辑器、托盘。原生验证发现并修复分组 CollectionView 延迟刷新异常与 Fluent 主题重复初始化问题。
- 完整解决方案 x64 / ARM64 Release 构建通过，0 警告、0 错误；中英 278 个唯一资源键一致，字面量界面资源引用均存在。

本地证据：`TestResults/x64/{Core,Storage,Windows}.trx`；`artifacts/ui-check/20260930-170803/{checks.txt,*.png}`。未完成混合 DPI、Narrator、系统高对比交互、Explorer 重启、Windows 11、ARM64 原生和签名 MSIX 验收，发布状态保持开发候选。界面设计与历史快照边界见 [工作台说明](ui-redesign.md)。

## 初始 Linux 验证记录

- 核心测试：51 通过，0 失败（含取消退出、立即强制清理、失败清理重试）。
- 存储测试：13 通过，0 失败（含 schema 1→2 备份迁移）。敏感值测试使用测试保护器，不能替代 Windows DPAPI 实测。
- Windows 项目的协议测试：2 通过；6 个 Windows 进程测试入口因非 Windows 明确跳过，参数化用例留待 Windows 展开执行。
- 全解决方案及 WPF/C# x64、ARM64 源码编译检查：0 警告、0 错误。Linux 编译检查显式关闭 `WindowsAppSDKSelfContained` 和 `AppxGeneratePriEnabled`；这仅用于检查托管代码，不生成可验证的自包含 Windows 发行包。
- 锁定依赖恢复已检查 x64/ARM64；SQLite 原生依赖显式固定为 `SQLitePCLRaw.bundle_e_sqlite3` 2.1.13，避免默认旧包的已知漏洞。依据：[GitHub 漏洞公告](https://github.com/advisories/GHSA-2m69-gcr7-jv3q)。

本地 TRX 由以下命令生成，位于各测试项目 `TestResults/`，构建产物和运行结果不提交源码。已将迁入 macos/ 的 75 个原有实现、测试、资源和脚本文件逐字节与 HEAD 对比，均无改动：

```bash
dotnet test tests/Barback.Core.Tests -c Release --logger 'trx;LogFileName=core.trx'
dotnet test tests/Barback.Storage.Tests -c Release --logger 'trx;LogFileName=storage.trx'
dotnet test tests/Barback.Windows.Tests -c Release --logger 'trx;LogFileName=windows.trx'
dotnet build Barback.sln -c Release -p:WindowsAppSDKSelfContained=false -p:AppxGeneratePriEnabled=false
dotnet build Barback.sln -c Release -p:Platform=ARM64 -p:WindowsAppSDKSelfContained=false -p:AppxGeneratePriEnabled=false
```

五个 PowerShell 脚本已通过 PowerShell 7.5.3 语法解析；中英资源均为 130 个唯一键且键集一致。Windows CI 和 PowerShell 发布/测试脚本已加入；初始 Linux 验证没有运行 GitHub Actions、Windows SDK 打包工具或签名安装，后续 Windows 10 构建/测试见上节。真实测试步骤见 [实机操作手册](windows-test-runbook.md)。

## 实现范围与仍需完成的产品核对

实现包含纯 reducer、独立串行监管/存储执行器、每 Run Job、挂起创建和持有句柄确认、ConsoleHost、双流有界采集和轮转、运行配置版本、SQLite/WAL/备份/配置恢复、DPAPI、INI 事务预览导入、主窗口/编辑器/日志/历史/事件/设置、托盘、单实例、通知、自启与 MSIX 构建入口。

交互和发布仍需按设计完成实机核对，尤其是：控制台闪窗、目标对 Ctrl+Break 的真实响应、MSIX 对开发工具的虚拟化、通知/登录项实际状态、Narrator、高对比度及混合 DPI。当前界面还需要核对完整本地化、History/Events 筛选、批量操作与状态倒计时反馈、托盘键盘入口；这些不以编译通过代替完成。退出停止进度、取消退出及提前强制清理已接通并有核心回归测试；日志磁盘搜索可双击或 Enter 打开有界上下文，定位前检查分段身份，轮转后提示重新搜索。自定义外部日志目录及进程树资源汇总尚未开放，当前默认日志目录和指标只提供应用私有输出/主进程口径。删除配置/历史会清理应用拥有的输出，失败项保留在独立清理队列重试；外部文件不会删除，相关实机场景仍需核对。

性能预算、72 小时稳定性及 7 天日常负载没有实測结果。打包入口生成依赖清单与 CycloneDX SBOM；正式包 SBOM、受支持 Windows build 清单、签名包哈希、安装升级证据必须由发布环境补齐。未签名包仅为构建产物。

## W01–W40 证据状态

“阻塞”表示完整 Windows 验收没有证据；右列仅列实现/本地测试覆盖，不表示该 W 编号已通过。后续每项填写实机版本、架构、日期及证据路径。

| 编号 | 完整验收状态 | 当前覆盖 / 剩余证据 |
| --- | --- | --- |
| W01 | 阻塞：待 Windows 实机 | ReducerTests、SupervisorTests：幂等、停后重启；Windows ProcessTests 待运行 |
| W02 | 阻塞：待 Windows 实机 | StableExitPolicy、EarlyZeroExitIsStartupFailure |
| W03 | 阻塞：待 Windows 实机 | InitialAttemptPlusThreeRetriesHaveOneTwoFourBackoff |
| W04 | 阻塞：待 Windows 实机 | EleventhAutomaticRestartIsBlocked、CrashRecoveryDoesNotResetFatalOrRerunOneShot |
| W05 | 阻塞：待 Windows 实机 | RootExitCleansAllRemainingDescendants（Windows 待运行） |
| W06 | 阻塞：待 Windows 实机 | DirectedBreakOnlyStopsSelectedTargetAndJobHandlesIgnoredBreak（Windows 待运行） |
| W07 | 阻塞：待 Windows 实机 | OwnerDeathAtSuspendedOrActiveStageKillsJob（Windows 待运行；仍需 100 次和握手阶段注入） |
| W08 | 阻塞：待 Windows 实机 | LateCallbacksAreIgnoredEvenWhenPidMatches、StopDuringPrepareNeverResumesTarget、CancelBatchBeforeQueuedHandshakesStart |
| W09 | 阻塞：待 Windows 实机 | OneShotPreservesDwordAndNeverRetries；DwordCodeUsesHandleSignaledState 待运行 |
| W10 | 阻塞：待 Windows 实机 | AcceptedCancellationCannotBecomeSuccess、DuplicateOneShotStartReturnsSameRunAndStopWorksWhenStoreFails |
| W11 | 阻塞：待 Windows 实机 | CrashRecoveryDoesNotResetFatalOrRerunOneShot、CrashRecoveryRecordsUnknownInterruptedAndKeepsFatal |
| W12 | 阻塞：待 Windows 实机 | SleepUsesElapsedForOneShotAndActiveForService；电源/RDP 实机待测 |
| W13 | 阻塞：待 Windows 实机 | ShutdownAsync 单调预算、取消退出、强制清理回归；实际会话结束待测 |
| W14 | 阻塞：待 Windows 实机 | QuoteCrtCases；UnicodeEmptyQuoteTrailingSlashAndMetacharArgumentsRoundTrip 待运行 |
| W15 | 阻塞：待 Windows 实机 | DirectMetacharactersAreNotShellExpanded、PowerShellNeverLoadsProfileOrBypassesPolicy；各 Shell 实测待测 |
| W16 | 阻塞：待 Windows 实机 | LayeredEnvironmentHonorsRemoveAndEmpty、EnvironmentKeepsLiteralValuesAndRejectsCaseConflict |
| W17 | 阻塞：待 Windows 实机 | ImportIsDisabledAndFlagsDangerousUnsupportedFields、DuplicateImportRollsBackEntireBatch |
| W18 | 阻塞：待 Windows 实机 | 无提权/无 breakaway 降级路径；目标与嵌套 Job 实机待测 |
| W19 | 阻塞：待 Windows 实机 | SID 跨会话互斥、受限激活、Explorer 重建代码；实机待测 |
| W20 | 阻塞：待 Windows 实机 | 句柄白名单、EOF 清理；实机句柄审计待测 |
| W21 | 阻塞：待 Windows 实机 | LargeOutputIsDrainedWithBoundedQueueAndVisibleLoss；SimultaneousLargeStreamsDrainAndReachEof 待运行 |
| W22 | 阻塞：待 Windows 实机 | QuotaRejectsAdditionalBytesAndRetainsRawEvidence；实际磁盘满/锁/恢复待测 |
| W23 | 阻塞：待 Windows 实机 | RotationKeepsBoundedSegmentsWithoutChangingRawBytes；可见查看器并发待测 |
| W24 | 阻塞：待 Windows 实机 | IncrementalDecoderKeepsSplitUtf8AndUtf16；实际 Shell 编码待测 |
| W25 | 阻塞：待 Windows 实机 | RunRetentionKeepsActiveOutputAndCumulativeCount、LogQuota；全局持续压力待测 |
| W26 | 阻塞：待 Windows 实机 | OptimisticVersionAndUniqueNamesAreTransactional、BlockedConfigurationSaveDoesNotBlockStop |
| W27 | 阻塞：待 Windows 实机 | OnlineBackupIncludesWalWrites、HigherSchemaIsRejectedWithoutWriting、CorruptDatabaseSourceIsPreserved |
| W28 | 阻塞：待 Windows 实机 | SecretsAreEncryptedAndPortableExportRemovesThem、UnreadableSecretDisablesConfigurationAndRequiresReentry（测试保护器）；真实 DPAPI/跨账户待测 |
| W29 | 阻塞：待 Windows 实机 | RejectsOversizedLengthBeforeAllocatingPayload、RejectsOldProtocolVersion；实际管道 ACL/激活待测 |
| W30 | 阻塞：待 Windows 实机 | 主窗口/编辑器/日志/托盘已接通；用户路径实机待测 |
| W31 | 阻塞：待 Windows 实机 | 关闭驻留、激活合并、草稿保护代码；实机待测 |
| W32 | 阻塞：待 Windows 实机 | EnvironmentDraft 原始文本解析；实际中文输入、焦点与保存对话框待测 |
| W33 | 阻塞：待 Windows 实机 | FailedSaveDoesNotStopActiveRunAndSuccessfulRestartUsesNewestVersion；UI 待测 |
| W34 | 阻塞：待 Windows 实机 | 批量操作在提交时按最新快照重算；UI 确认及状态变化待测 |
| W35 | 阻塞：待 Windows 实机 | 标准 WPF 控件、资源、快捷键；Narrator/高对比实机待测 |
| W36 | 阻塞：待 Windows 实机 | 物理像素托盘定位、显示器窗口恢复；实际混合 DPI 待测 |
| W37 | 阻塞：待 Windows 实机 | 可失败的 AppNotificationManager 适配和只导航激活；签名包待测 |
| W38 | 阻塞：待 Windows 实机 | StartupTask 实际状态和 DisabledByUser/Policy 分支；签名包待测 |
| W39 | 阻塞：待 Windows 实机 | MSIX 清单、自包含打包、在线备份、schema 1→2 备份迁移回归、源库保留恢复；安装/升级/卸载待测 |
| W40 | 阻塞：待 Windows 实机 | 两种架构源码编译检查；原生 ARM64 与 x64 实机验收待测 |
