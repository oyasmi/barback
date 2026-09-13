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

    /// Whether any of the given fields carries an error — used to force an `AdvancedGroup`
    /// open even while collapsed, so a validation error can never hide inside a folded section.
    func hasError(in fields: [FormField]) -> Bool {
        fields.contains { byField[$0] != nil }
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
///
/// `required` marks a field that must not be left empty (shown only while it actually is
/// empty, so it never lingers as noise once filled in). `changed` marks a field inside an
/// `AdvancedGroup` whose value differs from `Program`'s built-in default — a small dot ahead
/// of the label, so a folded-open section shows at a glance which of its rows were actually
/// touched versus left at the suggested value.
struct FormRow<Content: View>: View {
    let label: String
    var required: Bool = false
    var changed: Bool = false
    var messages: [String] = []
    @ViewBuilder let content: Content

    var body: some View {
        LabeledContent {
            VStack(alignment: .leading, spacing: 4) {
                content
                ForEach(messages, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
        } label: {
            HStack(spacing: 5) {
                if changed {
                    Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                }
                Text(label)
                if required {
                    Text("必填")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Color.secondary.opacity(0.15), in: Capsule())
                }
            }
        }
    }
}

/// A collapsible "advanced" block: collapsed by default, its label carrying a one-line
/// summary of the section's *current effective* settings so the page stays scannable without
/// expanding anything — reading "默认 · 5 秒存活，最多重试 3 次" tells you as much as opening
/// the section would. Only the delta from `Program`'s defaults is worth flagging, so a
/// changed-count badge appears once anything inside differs from that baseline, and a
/// validation error inside forces the section open regardless of its stored collapse state
/// (an error can never end up hidden behind a fold).
///
/// The "恢复默认值" action lives inside the expanded content, not the (tappable-to-toggle)
/// label row, so tapping it can never also fire the disclosure toggle.
struct AdvancedGroup<Content: View>: View {
    let title: String
    let summary: String
    let changedCount: Int
    var hasError: Bool = false
    @Binding var isExpanded: Bool
    var onResetAll: (() -> Void)?
    @ViewBuilder let content: Content

    var body: some View {
        DisclosureGroup(isExpanded: expandedBinding) {
            VStack(alignment: .leading, spacing: 12) {
                content
                if changedCount > 0, let onResetAll {
                    HStack {
                        Spacer()
                        Button("恢复本节默认值", action: onResetAll)
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 8) {
                if hasError {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                        .imageScale(.small)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(title)
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if changedCount > 0 {
                    Text("已改动 \(changedCount) 项")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
            .padding(.vertical, 3)
        }
    }

    /// A validation error keeps the section open no matter what the user last chose; once
    /// fixed, collapsing again goes back to reflecting `isExpanded` normally.
    private var expandedBinding: Binding<Bool> {
        Binding(
            get: { isExpanded || hasError },
            set: { isExpanded = $0 }
        )
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

/// Bridges an optional string field to a `TextField`, treating empty input as "unset" so
/// the stored value stays `nil` rather than becoming an empty string.
func optionalText(_ binding: Binding<String?>) -> Binding<String> {
    Binding(
        get: { binding.wrappedValue ?? "" },
        set: { binding.wrappedValue = $0.isEmpty ? nil : $0 }
    )
}
