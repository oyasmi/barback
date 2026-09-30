# Windows 开发验证记录

日期：2026-09-30。环境：Linux x86_64；.NET SDK 10.0.401。当前交付是首版开发候选源码，**不是 Windows 发布验收通过的版本**。没有 Windows 桌面、签名证书或 ARM64 实机，四项 M0 关卡均未获得真实 Windows 证据，M4 不通过；不得据此发布相关首版能力。

## 已完成的本地验证

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

五个 PowerShell 脚本已通过 PowerShell 7.5.3 语法解析；中英资源均为 130 个唯一键且键集一致。Windows CI 和 PowerShell 发布/测试脚本已加入，但当前会话没有实际运行 GitHub Actions、Windows SDK 打包工具或签名安装。真实测试步骤见 [实机操作手册](windows-test-runbook.md)。

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
