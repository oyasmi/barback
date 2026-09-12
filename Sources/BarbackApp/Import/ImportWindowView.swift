import SwiftUI
import BarbackCore

/// Paste-in supervisor INI import with a mapping preview (design.md §7, UJ-7).
struct ImportWindowView: View {
    @ObservedObject var appState: AppState
    let onClose: () -> Void

    @State private var rawText = ""
    @State private var previews: [ImportPreview] = []
    @State private var selected: Set<Int> = []
    @State private var imported = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("粘贴一段或多段 supervisor `[program:x]` INI 文本").font(.headline)
            TextEditor(text: $rawText)
                .font(.system(.body, design: .monospaced))
                .frame(minHeight: 140)
                .border(Color.secondary.opacity(0.3))
            HStack {
                Button("解析") { parse() }
                Spacer()
                if !previews.isEmpty {
                    Button("全选") { selected = Set(previews.indices) }
                    Button("全不选") { selected.removeAll() }
                }
            }
            if !previews.isEmpty {
                List {
                    ForEach(Array(previews.enumerated()), id: \.offset) { index, preview in
                        previewRow(index: index, preview: preview)
                    }
                }
            }
            HStack {
                Text("导入后请先执行 `supervisorctl stop all` 并停用 supervisord，再在 Barback 中启动。")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("取消") { onClose() }
                Button("导入选中项") { doImport() }.disabled(selected.isEmpty)
            }
        }
        .padding()
    }

    private func previewRow(index: Int, preview: ImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(isOn: Binding(
                    get: { selected.contains(index) },
                    set: { on in if on { selected.insert(index) } else { selected.remove(index) } }
                )) {
                    Text(preview.program.name).bold()
                }
                Spacer()
                Text("autostart=false").font(.caption).foregroundStyle(.secondary)
            }
            Text("command: \(preview.program.command)\(preview.program.useShell ? "  (via /bin/sh)" : "")").font(.caption)
            Text("autorestart: \(preview.program.autorestart.rawValue) · stopSignal: \(preview.program.stopSignal)").font(.caption)
            if !preview.unmapped.isEmpty {
                Text("无法映射：" + preview.unmapped.map { "\($0.key)(\($0.reason))" }.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
    }

    private func parse() {
        previews = SupervisorImporter.parse(rawText)
        selected = Set(previews.indices)
    }

    private func doImport() {
        let drafts = selected.sorted().map { previews[$0].program }
        appState.supervisor.importPrograms(drafts) { _ in
            DispatchQueue.main.async { onClose() }
        }
    }
}
