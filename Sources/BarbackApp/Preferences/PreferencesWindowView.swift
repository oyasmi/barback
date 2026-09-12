import SwiftUI
import BarbackCore

/// Three-tab preferences (design.md §6.6, APP-6): General / Notifications / Advanced.
struct PreferencesWindowView: View {
    @ObservedObject var appState: AppState
    @AppStorage("barback.menuDensity") private var menuDensity = "normal"
    @AppStorage("barback.notif.fatal") private var notifyFatal = true
    @AppStorage("barback.notif.restart") private var notifyRestart = true
    @AppStorage("barback.notif.oneshot") private var notifyOneshot = true
    @AppStorage("barback.notif.debounceMinutes") private var debounceMinutes = 10
    @AppStorage("barback.logFontSize") private var logFontSize = 11.0
    @State private var loginItemEnabled = LoginItemManager.isRegistered

    var body: some View {
        TabView {
            generalTab.tabItem { Label("通用", systemImage: "gearshape") }
            notificationsTab.tabItem { Label("通知", systemImage: "bell") }
            advancedTab.tabItem { Label("高级", systemImage: "wrench.and.screwdriver") }
        }
        .padding()
        .frame(width: 480, height: 380)
    }

    private var generalTab: some View {
        Form {
            Toggle("开机自动启动", isOn: $loginItemEnabled)
                .onChange(of: loginItemEnabled) { newValue in LoginItemManager.setEnabled(newValue) }
            Picker("菜单密度", selection: $menuDensity) {
                Text("正常").tag("normal")
                Text("紧凑").tag("compact")
            }
        }
    }

    private var notificationsTab: some View {
        Form {
            Toggle("进入 FATAL 时通知", isOn: $notifyFatal)
            Toggle("非预期退出并重启时通知", isOn: $notifyRestart)
            Toggle("一次性命令完成时通知", isOn: $notifyOneshot)
            Stepper("同类去抖窗口：\(debounceMinutes) 分钟", value: $debounceMinutes, in: 1...60)
        }
    }

    private var advancedTab: some View {
        Form {
            Stepper("日志字号：\(Int(logFontSize))", value: $logFontSize, in: 9...18)
            Button("刷新登录环境快照") { appState.supervisor.refreshEnvironmentSnapshot() }
            Button("打开数据库备份目录") { NSWorkspace.shared.open(URL(fileURLWithPath: AppPaths.backupsDir)) }
        }
    }
}
