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
                FormRow(label: "名称", messages: index.messages(.name)) {
                    TextField("", text: $program.name)
                        .frame(maxWidth: 260)
                }
                Toggle("启用", isOn: $program.enabled)
            } header: {
                FormSectionHeader(title: "标识")
            } footer: {
                Text("名称用于日志文件名与状态栏菜单，只能包含字母、数字、`.`、`_`、`-`。停用后不会随 Barback 启动，也不参与「全部启动」。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                        Text("数字越小越先启动").font(.caption).foregroundStyle(.secondary)
                    }
                }
                FormRow(label: "备注") {
                    TextField("", text: optionalText($program.notes), axis: .vertical)
                        .lineLimit(2...4)
                }
            } header: {
                FormSectionHeader(title: "组织")
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshHint() }
        .onChange(of: program.command) { _ in refreshHint() }
        .onChange(of: program.useShell) { _ in refreshHint() }
        .onChange(of: program.directory) { _ in refreshHint() }
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

// MARK: - 启动与重启（服务）

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
                FormRow(label: "正常退出码") {
                    TextField("0,2", text: exitCodesBinding)
                        .frame(maxWidth: 140)
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
        }
        .formStyle(.grouped)
    }

    private var exitCodesBinding: Binding<String> {
        Binding(
            get: { program.exitCodes.map(String.init).joined(separator: ",") },
            set: { program.exitCodes = $0.split(separator: ",").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) } }
        )
    }

    private func resetStartup() {
        let defaults = Program(name: program.name, kind: program.kind, command: program.command)
        program.autostart = defaults.autostart
        program.autorestart = defaults.autorestart
        program.exitCodes = defaults.exitCodes
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

// MARK: - 执行（一次性命令）

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
                Toggle("允许并发执行", isOn: $program.allowConcurrent)
                FormRow(label: "历史保留", messages: index.messages(.number("historyLimit"))) {
                    HStack(spacing: 6) {
                        IntField(value: $program.historyLimit)
                        Text("条，超出后连同输出一并清理").font(.caption).foregroundStyle(.secondary)
                    }
                }
            } header: {
                FormSectionHeader(title: "执行", reset: resetExecution)
            }
        }
        .formStyle(.grouped)
    }

    private func resetExecution() {
        let defaults = Program(name: program.name, kind: program.kind, command: program.command)
        program.timeoutSeconds = defaults.timeoutSeconds
        program.confirmBeforeRun = defaults.confirmBeforeRun
        program.allowConcurrent = defaults.allowConcurrent
        program.historyLimit = defaults.historyLimit
    }
}

// MARK: - 停止

struct StopTab: View {
    @Binding var program: Program
    let index: FieldErrorIndex

    var body: some View {
        Form {
            Section {
                FormRow(label: "停止信号") {
                    Picker("", selection: $program.stopSignal) {
                        ForEach(["TERM", "INT", "HUP", "QUIT"], id: \.self) { Text($0).tag($0) }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 140)
                }
                FormRow(label: "等待秒数", messages: index.messages(.number("stopWaitSeconds"))) {
                    HStack(spacing: 6) {
                        IntField(value: $program.stopWaitSeconds)
                        Text("秒后发送 KILL").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Toggle("按进程组停止", isOn: $program.stopAsGroup)
                Toggle("按进程组强杀", isOn: $program.killAsGroup)
            } header: {
                FormSectionHeader(title: "停止", reset: resetStop)
            } footer: {
                Text("按进程组操作会把信号发给整棵子进程树，适合会派生子进程的服务。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func resetStop() {
        let defaults = Program(name: program.name, kind: program.kind, command: program.command)
        program.stopSignal = defaults.stopSignal
        program.stopWaitSeconds = defaults.stopWaitSeconds
        program.stopAsGroup = defaults.stopAsGroup
        program.killAsGroup = defaults.killAsGroup
    }
}

// MARK: - 环境变量

struct EnvironmentTab: View {
    @Binding var program: Program

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("每行一个 KEY=VALUE")
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(program.environment.count) 个变量")
                    .foregroundStyle(.secondary)
            }
            .font(.caption)

            TextEditor(text: envBinding)
                .font(.system(.body, design: .monospaced))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))

            Text("在 KEY 前加 `*` 标记敏感值（保存后在导出与诊断包中打码）。这里的变量会覆盖登录环境快照中的同名变量。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
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
