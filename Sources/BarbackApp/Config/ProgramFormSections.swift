import SwiftUI
import AppKit
import BarbackCore

// MARK: - Form body

/// The whole per-program form as a single scrolling page rather than a segmented-control tab
/// bar. Splitting into tabs (常规 / 启动与停止 / 日志 …) was the original answer to "avoid one
/// long scroll" for a flat 28-field form, but nearly all of those fields are supervisor-style
/// knobs with a perfectly good default (`Program.defaults`) — only `command` and `name` truly
/// need a value from the user. Collapsing the rest into a handful of `AdvancedGroup`s, each
/// collapsed by default and showing a one-line summary of its current effective settings,
/// leaves a base form short enough that tabbed navigation no longer earns its chrome: everyone
/// sees command → identity → behaviour → environment, then a short stack of "更多设置" cards
/// they can scan without opening, and reach for only when they actually need to diverge from
/// the suggested value.
struct ProgramFormBody: View {
    @Binding var program: Program
    let index: FieldErrorIndex
    var existingGroups: [String] = []

    @State private var hint: CommandHint?
    /// Which `AdvancedGroup`s are expanded, keyed by a short id per group. Reset whenever the
    /// selected program changes so a heavily-customized service's open sections don't bleed
    /// into the next, unrelated program — mirrors the tab-reset the old tab bar did on
    /// `program.id` changing.
    @State private var expanded: Set<String> = []

    var body: some View {
        Form {
            commandSection
            identitySection
            lifecycleSection
            environmentSection
            advancedSections
        }
        .formStyle(.grouped)
        .frame(maxWidth: 680)
        .onAppear { refreshHint() }
        .onChange(of: program.id) { _ in expanded.removeAll() }
        .onChange(of: program.command) { _ in refreshHint() }
        .onChange(of: program.useShell) { _ in refreshHint() }
        .onChange(of: program.directory) { _ in refreshHint() }
    }

    // MARK: Base sections (Tier 0/1 — always visible)

    private var commandSection: some View {
        Section {
            FormRow(label: "命令", required: program.command.isEmpty, messages: index.messages(.command)) {
                TextField("", text: $program.command, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(2...6)
                if program.command.isEmpty {
                    Text("例如：/usr/local/bin/foo --flag")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let hint {
                    Label(hint.text, systemImage: hint.symbol)
                        .font(.caption)
                        .foregroundStyle(hint.tint)
                        .textSelection(.enabled)
                }
            }
            Toggle("通过 /bin/sh 执行", isOn: $program.useShell)
            FormRow(label: "工作目录", messages: index.messages(.directory)) {
                HStack {
                    TextField("~", text: optionalText($program.directory))
                    Button("选择…") { pickDirectory() }
                }
            }
        } header: {
            Text("命令")
        }
    }

    private var identitySection: some View {
        Section {
            FormRow(label: "名称", required: program.name.isEmpty, messages: index.messages(.name)) {
                TextField("", text: $program.name)
                    .frame(maxWidth: 260)
            }
            FormRow(label: "分组") {
                HStack {
                    TextField("默认", text: optionalText($program.groupName))
                        .frame(maxWidth: 200)
                    if !existingGroups.isEmpty {
                        Menu {
                            ForEach(existingGroups, id: \.self) { group in
                                Button(group) { program.groupName = group }
                            }
                        } label: {
                            Image(systemName: "chevron.down")
                        }
                        .menuStyle(.borderlessButton)
                        .frame(width: 20)
                        .accessibilityLabel("选择已有分组")
                        .help("从已有分组中选择")
                    }
                }
            }
        } header: {
            Text("标识")
        } footer: {
            Text("名称用于日志文件名与状态栏菜单，只能包含字母、数字、`.`、`_`、`-`。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var lifecycleSection: some View {
        if program.kind == .service {
            Section {
                Toggle("随 Barback 启动", isOn: $program.autostart)
                FormRow(label: "自动重启") {
                    Picker("", selection: $program.autorestart) {
                        Text("从不").tag(AutoRestartPolicy.never)
                        Text("仅异常").tag(AutoRestartPolicy.unexpected)
                        Text("总是").tag(AutoRestartPolicy.always)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 260)
                }
            } header: {
                Text("行为")
            }
        } else {
            Section {
                Toggle("执行前确认", isOn: $program.confirmBeforeRun)
                FormRow(label: "超时", messages: index.messages(.number("timeoutSeconds"))) {
                    HStack(spacing: 6) {
                        IntField(value: $program.timeoutSeconds)
                        Text("秒，0 表示不限").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("行为")
            } footer: {
                // A one-shot has no log-rotation config of its own (each run writes its own
                // file, cleaned up by the "历史保留" cap in the 执行 section below) — this is
                // the only place left telling the user where the output actually landed, now
                // that there's no longer an empty "日志" section pretending otherwise.
                Text("每次执行的输出单独保存在 runs/<名称>-<runId>.log，点击右上角「日志」查看最近一次。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var environmentSection: some View {
        Section {
            EnvironmentEditor(program: $program)
        } header: {
            Text(environmentTitle)
        } footer: {
            Text("每行一个 KEY=VALUE，覆盖登录环境快照中的同名变量；在 KEY 前加 `*` 标记敏感值，导出与诊断包中会打码。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var environmentTitle: String {
        program.environment.isEmpty ? "环境变量" : "环境变量（\(program.environment.count)）"
    }

    // MARK: Advanced sections (Tier 2 — collapsed by default)

    @ViewBuilder private var advancedSections: some View {
        if program.kind == .service {
            Section { RestartPolicyGroup(program: $program, index: index, isExpanded: expandedBinding("restart")) }
            Section { StopGroup(program: $program, index: index, isExpanded: expandedBinding("stop")) }
            Section { LogGroup(program: $program, isExpanded: expandedBinding("log")) }
            Section { OtherGroup(program: $program, isExpanded: expandedBinding("other")) }
        } else {
            Section { ExecutionAdvancedGroup(program: $program, index: index, isExpanded: expandedBinding("execution")) }
            Section { StopGroup(program: $program, index: index, isExpanded: expandedBinding("stop")) }
            Section { OtherGroup(program: $program, isExpanded: expandedBinding("other")) }
        }
    }

    private func expandedBinding(_ key: String) -> Binding<Bool> {
        Binding(
            get: { expanded.contains(key) },
            set: { on in
                if on { expanded.insert(key) } else { expanded.remove(key) }
            }
        )
    }

    // MARK: Command hint

    private func refreshHint() {
        hint = CommandHint.evaluate(command: program.command, useShell: program.useShell, directory: program.directory)
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            program.directory = url.path
        }
    }
}

// MARK: - 重启策略（服务）

struct RestartPolicyGroup: View {
    @Binding var program: Program
    let index: FieldErrorIndex
    @Binding var isExpanded: Bool

    private static let errorFields: [FormField] = [
        .number("startSeconds"), .number("startRetries"), .number("backoffBase"), .number("backoffMax")
    ]

    private var defaults: Program { Program.defaults(name: program.name, kind: program.kind, command: program.command) }

    private var changedCount: Int {
        var n = 0
        if program.startSeconds != defaults.startSeconds { n += 1 }
        if program.startRetries != defaults.startRetries { n += 1 }
        if program.backoffBase != defaults.backoffBase || program.backoffMax != defaults.backoffMax { n += 1 }
        if program.stormWindowSec != defaults.stormWindowSec || program.stormMaxRestarts != defaults.stormMaxRestarts { n += 1 }
        if program.exitCodes != defaults.exitCodes { n += 1 }
        return n
    }

    private var summary: String {
        let prefix = changedCount > 0 ? "已改动 \(changedCount) 项 · " : "默认 · "
        return prefix + "\(program.startSeconds) 秒存活，最多重试 \(program.startRetries) 次"
    }

    var body: some View {
        AdvancedGroup(
            title: "重启策略",
            summary: summary,
            changedCount: changedCount,
            hasError: index.hasError(in: Self.errorFields),
            isExpanded: $isExpanded,
            onResetAll: reset
        ) {
            FormRow(
                label: "存活判定",
                changed: program.startSeconds != defaults.startSeconds,
                messages: index.messages(.number("startSeconds"))
            ) {
                HStack(spacing: 6) {
                    IntField(value: $program.startSeconds)
                    Text("秒后视为启动成功").font(.caption).foregroundStyle(.secondary)
                }
            }
            FormRow(
                label: "启动重试",
                changed: program.startRetries != defaults.startRetries,
                messages: index.messages(.number("startRetries"))
            ) {
                HStack(spacing: 6) {
                    IntField(value: $program.startRetries)
                    Text("次后进入启动失败").font(.caption).foregroundStyle(.secondary)
                }
            }
            FormRow(
                label: "重启间隔",
                changed: program.backoffBase != defaults.backoffBase || program.backoffMax != defaults.backoffMax,
                messages: index.messages(.number("backoffBase")) + index.messages(.number("backoffMax"))
            ) {
                HStack(spacing: 6) {
                    DecimalField(value: $program.backoffBase)
                    Text("秒起，指数退避，上限").font(.caption).foregroundStyle(.secondary)
                    DecimalField(value: $program.backoffMax)
                    Text("秒").font(.caption).foregroundStyle(.secondary)
                }
            }
            FormRow(
                label: "重启风暴",
                changed: program.stormWindowSec != defaults.stormWindowSec || program.stormMaxRestarts != defaults.stormMaxRestarts
            ) {
                HStack(spacing: 6) {
                    IntField(value: $program.stormWindowSec)
                    Text("秒内重启超过").font(.caption).foregroundStyle(.secondary)
                    IntField(value: $program.stormMaxRestarts)
                    Text("次即停止重试").font(.caption).foregroundStyle(.secondary)
                }
            }
            FormRow(label: "正常退出码", changed: program.exitCodes != defaults.exitCodes) {
                VStack(alignment: .leading, spacing: 4) {
                    ExitCodesField(program: $program)
                    Text("退出码不在此列表中时，判定为失败。").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func reset() {
        program.startSeconds = defaults.startSeconds
        program.startRetries = defaults.startRetries
        program.backoffBase = defaults.backoffBase
        program.backoffMax = defaults.backoffMax
        program.stormWindowSec = defaults.stormWindowSec
        program.stormMaxRestarts = defaults.stormMaxRestarts
        program.exitCodes = defaults.exitCodes
    }
}

// MARK: - 执行（一次性命令）

struct ExecutionAdvancedGroup: View {
    @Binding var program: Program
    let index: FieldErrorIndex
    @Binding var isExpanded: Bool

    private var defaults: Program { Program.defaults(name: program.name, kind: program.kind, command: program.command) }

    private var changedCount: Int {
        var n = 0
        if program.exitCodes != defaults.exitCodes { n += 1 }
        if program.historyLimit != defaults.historyLimit { n += 1 }
        return n
    }

    private var summary: String {
        let prefix = changedCount > 0 ? "已改动 \(changedCount) 项 · " : "默认 · "
        let codes = program.exitCodes.map(String.init).joined(separator: ",")
        return prefix + "退出码 \(codes) · 保留 \(program.historyLimit) 条"
    }

    var body: some View {
        AdvancedGroup(
            title: "执行",
            summary: summary,
            changedCount: changedCount,
            hasError: index.hasError(in: [.number("historyLimit")]),
            isExpanded: $isExpanded,
            onResetAll: reset
        ) {
            FormRow(label: "正常退出码", changed: program.exitCodes != defaults.exitCodes) {
                VStack(alignment: .leading, spacing: 4) {
                    ExitCodesField(program: $program)
                    Text("退出码不在此列表中时，判定为失败。").font(.caption).foregroundStyle(.secondary)
                }
            }
            FormRow(
                label: "历史保留",
                changed: program.historyLimit != defaults.historyLimit,
                messages: index.messages(.number("historyLimit"))
            ) {
                HStack(spacing: 6) {
                    IntField(value: $program.historyLimit)
                    Text("条，超出后连同输出一并清理").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func reset() {
        program.exitCodes = defaults.exitCodes
        program.historyLimit = defaults.historyLimit
    }
}

// MARK: - 停止方式（服务与一次性命令共用）

struct StopGroup: View {
    @Binding var program: Program
    let index: FieldErrorIndex
    @Binding var isExpanded: Bool

    private var defaults: Program { Program.defaults(name: program.name, kind: program.kind, command: program.command) }

    private var changedCount: Int {
        var n = 0
        if program.stopSignal != defaults.stopSignal { n += 1 }
        if program.stopWaitSeconds != defaults.stopWaitSeconds { n += 1 }
        if program.stopAsGroup != defaults.stopAsGroup || program.killAsGroup != defaults.killAsGroup { n += 1 }
        return n
    }

    private var summary: String {
        let prefix = changedCount > 0 ? "已改动 \(changedCount) 项 · " : "默认 · "
        return prefix + "\(program.stopSignal)，\(program.stopWaitSeconds) 秒后强杀"
    }

    var body: some View {
        AdvancedGroup(
            title: "停止方式",
            summary: summary,
            changedCount: changedCount,
            hasError: index.hasError(in: [.number("stopWaitSeconds")]),
            isExpanded: $isExpanded,
            onResetAll: reset
        ) {
            FormRow(label: "停止信号", changed: program.stopSignal != defaults.stopSignal) {
                Picker("", selection: $program.stopSignal) {
                    ForEach(["TERM", "INT", "HUP", "QUIT"], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 140)
            }
            FormRow(
                label: "强杀等待",
                changed: program.stopWaitSeconds != defaults.stopWaitSeconds,
                messages: index.messages(.number("stopWaitSeconds"))
            ) {
                HStack(spacing: 6) {
                    IntField(value: $program.stopWaitSeconds)
                    Text("秒后发送 KILL").font(.caption).foregroundStyle(.secondary)
                }
            }
            FormRow(
                label: "进程组",
                changed: program.stopAsGroup != defaults.stopAsGroup || program.killAsGroup != defaults.killAsGroup
            ) {
                HStack(spacing: 14) {
                    Toggle("停止时", isOn: $program.stopAsGroup).toggleStyle(.checkbox)
                    Toggle("强杀时", isOn: $program.killAsGroup).toggleStyle(.checkbox)
                }
            }
            Text("按进程组发送会把信号送达整棵子进程树，适合会派生子进程的命令。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func reset() {
        program.stopSignal = defaults.stopSignal
        program.stopWaitSeconds = defaults.stopWaitSeconds
        program.stopAsGroup = defaults.stopAsGroup
        program.killAsGroup = defaults.killAsGroup
    }
}

// MARK: - 日志（服务）

struct LogGroup: View {
    @Binding var program: Program
    @Binding var isExpanded: Bool

    private var defaults: Program { Program.defaults(name: program.name, kind: program.kind, command: program.command) }

    private var changedCount: Int {
        var n = 0
        if program.logPath != defaults.logPath { n += 1 }
        if program.logMergeStderr != defaults.logMergeStderr { n += 1 }
        if program.logStderrPath != defaults.logStderrPath { n += 1 }
        if program.logRotatePolicy != defaults.logRotatePolicy { n += 1 }
        if program.logMaxBytes != defaults.logMaxBytes { n += 1 }
        if program.logBackups != defaults.logBackups { n += 1 }
        return n
    }

    private var summary: String {
        let prefix = changedCount > 0 ? "已改动 \(changedCount) 项 · " : "默认 · "
        switch program.logRotatePolicy {
        case .size:
            return prefix + "按 \(byteSummary) 轮转，保留 \(program.logBackups) 份"
        case .onRestart:
            return prefix + "重启时轮转，保留 \(program.logBackups) 份"
        case .never:
            return prefix + "不轮转"
        }
    }

    private var byteSummary: String {
        ByteCountFormatter.string(fromByteCount: program.logMaxBytes, countStyle: .file)
    }

    var body: some View {
        AdvancedGroup(
            title: "日志",
            summary: summary,
            changedCount: changedCount,
            isExpanded: $isExpanded,
            onResetAll: reset
        ) {
            FormRow(label: "输出路径", changed: program.logPath != defaults.logPath) {
                TextField("默认（应用日志目录）", text: optionalText($program.logPath))
            }
            FormRow(label: "stderr", changed: program.logMergeStderr != defaults.logMergeStderr) {
                Toggle("合并到 stdout", isOn: $program.logMergeStderr)
            }
            if !program.logMergeStderr {
                FormRow(label: "stderr 路径", changed: program.logStderrPath != defaults.logStderrPath) {
                    TextField("默认（应用日志目录）", text: optionalText($program.logStderrPath))
                }
            }
            FormRow(label: "轮转策略", changed: program.logRotatePolicy != defaults.logRotatePolicy) {
                Picker("", selection: $program.logRotatePolicy) {
                    Text("按大小").tag(LogRotatePolicy.size)
                    Text("重启时").tag(LogRotatePolicy.onRestart)
                    Text("不轮转").tag(LogRotatePolicy.never)
                }
                .labelsHidden()
                .frame(maxWidth: 160)
            }
            if program.logRotatePolicy == .size {
                FormRow(label: "单文件上限", changed: program.logMaxBytes != defaults.logMaxBytes) {
                    ByteSizeField(bytes: $program.logMaxBytes)
                }
            }
            if program.logRotatePolicy != .never {
                FormRow(label: "保留份数", changed: program.logBackups != defaults.logBackups) {
                    IntField(value: $program.logBackups)
                }
            }
        }
    }

    private func reset() {
        program.logPath = defaults.logPath
        program.logMergeStderr = defaults.logMergeStderr
        program.logStderrPath = defaults.logStderrPath
        program.logMaxBytes = defaults.logMaxBytes
        program.logBackups = defaults.logBackups
        program.logRotatePolicy = defaults.logRotatePolicy
    }
}

// MARK: - 其他（服务与一次性命令共用）

struct OtherGroup: View {
    @Binding var program: Program
    @Binding var isExpanded: Bool

    private var defaults: Program { Program.defaults(name: program.name, kind: program.kind, command: program.command) }

    private var changedCount: Int {
        var n = 0
        if program.priority != defaults.priority { n += 1 }
        if program.notes != defaults.notes { n += 1 }
        return n
    }

    private var summary: String {
        let prefix = changedCount > 0 ? "已改动 \(changedCount) 项 · " : "默认 · "
        let notesPart = (program.notes?.isEmpty == false) ? "有备注" : "无备注"
        return prefix + "优先级 \(program.priority) · \(notesPart)"
    }

    var body: some View {
        AdvancedGroup(
            title: "其他",
            summary: summary,
            changedCount: changedCount,
            isExpanded: $isExpanded,
            onResetAll: reset
        ) {
            FormRow(label: "优先级", changed: program.priority != defaults.priority) {
                HStack(spacing: 8) {
                    IntField(value: $program.priority)
                    Text("越小越先启动").font(.caption).foregroundStyle(.secondary)
                }
            }
            FormRow(label: "备注", changed: program.notes != defaults.notes) {
                TextField("", text: optionalText($program.notes), axis: .vertical)
                    .lineLimit(2...4)
            }
        }
    }

    private func reset() {
        program.priority = defaults.priority
        program.notes = defaults.notes
    }
}

// MARK: - 退出码

/// Free-form, comma-separated exit-code list. A `TextField` bound straight to a computed
/// `Binding<String>` over `program.exitCodes` — the previous approach — reformats on every
/// keystroke: typing "0," immediately parses to `[0]` and the field snaps back to "0" before
/// a second digit can follow, since the trailing empty token silently drops. This keeps its
/// own draft text instead, only normalizing into `program.exitCodes` as a side effect, and
/// surfaces whatever it had to drop rather than eating it silently.
struct ExitCodesField: View {
    @Binding var program: Program
    @State private var text: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField("0,2", text: $text)
                .frame(maxWidth: 160)
            if !invalidTokens.isEmpty {
                Text("已忽略无法识别的退出码：\(invalidTokens.joined(separator: ", "))")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .onAppear { text = Self.format(program.exitCodes) }
        .onChange(of: program.id) { _ in text = Self.format(program.exitCodes) }
        .onChange(of: program.exitCodes) { newValue in
            // Only an *external* change (a draft switch already caught above, or a section's
            // "恢复默认值") should overwrite what's being typed — never our own commit below,
            // which by construction already parses back to exactly `newValue`.
            if Self.parse(text) != newValue { text = Self.format(newValue) }
        }
        .onChange(of: text) { newValue in
            program.exitCodes = Self.parse(newValue)
        }
    }

    private var invalidTokens: [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && Int32($0) == nil }
    }

    private static func parse(_ text: String) -> [Int32] {
        text.split(separator: ",").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func format(_ codes: [Int32]) -> String {
        codes.map(String.init).joined(separator: ",")
    }
}

// MARK: - 日志大小

/// A byte count edited as "amount + unit" (KB/MB/GB) instead of a raw byte integer — nobody
/// thinks in bytes for a log rotation threshold. Stateless by design: the displayed unit is
/// always derived from `bytes` itself (the largest unit it divides evenly by) rather than
/// cached in `@State`, so switching to a different program's draft can never leave a stale
/// unit label paired with the new program's byte count.
struct ByteSizeField: View {
    @Binding var bytes: Int64

    private static let units: [(String, Int64)] = [("KB", 1024), ("MB", 1024 * 1024), ("GB", 1024 * 1024 * 1024)]

    private var unitIndex: Int {
        if bytes != 0, bytes % Self.units[2].1 == 0 { return 2 }
        if bytes != 0, bytes % Self.units[1].1 == 0 { return 1 }
        return 0
    }

    var body: some View {
        HStack(spacing: 6) {
            TextField("", value: amountBinding, format: .number)
                .frame(width: 64)
                .multilineTextAlignment(.trailing)
            Picker("", selection: unitBinding) {
                ForEach(Self.units.indices, id: \.self) { i in Text(Self.units[i].0).tag(i) }
            }
            .labelsHidden()
            .frame(width: 72)
        }
    }

    private var amountBinding: Binding<Double> {
        Binding(
            get: { Double(bytes) / Double(Self.units[unitIndex].1) },
            set: { newAmount in
                bytes = Int64((max(0, newAmount) * Double(Self.units[unitIndex].1)).rounded())
            }
        )
    }

    private var unitBinding: Binding<Int> {
        Binding(
            get: { unitIndex },
            set: { newIndex in
                let amount = Double(bytes) / Double(Self.units[unitIndex].1)
                bytes = Int64((amount * Double(Self.units[newIndex].1)).rounded())
            }
        )
    }
}

// MARK: - 环境变量

/// The KEY=VALUE editor, embedded as a section of the base form rather than a tab of its own.
struct EnvironmentEditor: View {
    @Binding var program: Program

    var body: some View {
        TextEditor(text: envBinding)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 90)
            .scrollContentBackground(.hidden)
            .padding(4)
            .overlay(alignment: .topLeading) {
                if program.environment.isEmpty {
                    Text("FOO=bar")
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
    }

    private var envBinding: Binding<String> {
        Binding(
            get: {
                program.environment.map { key, value in
                    (value.sensitive ? "*" : "") + key + "=" + value.value
                }.sorted().joined(separator: "\n")
            },
            set: { newValue in
                var result: [String: EnvVar] = [:]
                for line in newValue.split(separator: "\n") {
                    var key = String(line)
                    var sensitive = false
                    if key.hasPrefix("*") { sensitive = true; key.removeFirst() }
                    guard let eq = key.firstIndex(of: "=") else { continue }
                    let k = String(key[key.startIndex..<eq])
                    let v = String(key[key.index(after: eq)...])
                    result[k] = EnvVar(value: v, sensitive: sensitive)
                }
                program.environment = result
            }
        )
    }
}
