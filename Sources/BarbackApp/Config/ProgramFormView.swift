import SwiftUI
import BarbackCore

/// The right-hand detail form: fields switch by `kind` (design.md §6.5, CFG-3).
struct ProgramFormView: View {
    @Binding var program: Program
    let errors: [ProgramValidationError]
    let existingNames: Set<String>
    let isRunning: Bool
    let onSave: () -> Void
    let onSaveAndRestart: () -> Void
    let onRevert: () -> Void

    @State private var envText: String = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if !errors.isEmpty {
                    ErrorBanner(errors: errors)
                }
                basicSection
                if program.kind == .service {
                    startRestartSection
                    stopSection
                } else {
                    executionSection
                    stopSection
                }
                environmentSection
                logSection
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Spacer()
                Button("恢复默认") { }
                Button("保存") { onSave() }.keyboardShortcut("s", modifiers: .command)
                if isRunning {
                    Button("保存并重启") { onSaveAndRestart() }
                }
            }
            .padding()
            .background(.bar)
        }
    }

    private var header: some View {
        HStack {
            Text(program.name).font(.title2).bold()
            Spacer()
            if isRunning {
                Label("运行中", systemImage: "circle.fill").foregroundStyle(.green).font(.caption)
            }
        }
    }

    private var basicSection: some View {
        FormSection(title: "基本") {
            LabeledField("名称") { TextField("", text: $program.name) }
            LabeledField("类型") { Text(program.kind == .service ? "服务" : "一次性命令").foregroundStyle(.secondary) }
            LabeledField("命令") { TextField("/usr/bin/foo --flag", text: $program.command) }
            LabeledField("") { Toggle("通过 /bin/sh 执行", isOn: $program.useShell) }
            LabeledField("工作目录") {
                HStack {
                    TextField("~", text: Binding(get: { program.directory ?? "" }, set: { program.directory = $0.isEmpty ? nil : $0 }))
                    Button("选择") { pickDirectory() }
                }
            }
            LabeledField("分组") { TextField("默认", text: Binding(get: { program.groupName ?? "" }, set: { program.groupName = $0.isEmpty ? nil : $0 })) }
            LabeledField("优先级") { TextField("100", value: $program.priority, formatter: NumberFormatter()) }
            LabeledField("备注") { TextField("", text: Binding(get: { program.notes ?? "" }, set: { program.notes = $0.isEmpty ? nil : $0 })) }
        }
    }

    private var startRestartSection: some View {
        FormSection(title: "启动与重启") {
            LabeledField("") { Toggle("启动 Barback 时自动启动", isOn: $program.autostart) }
            LabeledField("自动重启") {
                Picker("", selection: $program.autorestart) {
                    Text("从不").tag(AutoRestartPolicy.never)
                    Text("仅异常").tag(AutoRestartPolicy.unexpected)
                    Text("总是").tag(AutoRestartPolicy.always)
                }.pickerStyle(.segmented).labelsHidden()
            }
            LabeledField("正常退出码") {
                TextField("0,2", text: Binding(
                    get: { program.exitCodes.map(String.init).joined(separator: ",") },
                    set: { program.exitCodes = $0.split(separator: ",").compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) } }
                ))
            }
            LabeledField("存活判定(秒)") { TextField("5", value: $program.startSeconds, formatter: NumberFormatter()) }
            LabeledField("启动重试(次)") { TextField("3", value: $program.startRetries, formatter: NumberFormatter()) }
            DisclosureGroup("退避与风暴") {
                LabeledField("退避基数(秒)") { TextField("1.0", value: $program.backoffBase, formatter: NumberFormatter()) }
                LabeledField("退避上限(秒)") { TextField("60", value: $program.backoffMax, formatter: NumberFormatter()) }
                LabeledField("风暴窗口(秒)") { TextField("600", value: $program.stormWindowSec, formatter: NumberFormatter()) }
                LabeledField("风暴阈值(次)") { TextField("10", value: $program.stormMaxRestarts, formatter: NumberFormatter()) }
            }
        }
    }

    private var executionSection: some View {
        FormSection(title: "执行") {
            LabeledField("超时(秒，0=不限)") { TextField("0", value: $program.timeoutSeconds, formatter: NumberFormatter()) }
            LabeledField("") { Toggle("执行前确认", isOn: $program.confirmBeforeRun) }
            LabeledField("") { Toggle("允许并发执行", isOn: $program.allowConcurrent) }
            LabeledField("历史保留(条)") { TextField("50", value: $program.historyLimit, formatter: NumberFormatter()) }
        }
    }

    private var stopSection: some View {
        FormSection(title: "停止") {
            LabeledField("停止信号") {
                Picker("", selection: $program.stopSignal) {
                    ForEach(["TERM", "INT", "HUP", "QUIT"], id: \.self) { Text($0).tag($0) }
                }.labelsHidden()
            }
            LabeledField("等待秒数") { TextField("10", value: $program.stopWaitSeconds, formatter: NumberFormatter()) }
            LabeledField("") { Toggle("按进程组停止 (stopAsGroup)", isOn: $program.stopAsGroup) }
            LabeledField("") { Toggle("按进程组强杀 (killAsGroup)", isOn: $program.killAsGroup) }
        }
    }

    private var environmentSection: some View {
        FormSection(title: "环境变量(\(program.environment.count))") {
            TextEditor(text: envBinding)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 100)
            Text("每行一个 KEY=VALUE；在 KEY 前加 * 标记敏感值（保存后打码显示）")
                .font(.caption).foregroundStyle(.secondary)
        }
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

    private var logSection: some View {
        FormSection(title: "日志") {
            LabeledField("输出路径") { TextField("默认", text: Binding(get: { program.logPath ?? "" }, set: { program.logPath = $0.isEmpty ? nil : $0 })) }
            LabeledField("") { Toggle("合并 stderr 到 stdout", isOn: $program.logMergeStderr) }
            if !program.logMergeStderr {
                LabeledField("stderr 路径") { TextField("默认", text: Binding(get: { program.logStderrPath ?? "" }, set: { program.logStderrPath = $0.isEmpty ? nil : $0 })) }
            }
            if program.kind == .service {
                LabeledField("单文件上限(字节)") { TextField("10485760", value: $program.logMaxBytes, formatter: NumberFormatter()) }
                LabeledField("保留份数") { TextField("3", value: $program.logBackups, formatter: NumberFormatter()) }
                LabeledField("轮转策略") {
                    Picker("", selection: $program.logRotatePolicy) {
                        Text("按大小").tag(LogRotatePolicy.size)
                        Text("重启时").tag(LogRotatePolicy.onRestart)
                        Text("不轮转").tag(LogRotatePolicy.never)
                    }.labelsHidden()
                }
            }
        }
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

private struct FormSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    var body: some View {
        GroupBox(title) {
            VStack(alignment: .leading, spacing: 8) { content }
                .padding(.top, 4)
        }
    }
}

private struct LabeledField<Content: View>: View {
    let label: String
    @ViewBuilder let content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }
    var body: some View {
        HStack(alignment: .top) {
            if !label.isEmpty {
                Text(label).frame(width: 110, alignment: .trailing).foregroundStyle(.secondary)
            }
            content
        }
    }
}

private struct ErrorBanner: View {
    let errors: [ProgramValidationError]
    var body: some View {
        VStack(alignment: .leading) {
            ForEach(Array(errors.enumerated()), id: \.offset) { _, error in
                Text(error.errorDescription ?? "").foregroundStyle(.red).font(.caption)
            }
        }
        .padding(8)
        .background(Color.red.opacity(0.1))
        .cornerRadius(6)
    }
}
