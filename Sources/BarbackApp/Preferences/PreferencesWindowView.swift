import SwiftUI
import BarbackCore

/// A single-page preferences sheet (design.md §6.6, APP-6). There are few enough settings
/// that three tabs hid two thirds of them behind a click for no gain, so 通用 / 通知 / 维护
/// are stacked as sections of one grouped form.
struct PreferencesWindowView: View {
    @ObservedObject var appState: AppState
    @AppStorage(Preferences.Key.menuDensity) private var menuDensity = MenuDensity.normal.rawValue
    @AppStorage(Preferences.Key.notifyFatal) private var notifyFatal = true
    @AppStorage(Preferences.Key.notifyRestart) private var notifyRestart = true
    @AppStorage(Preferences.Key.notifyOneshot) private var notifyOneshot = true
    @AppStorage(Preferences.Key.debounceMinutes) private var debounceMinutes = 10
    @AppStorage(Preferences.Key.logFontSize) private var logFontSize = 11.0
    @State private var loginItemEnabled = LoginItemManager.isRegistered
    @State private var snapshotRefreshedAt: Date?

    private var notificationsOff: Bool { !notifyFatal && !notifyRestart && !notifyOneshot }

    var body: some View {
        Form {
            Section {
                Toggle("开机自动启动 Barback", isOn: $loginItemEnabled)
                    .onChange(of: loginItemEnabled) { newValue in LoginItemManager.setEnabled(newValue) }
                LabeledContent("菜单密度") {
                    Picker("", selection: $menuDensity) {
                        Text("正常").tag(MenuDensity.normal.rawValue)
                        Text("紧凑").tag(MenuDensity.compact.rawValue)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 160)
                }
                LabeledContent("日志字号") {
                    Stepper(value: $logFontSize, in: 9...18) {
                        Text("\(Int(logFontSize)) pt").monospacedDigit()
                    }
                    .frame(width: 110)
                }
            } header: {
                Text("通用")
            } footer: {
                Text("紧凑密度下状态栏菜单每项只显示图标与名称，状态与指标仍在子菜单里；日志字号同时作用于日志窗口与执行历史的输出。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("服务失败（进入 FATAL、停止超时）", isOn: $notifyFatal)
                Toggle("非预期退出并自动重启", isOn: $notifyRestart)
                Toggle("一次性命令执行完成", isOn: $notifyOneshot)
                LabeledContent("服务通知去抖") {
                    Stepper(value: $debounceMinutes, in: 1...60) {
                        Text("\(debounceMinutes) 分钟").monospacedDigit()
                    }
                    .frame(width: 130)
                }
                .disabled(!notifyFatal && !notifyRestart)
            } header: {
                Text("通知")
            } footer: {
                Text(notificationsOff
                     ? "已关闭全部通知，异常仍会记录在事件日志中。"
                     : "同一服务的同类通知在窗口内只提醒一次，避免重启风暴刷屏；一次性命令的结果不去抖。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                LabeledContent("登录环境快照") {
                    HStack(spacing: 8) {
                        Button("重新抓取") {
                            appState.supervisor.refreshEnvironmentSnapshot()
                            snapshotRefreshedAt = Date()
                        }
                        if let snapshotRefreshedAt {
                            Text("已于 \(Self.timeFormatter.string(from: snapshotRefreshedAt)) 更新")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                LabeledContent("数据库备份") {
                    Button("在访达中打开") {
                        NSWorkspace.shared.open(URL(fileURLWithPath: AppPaths.backupsDir))
                    }
                }
            } header: {
                Text("维护")
            } footer: {
                Text("改动 shell 配置（如 PATH）后重新抓取，新启动的程序才会用上新的环境变量。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 460)
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
