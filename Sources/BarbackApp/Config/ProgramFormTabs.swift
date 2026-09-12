import SwiftUI
import AppKit
import BarbackCore

// MARK: - 常规

struct GeneralTab: View {
    @Binding var program: Program
    let index: FieldErrorIndex
    var existingGroups: [String] = []

    @State private var hint: CommandHint?

    var body: some View {
        Form {
            Section {
                FormRow(label: "命令", messages: index.messages(.command)) {
                    TextField("/usr/local/bin/foo --flag", text: $program.command, axis: .vertical)
                        .font(.system(.body, design: .monospaced))
                        .lineLimit(2...6)
                    Toggle("通过 /bin/sh 执行", isOn: $program.useShell)
                    if let hint {
                        Label(hint.text, systemImage: hint.symbol)
                            .font(.caption)
                            .foregroundStyle(hint.tint)
                            .textSelection(.enabled)
                    }
                }
                FormRow(label: "工作目录", messages: index.messages(.directory)) {
                    HStack {
                        TextField("~", text: optionalText($program.directory))
                        Button("选择…") { pickDirectory() }
                    }
                }
            } header: {
                FormSectionHeader(title: "命令")
            }

            Section {
                FormRow(label: "名称", messages: index.messages(.name)) {
                    TextField("", text: $program.name)
                        .frame(maxWidth: 260)
                }
                FormRow(label: "分组") {
                    HStack {
                        TextField("默认", text: optionalText($program.groupName))
                            .frame(maxWidth: 200)
                        if !existingGroups.isEmpty {
                            Menu("") {
                                ForEach(existingGroups, id: \.self) { group in
                                    Button(group) { program.groupName = group }
                                }
                            }
                            .menuStyle(.borderlessButton)
                            .frame(width: 16)
                        }
                    }
                }
                FormRow(label: "优先级") {
                    HStack(spacing: 8) {
                        IntField(value: $program.priority)
                        Text("越小越先启动").font(.caption).foregroundStyle(.secondary)
                    }
                }
                FormRow(label: "备注") {
                    TextField("", text: optionalText($program.notes), axis: .vertical)
                        .lineLimit(2...4)
                }
                Toggle("启用", isOn: $program.enabled)
            } header: {
                FormSectionHeader(title: "标识与分组")
            } footer: {
                Text("名称用于日志文件名与状态栏菜单，只能包含字母、数字、`.`、`_`、`-`。停用后不会随 Barback 启动，也不参与「全部启动」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                EnvironmentEditor(program: $program)
            } header: {
                FormSectionHeader(title: environmentTitle)
            } footer: {
                Text("每行一个 KEY=VALUE，覆盖登录环境快照中的同名变量；在 KEY 前加 `*` 标记敏感值，导出与诊断包中会打码。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshHint() }
        .onChange(of: program.command) { _ in refreshHint() }
        .onChange(of: program.useShell) { _ in refreshHint() }
        .onChange(of: program.directory) { _ in refreshHint() }
    }

    private var environmentTitle: String {
        program.environment.isEmpty ? "环境变量" : "环境变量（\(program.environment.count)）"
    }

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

// MARK: - 启动与停止（服务）

struct StartupTab: View {
    @Binding var program: Program
    let index: FieldErrorIndex

    var body: some View {
        Form {
            Section {
                Toggle("启动 Barback 时自动启动", isOn: $program.autostart)
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
                FormRow(label: "存活判定", messages: index.messages(.number("startSeconds"))) {
                    HStack(spacing: 6) {
                        IntField(value: $program.startSeconds)
                        Text("秒后视为启动成功").font(.caption).foregroundStyle(.secondary)
                    }
                }
                FormRow(label: "启动重试", messages: index.messages(.number("startRetries"))) {
                    HStack(spacing: 6) {
                        IntField(value: $program.startRetries)
                        Text("次后进入启动失败").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                FormSectionHeader(title: "启动与重启", reset: resetStartup)
            }

            Section {
                FormRow(label: "退避基数", messages: index.messages(.number("backoffBase"))) {
                    HStack(spacing: 6) {
                        DecimalField(value: $program.backoffBase)
                        Text("秒").font(.caption).foregroundStyle(.secondary)
                    }
                }
                FormRow(label: "退避上限", messages: index.messages(.number("backoffMax"))) {
                    HStack(spacing: 6) {
                        DecimalField(value: $program.backoffMax)
                        Text("秒").font(.caption).foregroundStyle(.secondary)
                    }
                }
                FormRow(label: "风暴窗口") {
                    HStack(spacing: 6) {
                        IntField(value: $program.stormWindowSec)
                        Text("秒").font(.caption).foregroundStyle(.secondary)
                    }
                }
                FormRow(label: "风暴阈值") {
                    HStack(spacing: 6) {
                        IntField(value: $program.stormMaxRestarts)
                        Text("次重启后停止重试").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                FormSectionHeader(title: "退避与风暴", reset: resetBackoff)
            } footer: {
                Text("重启间隔按退避基数指数增长，不超过退避上限；窗口内重启次数达到阈值即判定为重启风暴。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ExitCodesSection(program: $program)
            StopSection(program: $program, index: index)
        }
        .formStyle(.grouped)
    }

    private func resetStartup() {
        let defaults = Program(name: program.name, kind: program.kind, command: program.command)
        program.autostart = defaults.autostart
        program.autorestart = defaults.autorestart
        program.startSeconds = defaults.startSeconds
        program.startRetries = defaults.startRetries
    }

    private func resetBackoff() {
        let defaults = Program(name: program.name, kind: program.kind, command: program.command)
        program.backoffBase = defaults.backoffBase
        program.backoffMax = defaults.backoffMax
        program.stormWindowSec = defaults.stormWindowSec
        program.stormMaxRestarts = defaults.stormMaxRestarts
    }
}

// MARK: - 执行与停止（一次性命令）

struct ExecutionTab: View {
    @Binding var program: Program
    let index: FieldErrorIndex

    var body: some View {
        Form {
            Section {
                FormRow(label: "超时", messages: index.messages(.number("timeoutSeconds"))) {
                    HStack(spacing: 6) {
                        IntField(value: $program.timeoutSeconds)
                        Text("秒，0 表示不限").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("执行前确认", isOn: $program.confirmBeforeRun)
                FormRow(label: "历史保留", messages: index.messages(.number("historyLimit"))) {
                    HStack(spacing: 6) {
                        IntField(value: $program.historyLimit)
                        Text("条，超出后连同输出一并清理").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                FormSectionHeader(title: "执行", reset: resetExecution)
            }

            ExitCodesSection(program: $program)
            StopSection(program: $program, index: index)
        }
        .formStyle(.grouped)
    }

    private func resetExecution() {
        let defaults = Program(name: program.name, kind: program.kind, command: program.command)
        program.timeoutSeconds = defaults.timeoutSeconds
        program.confirmBeforeRun = defaults.confirmBeforeRun
        program.historyLimit = defaults.historyLimit
    }
}

// MARK: - 停止（服务与一次性命令共用）

/// The stop settings, shown as the last section of whichever lifecycle tab the program kind
/// gets — "启动与停止" for services, "执行与停止" for one-shots.
struct StopSection: View {
    @Binding var program: Program
    let index: FieldErrorIndex

    var body: some View {
        Section {
            FormRow(label: "停止信号") {
                Picker("", selection: $program.stopSignal) {
                    ForEach(["TERM", "INT", "HUP", "QUIT"], id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(maxWidth: 140)
            }
            FormRow(label: "强杀等待", messages: index.messages(.number("stopWaitSeconds"))) {
                HStack(spacing: 6) {
                    IntField(value: $program.stopWaitSeconds)
                    Text("秒后发送 KILL").font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("停止时发送给整个进程组", isOn: $program.stopAsGroup)
            Toggle("强杀时发送给整个进程组", isOn: $program.killAsGroup)
        } header: {
            FormSectionHeader(title: "停止", reset: resetStop)
        } footer: {
            Text("按进程组发送会把信号送达整棵子进程树，适合会派生子进程的命令。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func resetStop() {
        let defaults = Program(name: program.name, kind: program.kind, command: program.command)
        program.stopSignal = defaults.stopSignal
        program.stopWaitSeconds = defaults.stopWaitSeconds
        program.stopAsGroup = defaults.stopAsGroup
        program.killAsGroup = defaults.killAsGroup
    }
}

/// The "normal exit code" field used to live only on the service tab, so a one-shot's
/// success/failure judgment — which reads this same `exitCodes` field — was permanently
/// stuck at the default `[0]` with no way to change it (design.md §3.4, ex-F13). Shared here
/// the same way `StopSection` is, so both tabs get it.
struct ExitCodesSection: View {
    @Binding var program: Program

    var body: some View {
        Section {
            FormRow(label: "正常退出码") {
                TextField("0,2", text: exitCodesBinding)
                    .frame(maxWidth: 140)
            }
        } header: {
            FormSectionHeader(title: "退出码", reset: resetExitCodes)
        } footer: {
            Text("一次退出的退出码不在此列表中时，判定为失败。").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var exitCodesBinding: Binding<String> {
        Binding(
            get: { program.exitCodes.map(String.init).joined(separator: ",") },
            set: { program.exitCodes = $0.split(separator: ",").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) } }
        )
    }

    private func resetExitCodes() {
        let defaults = Program(name: program.name, kind: program.kind, command: program.command)
        program.exitCodes = defaults.exitCodes
    }
}

// MARK: - 环境变量

/// The KEY=VALUE editor, embedded as a section of 常规 rather than a tab of its own.
struct EnvironmentEditor: View {
    @Binding var program: Program

    var body: some View {
        TextEditor(text: envBinding)
            .font(.system(.body, design: .monospaced))
            .frame(minHeight: 120)
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

// MARK: - 日志

struct LogTab: View {
    @Binding var program: Program

    var body: some View {
        Form {
            // A one-shot's output always lands in `runs/<name>-<runId>.log`, one file per
            // execution — `openRunLog` never looks at `logPath`/`logStderrPath` at all. Showing
            // this section for one-shots let someone fill in a path that silently did nothing,
            // while `ProgramLogPath.resolve` favored the very same unused field over the real
            // per-run file, so the log window opened a path that was never written to
            // (design.md §4, ex-F11).
            if program.kind == .service {
                Section {
                    FormRow(label: "输出路径") {
                        TextField("默认（应用日志目录）", text: optionalText($program.logPath))
                    }
                    Toggle("合并 stderr 到 stdout", isOn: $program.logMergeStderr)
                    if !program.logMergeStderr {
                        FormRow(label: "stderr 路径") {
                            TextField("默认（应用日志目录）", text: optionalText($program.logStderrPath))
                        }
                    }
                } header: {
                    FormSectionHeader(title: "输出")
                }
            }

            if program.kind == .service {
                Section {
                    FormRow(label: "轮转策略") {
                        Picker("", selection: $program.logRotatePolicy) {
                            Text("按大小").tag(LogRotatePolicy.size)
                            Text("重启时").tag(LogRotatePolicy.onRestart)
                            Text("不轮转").tag(LogRotatePolicy.never)
                        }
                        .labelsHidden()
                        .frame(maxWidth: 160)
                    }
                    if program.logRotatePolicy == .size {
                        FormRow(label: "单文件上限") {
                            HStack(spacing: 6) {
                                IntField(value: $program.logMaxBytes, width: 130)
                                Text("字节（\(byteSummary)）").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    FormRow(label: "保留份数") {
                        IntField(value: $program.logBackups)
                    }
                } header: {
                    FormSectionHeader(title: "轮转", reset: resetRotation)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var byteSummary: String {
        ByteCountFormatter.string(fromByteCount: program.logMaxBytes, countStyle: .file)
    }

    private func resetRotation() {
        let defaults = Program(name: program.name, kind: program.kind, command: program.command)
        program.logMaxBytes = defaults.logMaxBytes
        program.logBackups = defaults.logBackups
        program.logRotatePolicy = defaults.logRotatePolicy
    }
}

// MARK: - Shared

/// Bridges an optional string field to a `TextField`, treating empty input as "unset" so
/// the stored value stays `nil` rather than becoming an empty string.
func optionalText(_ binding: Binding<String?>) -> Binding<String> {
    Binding(
        get: { binding.wrappedValue ?? "" },
        set: { binding.wrappedValue = $0.isEmpty ? nil : $0 }
    )
}
