# Barback for Windows

C# + .NET 10 LTS + WPF 的首版实现已加入仓库。**当前为开发候选，尚未通过 Windows 实机发布验收，不提供已签名正式发行包。** 实现和实测状态见 [开发验证记录](docs/implementation-status.md)；产品要求仍以 [总体设计](docs/design.md)、[交互设计](docs/interaction.md)、[40 项验收标准](docs/validation.md)为准。

目标平台为 Windows 10 2004（build 19041）及以上和 Windows 11，x64 / ARM64、普通用户登录会话。运行检查和 MSIX 安装清单均使用 `10.0.19041.0` 最低版本，与项目 API 基线一致；包括 Windows 10 21H2 / LTSC 2021 和 22H2，不包括 LTSC 2019（build 17763）及更早版本。具体实测版本见开发验证记录。Barback 管理自己启动的进程树，不安装系统服务，不接管任意 PID，也不管理 WSL、Docker 或其他系统代理的任务。应用拒绝以管理员身份运行。

## 构建与运行

在普通用户 Windows PowerShell / PowerShell 7 中操作，需要固定版本 .NET SDK（见 `global.json`）。默认 MSIX 是框架依赖发布，需要目标机器安装 .NET 10 Desktop Runtime；使用 `-SelfContained` 才会把 .NET 运行时一并放入包中。打包还需要 Windows SDK 的 `mt`、`makepri` 和 `makeappx` 工具；脚本也支持使用 NuGet 缓存中的 `Microsoft.Windows.SDK.BuildTools`。SDK 和 NuGet 版本集中固定，项目锁文件覆盖 x64 与 ARM64。

```powershell
cd windows
./scripts/build.ps1
./scripts/test.ps1
./scripts/test-ui.ps1 # x64 原生工作台控件回归与截图，使用隔离数据库和模拟宿主
./scripts/run.ps1
```

`run.ps1` 将 App、ConsoleHost 和品牌资源发布至 `artifacts/dev/x64/`，再启动 App。两者必须同目录、同架构；单独 `dotnet run` App 不会自动提供 ConsoleHost。ARM64 实机使用 `-Architecture arm64`。

```powershell
./scripts/package.ps1 -Architecture x64 # 默认框架依赖，约 16 MB 的 MSIX
./scripts/package.ps1 -Architecture arm64
# 需要独立携带 .NET 运行时时使用自包含模式，包会明显变大。
./scripts/package.ps1 -Architecture x64 -SelfContained
# 正式签名需要发布环境证书；Publisher 必须与证书 Subject 一致。
./scripts/package.ps1 -Architecture x64 -Publisher 'CN=Oyasmi' -CertificateThumbprint '<thumbprint>'
```

未传证书时只生成未签名构建产物，不能作为正式可安装发行包。仓库不保存私钥，也不自行安装或信任证书。发布前必须完成 M0、W01–W40、两架构实机 smoke、升级/卸载与长期运行验证。

在非 Windows 上可以运行核心、存储和协议测试：

```bash
dotnet test tests/Barback.Core.Tests -c Release
dotnet test tests/Barback.Storage.Tests -c Release
dotnet test tests/Barback.Windows.Tests -c Release
```

第三个命令的 Win32 用例会明确跳过。Linux 可检查 WPF/C# 编译，但 Windows App SDK 自包含清单合并及 PRI/MSIX 工具必须在 Windows 运行；交叉编译不能代替安装或进程测试。

## 使用

- 主窗口采用[工作台布局](docs/ui-redesign.md)：程序列表与输出详情并排，窄窗口进入可返回的详情页。导航集中为程序、活动和设置；活动中区分执行记录与系统事件。每行只保留当前状态对应的主动作，其余操作收进菜单；批量操作位于页头更多菜单。
- 列表支持名称/分组搜索、类型筛选和需要处理视图。历史只展示已结束的结果，打开记录查看该次输出；仅一次性命令提供“用当前配置再次运行”，确认时明确历史与当前版本。批量启动/重启只操作已启用服务，停止包括一次性命令与已禁用但仍运行的程序。
- 普通模式填写绝对 `.exe` 路径及逐行参数；空行是空参数，留空参数区表示无参数。PowerShell 脚本/命令文本和 cmd 模式显式选择，不执行 Profile、不绕过执行策略，也不翻译 POSIX 命令。
- 控制台停止尝试定向 Ctrl+Break，超时终止 Job；立即终止模式会显示风险。清理未确认时阻止下一次启动，提供重试清理。
- 内嵌编辑器保留原始草稿，保存区固定可见，离开时检查未保存内容；高级选项按组折叠。环境变量 `KEY=value` 是字面量覆盖，`-KEY` 删除继承值；敏感项使用密码框并以当前用户 DPAPI 加密。设置中可编辑应用级覆盖或刷新用户环境，均只影响新 Run。
- 保存后当前 Run 保持自己的参数与策略快照；服务可保存并重启，一次性命令不会因保存自动重跑。复制和迁移所得配置默认禁用且不自动启动。
- 关闭主窗口默认驻留；托盘提供快捷启停，明确退出显示停止进度，可取消退出意图或确认提前强制清理，已停止的程序不会因取消而重启。应用异常结束时 Job 关闭清理进程树，下一次启动标记中断；一次性命令不会自动重跑。
- 日志分别保存 stdout/stderr 原始字节，轮转由唯一写入者控制。查看器支持跟随、暂停、已加载内容搜索、可取消磁盘搜索、结果上下文定位及原始字节导出。缓存/日志预算耗尽时继续排空输出，记录丢弃量及 `.gaps` 文件。
- 配置迁移只解析 INI，不执行命令、不读取 include、不展开插值。预览可重命名或跳过重名项；选定草稿以一个事务导入。

## 数据与恢复

签名 MSIX 使用应用的 `LocalState/Barback`；调试发布使用 `%LOCALAPPDATA%\Barback\Dev`，二者互不混用。设置显示实际数据目录，支持 SQLite 在线备份、移除敏感值的配置导出和默认脱敏诊断 ZIP。

配置保存后保留最近 10 份加密配置快照。损坏或高版本数据库不会被自动覆盖；恢复窗口允许用户选择 Windows 配置备份，保留原数据库及 WAL，再创建全部禁用的配置。恢复不导入运行状态或历史；无法解密的敏感值必须重新输入。

MSIX 卸载可能删除私有数据，请先导出备份。升级前通过应用正常退出并停止任务，再安装新包；不承诺跨版本保活。默认没有网络监听或遥测，诊断不自动上传。

## 代码布局

```text
src/Barback.Core/          模型、纯 reducer、串行 Supervisor、日志和 INI 预览
src/Barback.Windows/       Job、CreateProcess、身份、受限管道、进程宿主
src/Barback.ConsoleHost/   按次隐藏控制台宿主
src/Barback.Storage/       SQLite、版本事务、备份、恢复、DPAPI
src/Barback.App/           WPF、托盘、通知、自启、配置/日志/恢复窗口
fixtures/                 测试目标与崩溃探针
tests/                    核心、存储、协议与 Windows 进程测试
packaging/                MSIX 清单及复用现有品牌源的 PNG/ICO
scripts/                  构建、运行、测试、打包与环境证据采集
```

已知验证边界和与设计仍需核对的交互见 [开发验证记录](docs/implementation-status.md)。macOS 实现内容保持不变。
