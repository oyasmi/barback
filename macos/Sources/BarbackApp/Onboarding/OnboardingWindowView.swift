import SwiftUI
import UserNotifications

/// First-launch welcome sheet (design.md UJ-1): explains the menu-bar-only UI, offers
/// login item + notification permission, then gets out of the way for good.
struct OnboardingWindowView: View {
    let onOpenConfig: () -> Void
    let onOpenImport: () -> Void
    let onFinish: () -> Void

    @State private var enableLoginItem = true
    @State private var enableNotifications = true

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("欢迎使用 Barback").font(.largeTitle).bold()
            Text("Barback 常驻在状态栏，没有 Dock 图标，也没有主窗口。所有操作都在菜单栏图标里完成。")
            Toggle("开机自动启动", isOn: $enableLoginItem)
            Toggle("允许系统通知（服务失败、命令完成等）", isOn: $enableNotifications)
            Divider()
            HStack {
                Button("从 supervisor 粘贴导入…") { onOpenImport() }
                Button("添加第一个程序…") { onOpenConfig() }
                Spacer()
                Button("完成") {
                    LoginItemManager.setEnabled(enableLoginItem)
                    if enableNotifications, Bundle.main.bundleIdentifier != nil {
                        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
                    }
                    onFinish()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 480)
    }
}
