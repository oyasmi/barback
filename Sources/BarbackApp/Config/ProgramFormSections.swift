import SwiftUI
import AppKit
import BarbackCore

// MARK: - Form body

/// A single scrollable editor, grouped by the task the user is performing.
struct ProgramFormBody: View {
    @Binding var program: Program
    @Binding var environmentText: String
    @Binding var expandedSections: [Int64: Set<String>]
    @Binding var scrollAnchors: [Int64: String]
    let index: FieldErrorIndex
    let validationRequest: Int
    var existingGroups: [String] = []

    @State private var hint: CommandHint?
    @StateObject private var fieldFocus = ConfigFieldFocusState()
    @State private var trackingProgramId: Int64?

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    identitySection
                    commandSection
                    lifecycleSection
                    outputSection
                    notesSection
                }
                .padding(24)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .coordinateSpace(name: "configFormScroll")
            .background(Color(nsColor: .windowBackgroundColor))
            .onPreferenceChange(ConfigScrollPositions.self) { positions in
                guard trackingProgramId == program.id else { return }
                let sorted = positions.sorted { $0.value < $1.value }
                let anchor = sorted.last(where: { $0.value <= 28 })?.key ?? sorted.first?.key
                if scrollAnchors[program.id] != anchor { scrollAnchors[program.id] = anchor }
            }
            .onChange(of: validationRequest) { _ in
                guard let field = index.firstField else { return }
                let section = sectionForError(field)
                setExpanded(section, true)
                // Allow disclosure content to enter the hierarchy before scrolling/focusing.
                Task { @MainActor in
                    await Task.yield()
                    proxy.scrollTo(section, anchor: .top)
                    fieldFocus.focus(field)
                }
            }
            .task(id: program.id) {
                trackingProgramId = nil
                let id = program.id
                let anchor = scrollAnchors[id] ?? "identity"
                refreshHint()
                await Task.yield()
                guard !Task.isCancelled, program.id == id else { return }
                proxy.scrollTo(anchor, anchor: .top)
                await Task.yield()
                guard !Task.isCancelled, program.id == id else { return }
                trackingProgramId = id
            }
        }
        .environmentObject(fieldFocus)
        .toggleStyle(.switch)
        .textFieldStyle(.roundedBorder)
        .onAppear { refreshHint() }
        .onChange(of: program.command) { _ in refreshHint() }
        .onChange(of: program.useShell) { _ in refreshHint() }
        .onChange(of: program.directory) { _ in refreshHint() }
    }

    private var identitySection: some View {
        ConfigSection(title: "基本信息") {
            FormRow(label: "名称", required: program.name.isEmpty, messages: index.messages(.name)) {
                TextField("程序名称", text: $program.name)
                    .configField(.name)
                Text("1–64 位字母、数字或 . _ -，用于菜单与日志文件名。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            FormRow(label: "分组") {
                HStack(spacing: 6) {
                    TextField("默认", text: optionalText($program.groupName))
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
        }
        .configScrollAnchor("identity")
    }

    private var commandSection: some View {
        ConfigSection(title: "启动命令") {
            VStack(alignment: .leading, spacing: 8) {
                TextField("例如：/usr/local/bin/server --port 8080", text: $program.command, axis: .vertical)
                    .font(.system(.body, design: .monospaced))
                    .lineLimit(3...8)
                    .configField(.command)
                ForEach(index.messages(.command), id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.circle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
                if let hint, index.messages(.command).isEmpty {
                    Label(hint.text, systemImage: hint.symbol)
                        .font(.caption).foregroundStyle(hint.tint)
                        .textSelection(.enabled)
                }
            }
            FormRow(label: "执行方式") {
                Picker("执行方式", selection: $program.useShell) {
                    Text("直接执行").tag(false)
                    Text("通过 Shell").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 280)
                if program.useShell {
                    Text("使用 /bin/sh -c，可使用管道、重定向和变量展开。")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            FormRow(label: "工作目录", messages: index.messages(.directory)) {
                HStack(spacing: 8) {
                    TextField("~", text: optionalText($program.directory))
                        .configField(.directory)
                    Button("选择…") { pickDirectory() }
                }
            }
            Divider()
            AdvancedGroup(
                title: "环境变量",
                summary: environmentText.isEmpty ? "未添加 · 使用登录环境" : "已配置 \(program.environment.count) 个变量",
                changedCount: 0,
                hasError: !index.messages(.environment).isEmpty,
                isExpanded: expandedBinding("environment", initially: !environmentText.isEmpty)
            ) {
                EnvironmentEditor(text: $environmentText, messages: index.messages(.environment))
            }
            .configScrollAnchor("environment")
        }
        .configScrollAnchor("command")
    }

    private var lifecycleSection: some View {
        ConfigSection(title: "运行规则") {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("启用此配置", isOn: $program.enabled)
                Text("保存后生效；此开关不会立即启动或停止程序。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if program.kind == .service {
                Toggle("随 Barback 启动", isOn: $program.autostart)
                FormRow(label: "自动重启") {
                    Picker("自动重启", selection: $program.autorestart) {
                        Text("从不").tag(AutoRestartPolicy.never)
                        Text("仅异常退出").tag(AutoRestartPolicy.unexpected)
                        Text("总是").tag(AutoRestartPolicy.always)
                    }
                    .labelsHidden().frame(maxWidth: 220)
                }
                Divider()
                RestartPolicyGroup(program: $program, index: index, isExpanded: expandedBinding("restart"))
                    .configScrollAnchor("restart")
            } else {
                Toggle("执行前确认", isOn: $program.confirmBeforeRun)
                FormRow(label: "执行超时", messages: index.messages(.number("timeoutSeconds"))) {
                    HStack(spacing: 6) {
                        IntField(value: $program.timeoutSeconds)
                            .configField(.number("timeoutSeconds"))
                        Text("秒，0 表示不限").font(.caption).foregroundStyle(.secondary)
                    }
                }
                FormRow(label: "成功退出码") {
                    ExitCodesField(program: $program)
                }
                FormRow(label: "排列顺序") {
                    HStack(spacing: 6) {
                        IntField(value: $program.priority)
                        Text("数值越小，列表越靠前").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Divider()
            }
            StopGroup(program: $program, index: index, isExpanded: expandedBinding("stop"))
                .configScrollAnchor("stop")
        }
        .configScrollAnchor("lifecycle")
    }

    private var outputSection: some View {
        ConfigSection {
            if program.kind == .service {
                LogGroup(program: $program, index: index, isExpanded: expandedBinding("log"))
            } else {
                ExecutionAdvancedGroup(program: $program, index: index, isExpanded: expandedBinding("log"))
            }
        }
        .configScrollAnchor("log")
    }

    private var notesSection: some View {
        ConfigSection {
            AdvancedGroup(
                title: "备注",
                summary: program.notes?.isEmpty == false ? "已添加程序说明" : "未添加",
                changedCount: 0,
                isExpanded: expandedBinding("notes")
            ) {
                TextField("记录程序用途或维护注意事项", text: optionalText($program.notes), axis: .vertical)
                    .lineLimit(3...6)
            }
        }
        .configScrollAnchor("notes")
    }

    private func expandedBinding(_ key: String, initially: Bool = false) -> Binding<Bool> {
        Binding(
            get: {
                let choices = expandedSections[program.id] ?? []
                return choices.contains(key) || (initially && !choices.contains("closed:" + key))
            },
            set: { setExpanded(key, $0) }
        )
    }

    private func setExpanded(_ key: String, _ value: Bool) {
        var choices = expandedSections[program.id] ?? []
        if value {
            choices.insert(key)
            choices.remove("closed:" + key)
        } else {
            choices.remove(key)
            choices.insert("closed:" + key)
        }
        expandedSections[program.id] = choices
    }

    private func sectionForError(_ field: FormField) -> String {
        switch field {
        case .name: return "identity"
        case .command, .directory: return "command"
        case .environment: return "environment"
        case .logPath, .stderrPath: return "log"
        case .number(let name):
            if ["logMaxBytes", "logBackups", "historyLimit"].contains(name) { return "log" }
            if name == "stopWaitSeconds" { return "stop" }
            if name == "timeoutSeconds" { return "lifecycle" }
            return "restart"
        }
    }

    private func refreshHint() {
        hint = CommandHint.evaluate(command: program.command, useShell: program.useShell, directory: program.directory)
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url { program.directory = url.path }
    }
}

// MARK: - 重启策略（服务）

struct RestartPolicyGroup: View {
    @Binding var program: Program
    let index: FieldErrorIndex
    @Binding var isExpanded: Bool

    private static let errorFields: [FormField] = [
        .number("startSeconds"), .number("startRetries"), .number("backoffBase"), .number("backoffMax"),
        .number("stormWindowSec"), .number("stormMaxRestarts")
    ]

    private var defaults: Program { Program.defaults(name: program.name, kind: program.kind, command: program.command) }

    private var changedCount: Int {
        var n = 0
        if program.startSeconds != defaults.startSeconds { n += 1 }
        if program.startRetries != defaults.startRetries { n += 1 }
        if program.backoffBase != defaults.backoffBase || program.backoffMax != defaults.backoffMax { n += 1 }
        if program.stormWindowSec != defaults.stormWindowSec || program.stormMaxRestarts != defaults.stormMaxRestarts { n += 1 }
        if program.exitCodes != defaults.exitCodes { n += 1 }
        if program.priority != defaults.priority { n += 1 }
        return n
    }

    private var summary: String {
        let defaultSummary = changedCount > 0 ? "" : "默认 · "
        return defaultSummary + "\(program.startSeconds) 秒存活，最多重试 \(program.startRetries) 次"
    }

    var body: some View {
        AdvancedGroup(
            title: "启动判定与重试",
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
                        .configField(.number("startSeconds"))
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
                        .configField(.number("startRetries"))
                    Text("次后进入启动失败").font(.caption).foregroundStyle(.secondary)
                }
            }
            FormRow(
                label: "重启间隔",
                changed: program.backoffBase != defaults.backoffBase || program.backoffMax != defaults.backoffMax,
                messages: index.messages(.number("backoffBase")) + index.messages(.number("backoffMax"))
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        DecimalField(value: $program.backoffBase)
                            .configField(.number("backoffBase"))
                        Text("秒起，失败后逐次延长").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        DecimalField(value: $program.backoffMax)
                            .configField(.number("backoffMax"))
                        Text("秒上限").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            FormRow(
                label: "重启风暴",
                changed: program.stormWindowSec != defaults.stormWindowSec || program.stormMaxRestarts != defaults.stormMaxRestarts,
                messages: index.messages(.number("stormWindowSec")) + index.messages(.number("stormMaxRestarts"))
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        IntField(value: $program.stormWindowSec)
                            .configField(.number("stormWindowSec"))
                        Text("秒内统计重启次数").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack(spacing: 6) {
                        IntField(value: $program.stormMaxRestarts)
                            .configField(.number("stormMaxRestarts"))
                        Text("次后停止自动重试").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            FormRow(label: "启动顺序", changed: program.priority != defaults.priority) {
                HStack(spacing: 6) {
                    IntField(value: $program.priority)
                        .configField(.number("priority"))
                    Text("数值越小，越先启动").font(.caption).foregroundStyle(.secondary)
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
        program.priority = defaults.priority
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

    private var defaultLimit: Int {
        Program.defaults(name: program.name, kind: program.kind, command: program.command).historyLimit
    }

    var body: some View {
        AdvancedGroup(
            title: "输出与历史",
            summary: "每次执行单独记录输出 · 保留 \(program.historyLimit) 条",
            changedCount: program.historyLimit == defaultLimit ? 0 : 1,
            hasError: index.hasError(in: [.number("historyLimit")]),
            isExpanded: $isExpanded,
            onResetAll: { program.historyLimit = defaultLimit }
        ) {
            FormRow(label: "历史保留", messages: index.messages(.number("historyLimit"))) {
                HStack(spacing: 6) {
                    IntField(value: $program.historyLimit)
                        .configField(.number("historyLimit"))
                    Text("条，超出后连同输出一并清理").font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("每次执行的输出单独保存，可从右上角的「日志」或「历史」查看。")
                .font(.caption).foregroundStyle(.secondary)
        }
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
        let defaultSummary = changedCount > 0 ? "" : "默认 · "
        return defaultSummary + "\(program.stopSignal)，\(program.stopWaitSeconds) 秒后强杀"
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
                        .configField(.number("stopWaitSeconds"))
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
    let index: FieldErrorIndex
    @Binding var isExpanded: Bool

    private static let errorFields: [FormField] = [.logPath, .stderrPath, .number("logMaxBytes"), .number("logBackups")]

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
        let defaultSummary = changedCount > 0 ? "" : "默认 · "
        switch program.logRotatePolicy {
        case .size:
            return defaultSummary + "按 \(byteSummary) 轮转，保留 \(program.logBackups) 份"
        case .onRestart:
            return defaultSummary + "重启时轮转，保留 \(program.logBackups) 份"
        case .never:
            return defaultSummary + "不轮转"
        }
    }

    private var byteSummary: String {
        ByteCountFormatter.string(fromByteCount: program.logMaxBytes, countStyle: .file)
    }

    var body: some View {
        AdvancedGroup(
            title: "日志与保留",
            summary: summary,
            changedCount: changedCount,
            hasError: index.hasError(in: Self.errorFields),
            isExpanded: $isExpanded,
            onResetAll: reset
        ) {
            FormRow(
                label: "输出路径",
                changed: program.logPath != defaults.logPath,
                messages: index.messages(.logPath)
            ) {
                TextField("默认（应用日志目录）", text: optionalText($program.logPath))
                    .configField(.logPath)
            }
            FormRow(label: "stderr", changed: program.logMergeStderr != defaults.logMergeStderr) {
                Toggle("合并到 stdout", isOn: $program.logMergeStderr)
            }
            if !program.logMergeStderr {
                FormRow(
                    label: "stderr 路径",
                    changed: program.logStderrPath != defaults.logStderrPath,
                    messages: index.messages(.stderrPath)
                ) {
                    TextField("默认（应用日志目录）", text: optionalText($program.logStderrPath))
                        .configField(.stderrPath)
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
            if program.logRotatePolicy == .size || !index.messages(.number("logMaxBytes")).isEmpty {
                FormRow(
                    label: "单文件上限",
                    changed: program.logMaxBytes != defaults.logMaxBytes,
                    messages: index.messages(.number("logMaxBytes"))
                ) {
                    ByteSizeField(bytes: $program.logMaxBytes)
                }
            }
            if program.logRotatePolicy != .never || !index.messages(.number("logBackups")).isEmpty {
                FormRow(
                    label: "保留份数",
                    changed: program.logBackups != defaults.logBackups,
                    messages: index.messages(.number("logBackups"))
                ) {
                    IntField(value: $program.logBackups)
                        .configField(.number("logBackups"))
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
                .configField(.number("logMaxBytes"))
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

/// Raw text belongs to ConfigWindowModel so even invalid edits participate in save/close guards.
struct EnvironmentEditor: View {
    @Binding var text: String
    let messages: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextEditor(text: $text)
                .font(.system(.body, design: .monospaced))
                .frame(height: 120)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))
                .configField(.environment)
                .accessibilityLabel("环境变量，每行一个 KEY=VALUE")
            ForEach(messages, id: \.self) { message in
                Label(message, systemImage: "exclamationmark.circle.fill")
                    .font(.caption).foregroundStyle(.red)
            }
            Text("每行一个 KEY=VALUE，覆盖登录环境中的同名变量。变量名前加 * 标记敏感值，导出时打码。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
