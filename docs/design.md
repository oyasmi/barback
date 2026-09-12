# Barback 设计文档

| 项 | 内容 |
| --- | --- |
| 版本 | v1.0 设计基线 · 2026-09-12 |
| 前置 | [需求文档](./requirements.md) |
| 目标 | macOS 13+ / Universal 2 / Swift 6 / 零第三方依赖 |

---

## 1. 设计约束

所有取舍服从以下四条，冲突时按顺序仲裁：

1. **简单优先**——单进程、单数据库、无守护进程、无 IPC、无外部配置文件。能少一个活动部件就少一个。
2. **常态零开销**——无事件、无界面打开时 CPU 为零。进程退出靠 kqueue 事件、日志不经过主程序、菜单关闭即停止采样；全系统唯一的周期性任务是每 60 s 一次的日志尺寸检查。
3. **语义可预期**——与 supervisor 同名的字段必须同义。
4. **故障不扩散**——单个被管进程的任何异常不得波及 Barback 或其他被管进程。

**生命周期契约**：Barback 进程 = 所有被管进程的父进程。Barback 退出，被管进程一并退出。

---

## 2. 架构

### 2.1 进程拓扑

```
   登录项 (SMAppService) ── 开机自启
            │
            ▼
 ┌──────────────────────────────────────────────┐
 │  Barback.app  (LSUIElement, 单进程)           │
 │                                              │
 │  ── UI 层（主线程 / AppKit + SwiftUI）──      │
 │   StatusItemController  左右双菜单            │
 │   ConfigWindow · LogViewer · HistoryWindow    │
 │   PreferencesWindow · ImportSheet             │
 │            ▲ 状态快照        ▼ 操作指令        │
 │  ── 核心层（串行队列 core，无 UI 依赖）──      │
 │   Supervisor   状态机 / 退避 / 启停编排       │
 │   ProcessHost  posix_spawn / signal / 进程组   │
 │   ExitWatcher  kqueue NOTE_EXIT / waitpid     │
 │   LogManager   日志 fd 装配 / 轮转            │
 │   Store        SQLite（配置 / 运行 / 事件）    │
 │   ProcSampler  按需 CPU/RSS 采样              │
 │   PowerObserver 睡眠唤醒核对                  │
 └───────┬──────────────────┬───────────────────┘
         │ posix_spawn      │
         ▼ (独立会话/进程组)  ▼
   ┌───────────┐      ┌───────────┐
   │ 服务 A    │      │ 一次性命令 │
   └─────┬─────┘      └─────┬─────┘
         │ fd 1/2 直写       │
         ▼                  ▼
   ~/Library/Logs/Barback/{programs,runs}/*.log
                  ▲
                  └── 日志窗口打开时由 UI 层直接 tail
```

### 2.2 分层与线程模型

| 层 | 线程 | 职责 | 约束 |
| --- | --- | --- | --- |
| UI 层 | 主线程 | 菜单构建、窗口、用户输入 | 只读核心层发布的状态快照；所有操作以指令形式投递到 core 队列 |
| 核心层 | 串行队列 `barback.core` | 全部可变状态、进程生命周期、数据库读写 | **不 import AppKit / SwiftUI**；状态变更后向主线程发布不可变快照 |
| 辅助 | 独立队列 | 日志轮转的文件复制、批量采样、数据库备份 | 结果回投 core 队列 |

单一串行队列持有全部可变状态 → 天然无锁、无数据竞争。核心层与 UI 解耦，使 UI 卡顿不影响监管，也让状态机可脱离 UI 做穷举测试。

定时器统一用 `DispatchSourceTimer` 并设置宽松 `leeway`（≥10% 或 ≥1s），允许内核合并唤醒以省电。

### 2.3 关键决策

| # | 决策 | 理由 | 被否决的替代 |
| --- | --- | --- | --- |
| D-1 | 单进程：GUI 即监管者 | 无 IPC、无版本协商、无守护进程安装/卸载/升级流程；退出语义直观 | 独立守护进程 + launchd 托管：健壮性更高但活动部件翻倍，与"简单优先"冲突 |
| D-2 | Swift 6 + SwiftPM，零第三方依赖 | 原生、体积小、启动快、构建可复现 | Electron（内存 300 MB+）、Python（运行时依赖） |
| D-3 | 状态栏用 AppKit（`NSStatusItem`）分流左右键：左键 `NSPopover` 承载 SwiftUI 面板，右键 `NSMenu` | 左键是最高频路径，`NSMenu` 一行只能给一段文字、动作必须塞进子菜单；popover 里可以把启停、指标、告警补救都放在行上。右键是纯功能清单，`NSMenu` 更轻 | SwiftUI `MenuBarExtra`：无法区分左右键；左键继续用 `NSMenu`：无法去掉二级菜单 |
| D-4 | `posix_spawn` + `POSIX_SPAWN_SETSID` | 可控制会话/进程组（`stopAsGroup` 的前提）、fd 与环境；无 fork 后非 async-signal-safe 调用风险 | Foundation `Process`：无法设 pgid/sid，cmd_mgr 因此清理不掉子孙进程 |
| D-5 | `kqueue EVFILT_PROC/NOTE_EXIT` + `waitpid(WNOHANG)` | 内核事件驱动、零轮询；对非子进程同样有效，是崩溃后接管孤儿的技术前提 | SIGCHLD handler（处理受限）、轮询 `kill(pid,0)`（违反约束 2） |
| D-6 | 子进程 fd 直连日志文件，主程序不中转日志数据 | 日志吞吐对 Barback 的 CPU 开销恒为零；狂输出的程序不会拖垮监管 | 管道回流（supervisor 的做法）：每行日志唤醒一次监管者 |
| D-7 | 日志轮转用"复制后原地截断"（copytruncate） | 直连 fd 模式下 rename 会让子进程继续写旧 inode，只有原地截断能保持 fd 有效 | rename + reopen：需子进程配合 SIGHUP，不通用 |
| D-8 | SQLite 单库存配置/运行记录/事件 | 事务保证、查询能力（执行历史天然需要）、单文件易备份；GUI 唯一入口下不需要人类可读格式 | 文本配置文件：需要解析器、文件监听、并发写保护，且与"只能 GUI 配置"冲突 |
| D-9 | 纯用户级，不装特权助手 | 覆盖真实需求，避免授权弹窗与签名复杂度 | LaunchDaemon + `SMJobBless` |

> **已知取舍**：D-1 使 UI 层的崩溃会连带所有被管进程，且没有外部看门狗把 Barback 拉起来。缓解手段见 §8。

---

## 3. 进程管理

### 3.1 启动流程

```
start(program)  ← autostart / 用户操作 / 自动重启 / 一次性触发
 1. 前置校验：状态允许？可执行文件存在且有 x 位？工作目录存在？
 2. LogManager 备 fd：
      service : out = open(logPath, O_WRONLY|O_CREAT|O_APPEND|O_CLOEXEC, 0644)
      oneshot : out = open(runs/<name>-<runId>.log, 同上)
      err = mergeStderr ? dup(out) : open(errPath) ；写入分隔行（时间/PID/命令行）
 3. argv：useShell=false 时按 POSIX 词法解析 command；true 时 ["/bin/sh","-c",command]
 4. envp：登录环境快照 + program.environment + BARBACK_PROGRAM_NAME
 5. file_actions：fd0←/dev/null，fd1←out，fd2←err，addchdir_np(directory)
 6. attr：POSIX_SPAWN_SETSID | SETSIGDEF | SETSIGMASK
 7. posix_spawn → pid
 8. 立即读 proc_pidinfo(PROC_PIDTBSDINFO).pbi_start_tvsec/usec
      → (pid, startTime) 构成进程身份指纹，用于防 PID 复用
 9. ExitWatcher.register(pid)；关闭父侧 out/err fd
10. 写 live 表 + runs 表；状态迁移；发布快照
```

**要点**

- 默认**不经过 shell**，避开 supervisor 中 `command=bash -c 'foo ; bar'` 被注释语法截断那类坑，也少一层进程；需要管道/重定向时用户显式开 `useShell`。
- `POSIX_SPAWN_SETSID` 让子进程成为新会话首进程，其派生的子孙默认同属一个进程组 → `kill(-pgid, sig)` 可一网打尽。这正是用户现有配置中 `stopasgroup=true` 依赖的行为。
- stdin 接 `/dev/null`，防止读 stdin 的程序永久阻塞。

**API 可用性**（已在本机 macOS 15.7 SDK 核对）：`POSIX_SPAWN_SETSID`/`SETSIGDEF`/`SETSIGMASK` 见 `sys/spawn.h`；部署目标 macOS 13 需用 `posix_spawn_file_actions_addchdir_np`（10.15+），该符号自 macOS 26 更名为 `posix_spawn_file_actions_addchdir`，按可用性分支调用；进程启动时刻取自 `proc_pidinfo(PROC_PIDTBSDINFO)`。

### 3.2 退出感知

`DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit)`（底层即 kqueue `EVFILT_PROC/NOTE_EXIT`）→ 事件投递到 core 队列 → `waitpid(pid, &status, WNOHANG)` 取退出码/致死信号并回收僵尸。全程零轮询：没有进程退出就没有任何唤醒。

被接管的孤儿（非本次进程的子进程）同样能收到 NOTE_EXIT，但无法 `waitpid` 取状态 → 记为"退出码未知"，保守按非预期退出处理（宁可重启，不可失管）。

### 3.3 服务状态机

```
   [start]            存活 ≥ startSeconds
 STOPPED ──► STARTING ──────────────────► RUNNING
   ▲  ▲         │ 启动失败                    │ 进程退出
   │  │         ▼                            ▼
   │  │   retries < startRetries ?      autorestart 判定
   │  │    ├─是─► BACKOFF ──到期──► STARTING   ├─重启─► STARTING
   │  │    └─否─► FATAL ──[手动]──► STARTING   └─否──► EXITED
   │  │  [stop] 可从任意活动态进入
   │  └──── STOPPING ◄────────────────────────────────
   └──────────┘ 进程已消失
```

| 当前 | 事件 | 条件 | 新状态 | 副作用 |
| --- | --- | --- | --- | --- |
| STOPPED/EXITED/FATAL | `start` | — | STARTING | spawn；`retryCount` 清零 |
| STARTING | 存活满 `startSeconds` | — | RUNNING | 清零 `retryCount` |
| STARTING | 进程退出 | `retryCount+1 < startRetries` | BACKOFF | 排定退避定时器 |
| STARTING | 进程退出 | 重试耗尽 | FATAL | 通知 |
| BACKOFF | 退避到期 | — | STARTING | spawn |
| BACKOFF | `stop` | — | STOPPED | 取消定时器 |
| RUNNING | 进程退出 | `never` | EXITED | — |
| RUNNING | 进程退出 | `always` | STARTING | 经最小间隔后 spawn |
| RUNNING | 进程退出 | `unexpected` 且码 ∈ `exitCodes` | EXITED | 视为正常收工 |
| RUNNING | 进程退出 | `unexpected` 且码 ∉ `exitCodes` | STARTING | 通知（去抖）+ 退避后 spawn |
| RUNNING | 进程退出 | 触发崩溃风暴阈值 | FATAL | 通知，停止重试 |
| RUNNING/STARTING | `stop` | — | STOPPING | 执行停止序列 |
| STOPPING | 进程已退出 | — | STOPPED | **无论 autorestart 都不重启** |

**不变量**（debug 断言）：每个 Program 至多一个活动 PID；STARTING/RUNNING/STOPPING 必有有效 PID；STOPPED/EXITED/FATAL/BACKOFF 必无。

**`autostart` 语义**：Barback 每次启动时无条件拉起所有 `autostart=1` 的服务，**不记忆上次是否被手动停止**（`live` 表的状态只用于崩溃接管，不作为下次启动的依据）。"手动停止不自动重启"只在同一次会话内成立——它由 `stop_requested` 标志阻断本次退出触发的 autorestart，与 autostart 无关。

**退避**：`delay = min(base × 2^(n-1), max)`，默认 base=1s、max=60s，±20% 抖动避免多服务同步重启。
**崩溃风暴保护**（独立于 `startRetries`）：滑动窗口内（默认 10 分钟）重启超阈值（默认 10 次）→ 强制 FATAL。这覆盖"每次都活过 `startSeconds` 但很快就崩"的情形，supervisor 对此无保护。

### 3.4 一次性命令生命周期

复用同一套 spawn / 退出感知 / 停止序列，但走独立的简化状态：

```
IDLE ──[运行]──► RUNNING ──┬─ 退出码 ∈ exitCodes ─► SUCCEEDED
                          ├─ 其他退出码/信号 ────► FAILED(码)
                          ├─ 超过 timeoutSeconds ─► TIMEOUT   （先走停止序列）
                          └─ 用户中止 ───────────► CANCELLED （先走停止序列）
```

- **无** autostart / autorestart / startSeconds / startRetries / 退避——一次性命令永不自动重试。
- 默认禁止并发：RUNNING 时菜单「运行」置灰（`allowConcurrent=true` 时允许多实例，各自独立记录）。
- `confirmBeforeRun=true` 的命令在触发前弹确认框。
- 每次执行写一条 `runs` 记录并分配独立输出文件 `runs/<name>-<runId>.log`；超出保留条数（默认 50）时按 FIFO 删记录与文件。
- 终态触发系统通知（结果 + 耗时），点击通知打开该次输出。

### 3.5 停止序列（两类通用）

```
1. 状态 → STOPPING，置 stopRequested（该标志使本次退出绝不触发自动重启）
2. kill(stopAsGroup ? -pgid : pid, stopSignal)        # 默认 SIGTERM
3. 起 stopWaitSeconds 定时器（默认 10s）
4a. 收到 NOTE_EXIT → 取消定时器 → killAsGroup 时补发 kill(-pgid, SIGKILL) 清残留 → STOPPED
4b. 定时器到期 → kill(…, SIGKILL) → 再等 2s 兜底 → STOPPED（记 warning 事件）
```

`restart` = stop 完成（或超时 KILL）后再 start，两段之间不给自动重启逻辑插入的机会。

### 3.6 应用退出时的清理

```
applicationShouldTerminate:
 1. 若有一次性命令在跑 → 弹确认（"N 个命令正在执行，退出将终止它们"）
 2. 返回 .terminateLater，在 core 队列按 priority 降序对所有活动进程执行停止序列
 3. UI 若在 1 秒内未完成，显示带进度的停止面板（列出仍在停止的项）
 4. 全部进入终态 → 提交数据库事务 → NSApp.reply(toApplicationShouldTerminate: true)
 5. 兜底：总时长超过 max(各 stopWaitSeconds) + 5s 仍未清空 → 对残余 pgid 直接 SIGKILL 后退出
```

被 SIGTERM（注销/关机）时走同一路径但跳过确认与面板：系统本就会结束所有进程，此时只需尽快落盘。

### 3.7 崩溃后的接管

单进程架构下 Barback 崩溃会留下失管孤儿，违反生命周期契约。启动时修复：

```
1. 读 live 表（上次运行的 pid / startTime / pgid / state / retryCount）
2. 若记录的 appBootId 等于本次 → 说明是正常启动，表应为空；否则逐条身份校验：
     a. kill(pid, 0) 成功？ b. 进程启动时刻与记录一致？（防 PID 复用）
3. 双因子通过 → 接管：ExitWatcher.register(pid)，恢复 RUNNING（一次性命令恢复 RUNNING 并接管超时计时）
4. a 成功 b 失败 → PID 已复用，原进程已消失 → 按"退出码未知"处理
5. a 失败 → 进程已在 Barback 缺席期间退出 → 服务按 autorestart 语义处理，一次性命令记为"结果未知"
6. 接管完成后再处理 autostart（避免重复启动已接管的服务）
7. 事件日志记 `recoveredFromCrash`，菜单顶部提示一次"上次异常退出，已恢复 N 项"
```

`live` 表在每次状态迁移后写入（50 ms 内合并为一次），崩溃时最多丢失最近 50 ms 的状态。

### 3.8 睡眠 / 唤醒

订阅 `NSWorkspace.didWakeNotification`，唤醒后延迟 3 秒对所有活动 PID 做一次 §3.7 的双因子校验，修正睡眠期间的状态漂移。所有定时器在唤醒后按单调时钟重算到期时间。

---

## 4. 日志

**写入（零中转）**：子进程 fd 1/2 直连日志文件（`O_APPEND`，内核保证单次 write 原子追加）。Barback 在进程生命周期内完全不参与日志数据流动——这是"日志吞吐 CPU 开销 ≈ 0"的实现基础。

**轮转**（仅服务；一次性命令按运行记录 FIFO 清理）：

- 触发：宽松定时器每 60 s（leeway 30 s）`stat` 各日志文件；另在每次启停时顺带检查。这是全系统唯一的周期性任务。
- 动作：`<name>.log` → 复制为 `.1`（旧的依次后移，超 `backups` 的删除）→ 对原文件 `ftruncate(0)`（子进程因 `O_APPEND` 从 0 继续写）→ 写入轮转标记行 → 记事件。
- **取舍**：复制与截断之间写入的极少量数据可能丢失。提供 `rotatePolicy = onRestart` 严格模式：仅在服务重启时 `rename` 轮转，此时无写入者，零丢失。
- 写失败（ENOSPC）：记 error 事件 + 通知 + 菜单标注，**不停止业务进程**。

**读取（按需）**：日志窗口打开时由 UI 层直接读文件——`seek` 到 `max(0, size − 2 MB)` 对齐行边界后加载；跟随模式用 `DispatchSource.makeFileSystemObjectSource(.write|.extend|.rename|.delete)` 增量读取，检测到 inode 变化或文件缩小则重开。行数组设 5000 行上限。窗口关闭即注销监听、归零开销。渲染用 `NSTextView`（`NSViewRepresentable` 包装）而非 SwiftUI 列表，保证大文本性能。

---

## 5. 数据层

### 5.1 存储位置

```
~/Library/Application Support/Barback/
├── barback.db            (+ -wal, -shm)      # 唯一数据源，0600
└── backups/config-<ts>.json                  # 每次配置变更后的滚动备份，保留 10 份

~/Library/Logs/Barback/
├── barback.log                               # 自身日志（轮转）
├── programs/<name>.out.log[.1..N]            # 服务日志
└── runs/<name>-<runId>.log                   # 一次性命令每次输出
```

SQLite 以 **WAL + `synchronous=NORMAL`** 运行，写入全部发生在 core 串行队列（单写者），无并发写问题。启动时执行 `PRAGMA integrity_check`，失败则从最近备份恢复并提示。

### 5.2 Schema

```sql
PRAGMA user_version = 1;                      -- 迁移依据

CREATE TABLE program (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL UNIQUE,                  -- [A-Za-z0-9._-]{1,64}
  kind TEXT NOT NULL,                         -- 'service' | 'oneshot'，创建后不可改
  enabled INTEGER NOT NULL DEFAULT 1,
  command TEXT NOT NULL,
  use_shell INTEGER NOT NULL DEFAULT 0,
  directory TEXT,                             -- NULL = ~
  env_json TEXT NOT NULL DEFAULT '{}',        -- {"K":{"v":"...","sensitive":false}}
  group_name TEXT,
  priority INTEGER NOT NULL DEFAULT 100,      -- 小者先启动、后停止
  notes TEXT,
  -- service 专用
  autostart INTEGER NOT NULL DEFAULT 1,
  autorestart TEXT NOT NULL DEFAULT 'unexpected',   -- never|unexpected|always
  exit_codes TEXT NOT NULL DEFAULT '[0]',
  start_seconds INTEGER NOT NULL DEFAULT 5,
  start_retries INTEGER NOT NULL DEFAULT 3,
  backoff_base REAL NOT NULL DEFAULT 1.0,
  backoff_max REAL NOT NULL DEFAULT 60.0,
  storm_window_sec INTEGER NOT NULL DEFAULT 600,
  storm_max_restarts INTEGER NOT NULL DEFAULT 10,
  -- oneshot 专用
  timeout_seconds INTEGER NOT NULL DEFAULT 0, -- 0 = 不限
  confirm_before_run INTEGER NOT NULL DEFAULT 0,
  allow_concurrent INTEGER NOT NULL DEFAULT 0,
  history_limit INTEGER NOT NULL DEFAULT 50,
  -- 停止（两类通用）
  stop_signal TEXT NOT NULL DEFAULT 'TERM',
  stop_wait_seconds INTEGER NOT NULL DEFAULT 10,
  stop_as_group INTEGER NOT NULL DEFAULT 1,
  kill_as_group INTEGER NOT NULL DEFAULT 1,
  -- 日志
  log_path TEXT, log_merge_stderr INTEGER NOT NULL DEFAULT 1,
  log_stderr_path TEXT,
  log_max_bytes INTEGER NOT NULL DEFAULT 10485760,
  log_backups INTEGER NOT NULL DEFAULT 3,
  log_rotate_policy TEXT NOT NULL DEFAULT 'size',   -- size|onRestart|never
  created_at REAL NOT NULL, updated_at REAL NOT NULL
);

-- 运行时快照：崩溃恢复的唯一依据，每次状态迁移后写入
CREATE TABLE live (
  program_id INTEGER PRIMARY KEY REFERENCES program(id) ON DELETE CASCADE,
  app_boot_id TEXT NOT NULL,                  -- 本次 Barback 启动的唯一 id
  state TEXT NOT NULL,
  pid INTEGER, pgid INTEGER,
  proc_start_time REAL,                       -- 防 PID 复用
  started_at REAL, retry_count INTEGER NOT NULL DEFAULT 0,
  stop_requested INTEGER NOT NULL DEFAULT 0,
  run_id INTEGER,                             -- oneshot 当前运行
  needs_restart INTEGER NOT NULL DEFAULT 0
);

-- 运行记录：服务每次启动一条，一次性命令每次执行一条
CREATE TABLE run (
  id INTEGER PRIMARY KEY,
  program_id INTEGER NOT NULL REFERENCES program(id) ON DELETE CASCADE,
  trigger TEXT NOT NULL,                      -- manual|autostart|autorestart|retry
  pid INTEGER, started_at REAL NOT NULL, ended_at REAL,
  exit_code INTEGER, term_signal INTEGER,
  outcome TEXT,                               -- succeeded|failed|timeout|cancelled|unknown
  log_path TEXT
);
CREATE INDEX idx_run_program_time ON run(program_id, started_at DESC);

CREATE TABLE event (
  id INTEGER PRIMARY KEY, ts REAL NOT NULL,
  level TEXT NOT NULL,                        -- info|warn|error
  program_id INTEGER, type TEXT NOT NULL, detail_json TEXT
);
CREATE INDEX idx_event_time ON event(ts DESC);

CREATE TABLE setting (key TEXT PRIMARY KEY, value TEXT NOT NULL);
```

事件类型：`appStarted` / `appStopping` / `recoveredFromCrash` / `stateChanged` / `processSpawned` / `processExited` / `restartScheduled` / `enteredFatal` / `stopTimeout` / `logRotated` / `logWriteFailed` / `configChanged` / `imported` / `wakeReconcile`。保留策略：事件表超 20000 行时按时间裁剪；`run` 表按每程序 `history_limit` 裁剪并同步删除输出文件。

### 5.3 环境变量快照

登录项启动的进程不继承用户登录 shell 的 PATH（macOS 上最常见的"终端能跑、自启跑不了"问题）。对策：首次运行及每次应用启动时执行 `$SHELL -l -i -c 'export -p'` 抓取登录环境，过滤易变项（`_`、`PWD`、`SHLVL`、`OLDPWD`、`TERM*`）后存入 `setting` 表；以此为基础环境，程序级 `env_json` 在其上叠加。偏好中可查看、刷新、逐项禁用。

### 5.4 配置变更与运行中的服务

保存配置时按字段分类处理：

| 字段类别 | 字段 | 处理 |
| --- | --- | --- |
| 非运行时 | autostart / autorestart / exit_codes / start_retries / 退避 / priority / group / notes / 轮转参数 / oneshot 的 confirm & history_limit | 立即生效，不重启 |
| 运行时 | command / use_shell / directory / env / 日志路径 / stop_* / timeout | 未运行则下次启动生效；运行中则由 `Supervisor` 记下该 id（下次 spawn 即清除），面板行显示「配置已变更，重启后生效」并给出「立即重启」，配置窗口提供「保存并重启」 |

---

## 6. GUI

### 6.1 状态栏图标

`NSStatusItem(variableLength)`，template 图像自动适配明暗与强调色。四种视觉状态：全部健康（常规）/ 有已停止项（常规 + 右下小空心点）/ 有 FATAL 或日志写失败（叠加警示徽标，系统警示色）/ 有一次性命令执行中（叠加忙态点）。不做持续动画以免耗电。

### 6.2 左右键分流

SwiftUI `MenuBarExtra` 无法区分左右键，故用 AppKit。左键打开**程序面板**（`NSPopover` + SwiftUI），右键弹出应用 `NSMenu`：

```swift
statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
statusItem.button?.action = #selector(handleClick(_:))

@objc func handleClick(_ sender: NSStatusBarButton) {
    let e = NSApp.currentEvent!
    let isRight = e.type == .rightMouseUp
        || (e.type == .leftMouseUp && e.modifierFlags.contains(.control))
    isRight ? showAppMenu()       // 打开瞬间才构建，用完摘除，下次点击仍走 action
            : togglePanel()       // popover 关闭即释放 contentViewController
}
```

面板与菜单都**只在打开的瞬间构建、关闭即释放**。面板持有的每秒计时器（运行时长、退避倒计时、CPU/RSS 采样）随 `popoverDidClose` 一并停掉：**面板关闭时不采样 CPU/RSS、不刷新计时**，这是常态零开销的关键。

### 6.3 左键面板

原来的左键是标准 `NSMenu`：一行只放得下名称与一句状态，启停要先展开子菜单、再移动到目标项，是全 App 使用频率最高却最慢的一条路径。改为自绘面板后，**日常动作直接落在行上**，长尾动作收进行内抽屉，不再有二级菜单。

```
┌─ 左键面板（宽 420）────────────────────────────────────────┐
│ ●1 运行中  ○2 已停止  ⚠1 失败  ◌1 执行中              ⚙  │ ← 摘要胶囊 + 配置 ⌘,
│ 🔍 搜索程序                                （> 8 项时出现）│
├────────────────────────────────────────────────────────────┤
│ 服务 6                                                     │
│  网络 2                                                    │
│ ▎● nslocal        运行中           [■ 停止] [↻] [📄] [⌄]  │
│    PID 4821 · 已运行 2 天 3 小时 · CPU 0.3% · 48.0 MB      │
│ ▎◑ api-server     重试 2/3         [■ 停止] [↻] [📄] [⌄]  │
│    12 秒后重试 · 上次退出 今天 22:26 · 退出码 1            │
│    ▁▁▁▁▁▁▁▁▃▃▃▃▃▃▃▃▃▃▃▃  ← 退避倒计时                     │
│  未分组 3                                                  │
│ ▎⚠ tunnel-gateway 启动失败         [▶ 启动] [↻] [📄] [⌄]  │
│    已重试 3 次 · 上次退出 今天 22:21 · 退出码 127          │
│    ⚠ 自动重试已停止，需要人工处理            清除状态      │
│ ▎○ voice_typer_server 已停止       [▶ 启动] [↻] [📄] [⌄]  │
│ 一次性命令 3                                               │
│ ▎✓ backup-db      成功             [▶ 运行] [📄] [🕑] [⌄]  │
│    上次 今天 20:27 · 耗时 3.4 秒 · 共 27 次                │
├────────────────────────────────────────────────────────────┤
│ [▶ 全部启动]   [■ 全部停止]   [↻ 全部重启]                 │
│ 右键状态栏图标可打开应用菜单                 Barback 0.2.0 │
└────────────────────────────────────────────────────────────┘

展开抽屉（点行任意处或 ⌄）
 命令  /usr/local/bin/nslocal --config ~/x.yml        [复制]
 目录  ~/work
 日志  ~/Library/Logs/Barback/programs/nslocal.out.log
 分组 网络        启动于 09-06 13:33
 自动启动 开      自动重启 非预期退出      停止信号 SIGTERM
 [在 Finder 中显示]  [复制 PID 4821]  [编辑配置…]
```

**行上的动作**取决于状态，一次点击即生效，不需要先选中：

| 状态 | 主按钮 | 图标按钮 |
| --- | --- | --- |
| 服务 运行中 / 启动中 / 重试中 | 停止（红） | 重启 · 日志 · 展开 |
| 服务 已停止 / 已退出 / 启动失败 | 启动（绿） | 重启（禁用）· 日志 · 展开 |
| 服务 停止中 | 强制终止（红） | 重启（禁用）· 日志 · 展开 |
| 一次性 执行中 | 中止（红） | 输出 · 历史 · 展开 |
| 一次性 其他 | 运行（强调色） | 输出 · 历史 · 展开 |

- 状态**同时用形状、文字与颜色表达**（实心绿=运行 / 半填充橙+转轮=启动中·停止中 / 空心灰=停止·退出 / 红⚠=启动失败 / ✓✗=一次性结果），不单靠颜色传达信息；行首还有一条同色竖条作为可扫视的状态脊。
- 强制终止只在 `STOPPING` 出现——状态机也只在这个状态接受 `forceKill`，其余状态给出这个按钮等于给一个死键。它会先关面板再弹确认。
- 异常态用整条提示带表达而不是一行小字：`FATAL` 给「清除状态」，运行中改过运行时字段给「立即重启」。
- 退避用倒计时 + 进度发丝线。快照里的 `backoff_remaining` 冻结在发布时刻，面板按本地时钟推进，不必等定时器到点才更新。
- 项数 > 8 时出现搜索框；服务存在一个以上 `group_name` 时按分组分节。
- 紧凑密度（偏好设置）去掉指标行，其余不变。

### 6.4 右键菜单

```
Barback 1.0.0 (42) · 已运行 3天2小时        ← 禁用
────────────────────────────────────────
打开配置窗口…                       ⌘,
执行历史…  /  事件日志…
打开日志目录
────────────────────────────────────────
偏好设置…
开机自动启动                         ✓
从 supervisor 粘贴导入…
────────────────────────────────────────
导出诊断包…  /  检查更新…  /  关于 Barback
────────────────────────────────────────
退出 Barback（将停止全部被管进程）
```

### 6.5 配置窗口

SwiftUI `NavigationSplitView` 挂在 AppKit 窗口上，默认 980×680、最小 840×560。主操作放在原生工具栏，详情区按分区切页而不是堆成一条长滚动：

```
┌─ 配置 ──────────────────────────────────────────────────────────────────┐
│ ⊕ 新建 ▾   ⧉ 复制   🗑 删除                   🔍 搜索…      ⇅ 分组方式 ▾ │
├───────────────────────┬─────────────────────────────────────────────────┤
│ 服务                3 │  nslocal  [服务]                    ● 运行中     │
│  ● nslocal            │  PID 4821 · 已运行 2 天 3 小时 · 分组 网络       │
│    运行中 · PID 4821  │                                  [日志] [历史]   │
│  ● tunnel             │ ─────────────────────────────────────────────── │
│    重试中 2/3 · 12 秒 │  ⟨ 常规 │ 启动与重启 │ 停止 │ 环境 │ 日志 ⟩     │
│  ○ voice_typer_server │ ─────────────────────────────────────────────── │
│    已停止             │   ┌ 标识 ─────────────────────────────────────┐ │
│ 一次性命令          2 │   │ 名称 [nslocal          ]   ☑ 启用         │ │
│  ▶ backup-db          │   └───────────────────────────────────────────┘ │
│    成功 · 1.2s        │   ┌ 命令 ─────────────────────────────────────┐ │
│  ▶ clean-cache        │   │ 命令 [/usr/local/bin/nslocal -c ~/x.yml ] │ │
│    尚未执行           │   │      ☐ 通过 /bin/sh 执行                  │ │
│                       │   │      ✓ 解析为 /usr/local/bin/nslocal      │ │
│                       │   │ 工作目录 [~/work           ] [选择…]      │ │
│                       │   └───────────────────────────────────────────┘ │
│ [+] [−]               │ ─────────────────────────────────────────────── │
│                       │ ● 有未保存的更改   [撤销] [保存并重启] [保存]   │
└───────────────────────┴─────────────────────────────────────────────────┘
```

- 工具栏的 `⊕ 新建 ▾` 是主入口（⌘N 服务 / ⇧⌘N 一次性命令 / 粘贴导入）；左栏底部的 `[+] [−]` 只是 macOS 侧栏的惯例补充。类型决定表单字段集，创建后不可改（可「复制」后另存）。
- 详情区三层固定结构：**身份与实况**（名称、类型徽章、状态胶囊、PID/运行时长、跳转日志与历史）→ **分段标签**（服务：常规 / 启动与重启 / 停止 / 环境 / 日志；一次性命令：常规 / 执行 / 停止 / 环境 / 日志，含错误分区角标）→ **提交条**（脏标记 + 撤销 + 保存 + 保存并重启）。
- 表单用 `Form.formStyle(.grouped)`；每个分区头部带「恢复默认值」，作用域限于本分区。
- 左栏按「类型 / 分组 / 状态 / 名称」分组；仅在按类型且未搜索时允许拖拽排序 = 调整 `priority`。显示只读状态，**不提供日常启停按钮**（操作归状态栏）。
- 命令字段实时解析（`ShellLexer` + `PATH` 查找）并就地给出提示；其余字段停止输入 0.5s 后校验，错误红字贴在对应字段下。
- ⌘S 保存、Esc 撤销、⌘D 复制、⌘⌫ 删除；脏状态驱动标题栏 edited 圆点，切换选中项与关窗都会弹确认（保存 / 放弃 / 取消）。
- 首次使用时详情区是引导态（新建服务 / 新建一次性命令 / 粘贴导入），删除前必须确认且提示会一并清除执行历史。

### 6.6 其他窗口

| 窗口 | 要点 |
| --- | --- |
| 日志查看器 | 每服务一个窗口；跟随/暂停、搜索高亮、字号、清空、Finder 显示、外部打开；底部显示路径与大小 |
| 执行历史 | 表格（时间 / 命令 / 结果 / 耗时 / 退出码），按命令与结果筛选，双击查看该次输出，支持「重跑」与清理 |
| 事件日志 | 表格（时间 / 级别 / 对象 / 类型 / 详情），按对象与级别筛选，可导出 |
| 偏好设置 | 三页：通用（开机自启、面板密度、语言）/ 通知（分级开关、去抖窗口）/ 高级（历史保留、环境快照管理、日志级别、诊断包、数据库备份恢复） |

### 6.7 无障碍与本地化

菜单项与按钮提供 `accessibilityLabel`；状态不单靠颜色传达；完整键盘导航；尊重"减少动态效果"与系统字号；文案走 String Catalog，首发 zh-Hans + en。

---

## 7. supervisor 粘贴导入

用户把一段或多段 INI 文本粘到导入窗口 → 解析 `[program:name]` 小节 → 展示映射预览表（每行：程序名 / 将导入的字段 / 无法映射的字段与原因 / 勾选框）→ 导入。

| supervisor 字段 | Barback | 备注 |
| --- | --- | --- |
| `command` | `command` | 含 `sh -c` 前缀时自动改为 `use_shell=true` + 去前缀 |
| `directory` / `environment` | `directory` / `env_json` | `environment` 支持带引号的逗号分隔解析 |
| `autostart` | `autostart` | **导入时一律强制 false**（避免与仍在跑的 supervisord 抢端口） |
| `autorestart` | `autorestart` | `true→always`、`false→never`、`unexpected→unexpected` |
| `exitcodes` / `startsecs` / `startretries` | 同名字段 | — |
| `stopsignal` / `stopwaitsecs` / `stopasgroup` / `killasgroup` | 同名字段 | — |
| `priority` | `priority` | — |
| `stdout_logfile` / `stderr_logfile` / `redirect_stderr` | `log_path` / `log_stderr_path` / `log_merge_stderr` | `AUTO`/`NONE` 转为默认路径/丢弃 |
| `stdout_logfile_maxbytes` / `_backups` | `log_max_bytes` / `log_backups` | 支持 `10MB` 后缀解析 |
| `user` / `numprocs` / `process_name` / `serverurl` / `umask` 等 | — | 列入"无法映射"并说明原因（用户级运行 / 不支持多实例等） |

导入是非破坏性的：不读写任何 supervisor 文件。导入后提示"请先 `supervisorctl stop all` 并停用 supervisord，再在 Barback 中启动"，附可复制命令。

---

## 8. 容错、安全与工程

### 8.1 容错清单

| 风险点 | 对策 |
| --- | --- |
| UI 层崩溃连带所有被管进程 | 核心层零 UI 依赖、跑独立队列；编码规范禁用 `!` 与无检查下标；崩溃后下次启动自动接管存活进程（§3.7）并记事件以便发现 |
| PID 复用误判 | PID + 进程启动时刻双因子校验 |
| 子进程狂输出日志 | 日志不经过 Barback（§4）；轮转上限约束磁盘 |
| 子进程吃满内存 | 独立进程互不影响；v1.1 提供 RSS 阈值自动重启 |
| 崩溃风暴 | 指数退避 + 滑动窗口阈值强制 FATAL |
| 停止残留子孙进程 | SETSID + 整组信号 + KILL 兜底 |
| 磁盘写满 | 事件 + 通知 + 菜单标注，业务进程照常运行 |
| 数据库损坏 | WAL + 事务；启动 `integrity_check`；每次配置变更后滚动 JSON 备份（10 份）可一键恢复 |
| 睡眠唤醒状态漂移 | 唤醒后全量双因子核对 |
| 升级 | 只换 `.app`；按 `PRAGMA user_version` 做 schema 迁移，迁移前自动备份数据库 |

### 8.2 安全

数据库与日志目录 0700、文件 0600；环境变量可标记 sensitive，在界面打码、在导出与诊断包中替换为 `***`；子进程以当前用户身份运行，不提权；不监听端口、不发遥测；仅申请通知权限与登录项；发布走 Developer ID 签名 + 公证 + Hardened Runtime。

### 8.3 代码结构

```
barback/
├── Package.swift                  # 可执行 target + 核心库 target + CSQLite 系统库 shim
├── Sources/
│   ├── CSQLite/                   # libsqlite3 的 modulemap（无第三方依赖）
│   ├── BarbackCore/               # 无 UI 依赖，可脱离 App 测试
│   │   ├── Model/                 # Program, ProgramState, RunRecord, Event, Settings
│   │   ├── StateMachine/          # (State, Event, Config) -> (State, [Action]) 纯函数
│   │   ├── Process/               # ProcessHost, ExitWatcher, ProcSampler
│   │   ├── Store/                 # SQLite 封装、schema 迁移、备份
│   │   ├── Log/                   # LogManager（fd 装配 + 轮转）
│   │   ├── Import/                # supervisor INI 解析与映射
│   │   └── Util/                  # shell 词法解析、路径展开、时间
│   └── BarbackApp/
│       ├── AppDelegate.swift      # 生命周期、退出清理、登录项、通知
│       ├── Supervisor.swift       # 编排：core 队列上的唯一状态持有者
│       ├── StatusItem/            # 双菜单构建与刷新
│       ├── Config/ Logs/ History/ Events/ Preferences/ Import/ Onboarding/
├── Tests/{CoreTests,ProcessTests,IntegrationTests}/
├── Fixtures/testchild/            # 可控行为的测试子进程
└── Scripts/{build,package,sign-notarize}.sh
```

**关键约定**：状态机写成纯函数 `(State, Event, Config) -> (State, [Action])`，副作用（spawn / kill / 计时 / 写库）以 `Action` 值返回给 `Supervisor` 执行。这让全部语义可脱离真实进程做穷举测试（验收 A2）。

### 8.4 测试

| 层 | 内容 |
| --- | --- |
| 纯函数单测 | 服务状态机矩阵（`{autorestart×3} × {码 0/非0/信号} × {startSeconds 内外}`）、一次性命令终态判定、退避计算、配置校验、shell 词法解析、supervisor INI 映射 |
| 进程集成测试 | `Fixtures/testchild` 提供 `--exit-after/--exit-code/--ignore-term/--spawn-children/--spam-stdout/--alloc`，覆盖启停、重试至 FATAL、TERM 超时升级 KILL、整组清理、超时中止、日志轮转 |
| 端到端 | 崩溃接管（反复 `kill -9` 自身，断言 PID 不变、无重复启动，A5）、退出清理（20 项混合场景后 `pgrep` 无残留，A4）、真实 INI 黄金用例（A1） |
| 故障注入 | 只读目录、磁盘满（小 sparse 卷）、损坏数据库、PID 复用模拟 |
| 性能 / Soak | RSS/CPU 采样脚本（CI 做 RSS 回归）；30 天长跑 + 随机杀进程/睡眠唤醒（A7、A10） |

### 8.5 打包与分发

`swift build -c release --arch arm64 --arch x86_64` → 组装 `Barback.app`（`LSUIElement=true`）→ 签名公证 → `.dmg`。开机自启用 `SMAppService.mainApp.register()`（出现在"系统设置 → 通用 → 登录项"，用户可自行关闭）——这是登录项注册，不是 LaunchAgent 守护进程，Barback 崩溃后不会被系统自动拉起。

---

## 9. 未决问题

| # | 问题 | 倾向 | 何时定 |
| --- | --- | --- | --- |
| Q1 | 日志轮转默认 `size`（copytruncate，可能丢极少量行）还是 `onRestart`（零丢失但可能长期不轮转） | 默认 `size`，文档标注取舍 | M5 前 |
| Q2 | 一次性命令是否需要"参数化输入"（运行前弹框填变量） | v1 不做，排入 v1.1 | — |
| Q3 | 分发方式：Developer ID 签名公证 vs 自签名 + 放行说明 | 取决于是否有开发者账号 | M5 前 |
