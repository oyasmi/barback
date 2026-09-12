import SwiftUI
import BarbackCore

/// A form field that validation can point at, so errors render next to the offending
/// control instead of as one undifferentiated banner (design.md §6.5 "错误就地红字").
enum FormField: Hashable {
    case name
    case command
    case directory
    case number(String)
}

/// The tabs of the detail pane. Which ones are shown depends on `ProgramKind`.
enum FormTab: String, CaseIterable, Identifiable {
    case general
    case startup
    case execution
    case log

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "常规"
        case .startup: return "启动与停止"
        case .execution: return "执行与停止"
        case .log: return "日志"
        }
    }

    static func tabs(for kind: ProgramKind) -> [FormTab] {
        switch kind {
        case .service: return [.general, .startup, .log]
        case .oneshot: return [.general, .execution, .log]
        }
    }

    /// Numeric fields owned by this tab, used to badge tabs that contain an error.
    var fields: [FormField] {
        switch self {
        case .general: return [.name, .command, .directory]
        case .startup:
            return [.number("startSeconds"), .number("startRetries"), .number("backoffBase"),
                    .number("backoffMax"), .number("stopWaitSeconds")]
        case .execution:
            return [.number("timeoutSeconds"), .number("historyLimit"), .number("stopWaitSeconds")]
        case .log: return []
        }
    }
}

/// Groups validation errors by the field they belong to.
struct FieldErrorIndex {
    private var byField: [FormField: [String]] = [:]

    init(_ errors: [ProgramValidationError]) {
        for error in errors {
            let field: FormField
            switch error {
            case .invalidName, .duplicateName: field = .name
            case .emptyCommand, .executableNotFound: field = .command
            case .directoryNotFound: field = .directory
            case .invalidNumber(let name): field = .number(name)
            }
            byField[field, default: []].append(error.errorDescription ?? "")
        }
    }

    func messages(_ field: FormField) -> [String] { byField[field] ?? [] }

    func hasError(in tab: FormTab) -> Bool {
        tab.fields.contains { byField[$0] != nil }
    }

    var isEmpty: Bool { byField.isEmpty }
}

/// What the live command check found. Surfaced under the command field so a typo is
/// visible while typing rather than only on save.
enum CommandHint {
    case shell
    case resolved(String)
    case problem(String)

    var text: String {
        switch self {
        case .shell: return "将由 /bin/sh -c 执行"
        case .resolved(let path): return "解析为 \(path)"
        case .problem(let message): return message
        }
    }

    var symbol: String {
        switch self {
        case .shell: return "terminal"
        case .resolved: return "checkmark.circle"
        case .problem: return "exclamationmark.triangle"
        }
    }

    var tint: Color {
        switch self {
        case .shell: return .secondary
        case .resolved: return .green
        case .problem: return .orange
        }
    }

    static func evaluate(command: String, useShell: Bool, directory: String?) -> CommandHint? {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if useShell { return .shell }
        do {
            let tokens = try ShellLexer.tokenize(trimmed)
            guard let first = tokens.first else { return nil }
            if let resolved = PathUtil.resolveExecutable(first, directory: directory) {
                return .resolved(resolved)
            }
            return .problem("找不到可执行文件：\(first)")
        } catch {
            return .problem((error as? LocalizedError)?.errorDescription ?? "命令无法解析")
        }
    }
}

/// One labelled row plus any validation messages for it. `LabeledContent` keeps the label
/// column aligned with the plain `Form` rows around it.
struct FormRow<Content: View>: View {
    let label: String
    var messages: [String] = []
    @ViewBuilder let content: Content

    var body: some View {
        LabeledContent(label) {
            VStack(alignment: .leading, spacing: 4) {
                content
                ForEach(messages, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        }
    }
}

/// A section header carrying a "reset this section" affordance, replacing the window-wide
/// "恢复默认" button that was never implemented.
struct FormSectionHeader: View {
    let title: String
    var reset: (() -> Void)?

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            if let reset {
                Button("恢复默认值", action: reset)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
    }
}

/// Fixed-width numeric entry so number fields don't stretch across a wide window.
struct IntField<Value: BinaryInteger>: View {
    @Binding var value: Value
    var width: CGFloat = 90

    var body: some View {
        TextField("", value: $value, format: IntegerFormatStyle<Value>())
            .frame(width: width)
            .multilineTextAlignment(.trailing)
    }
}

struct DecimalField: View {
    @Binding var value: Double
    var width: CGFloat = 90

    var body: some View {
        TextField("", value: $value, format: .number)
            .frame(width: width)
            .multilineTextAlignment(.trailing)
    }
}
