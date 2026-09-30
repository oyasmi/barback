import SwiftUI
import BarbackCore

/// A form field that validation can point at, so errors render next to the offending
/// control instead of as one undifferentiated banner (design.md §6.5 "错误就地红字").
enum FormField: Hashable {
    case name
    case command
    case directory
    case logPath
    case stderrPath
    case environment
    case number(String)
}

/// Groups validation errors by the field they belong to.
struct FieldErrorIndex {
    private var byField: [FormField: [String]] = [:]

    init(_ errors: [ProgramValidationError], environmentErrors: [String] = [], program: Program? = nil) {
        for error in errors {
            let field: FormField
            switch error {
            case .invalidName, .duplicateName: field = .name
            case .emptyCommand, .executableNotFound: field = .command
            case .directoryNotFound: field = .directory
            case .invalidLogPath(let path): field = path == program?.logStderrPath && path != program?.logPath ? .stderrPath : .logPath
            case .invalidNumber(let name): field = .number(name)
            }
            byField[field, default: []].append(error.errorDescription ?? "")
        }
        if !environmentErrors.isEmpty { byField[.environment] = environmentErrors }
    }

    var firstField: FormField? {
        let order: [FormField] = [
            .name, .command, .directory, .environment, .number("timeoutSeconds"),
            .number("startSeconds"), .number("startRetries"), .number("backoffBase"),
            .number("backoffMax"), .number("stormWindowSec"), .number("stormMaxRestarts"),
            .number("stopWaitSeconds"), .logPath, .stderrPath, .number("logMaxBytes"),
            .number("logBackups"), .number("historyLimit")
        ]
        return order.first { byField[$0] != nil }
    }

    var count: Int { byField.count }

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

/// Shared label width gives short fields and advanced rows the same leading edge.
struct FormRow<Content: View>: View {
    let label: String
    var required: Bool = false
    var changed: Bool = false
    var messages: [String] = []
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 4) {
                    Text(label)
                    if changed {
                        Circle().fill(Color.secondary).frame(width: 4, height: 4)
                            .help("此项使用自定义值")
                    }
                }
                if required { Text("必填").font(.caption2).foregroundStyle(.secondary) }
            }
            .frame(width: 92, alignment: .leading)
            VStack(alignment: .leading, spacing: 5) {
                content
                ForEach(messages, id: \.self) { message in
                    Label(message, systemImage: "exclamationmark.circle.fill")
                        .font(.caption).foregroundStyle(.red)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ConfigSection<Content: View>: View {
    var title: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title {
                Text(title).font(.headline)
            }
            VStack(alignment: .leading, spacing: 14) { content }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)))
        }
    }
}

@MainActor
final class ConfigFieldFocusState: ObservableObject {
    @Published private(set) var request = 0
    private(set) var field: FormField?

    func focus(_ field: FormField) {
        self.field = field
        request += 1
    }
}

private struct ConfigFieldFocusModifier: ViewModifier {
    let field: FormField
    @EnvironmentObject private var focus: ConfigFieldFocusState
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focused($isFocused)
            .onChange(of: focus.request) { _ in isFocused = focus.field == field }
    }
}

extension View {
    func configField(_ field: FormField) -> some View {
        modifier(ConfigFieldFocusModifier(field: field))
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
                    Text("自定义 \(changedCount) 项")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
            .padding(.vertical, 3)
        }
        .onAppear { if hasError { isExpanded = true } }
        .onChange(of: hasError) { value in if value { isExpanded = true } }
    }

    /// A validation error keeps the section open no matter what the user last chose; once
    /// fixed, collapsing again goes back to reflecting `isExpanded` normally.
    private var expandedBinding: Binding<Bool> {
        Binding(
            get: { isExpanded || hasError },
            set: { if !hasError { isExpanded = $0 } }
        )
    }
}

/// Fixed-width numeric entry so number fields don't stretch across a wide window.
struct IntField<Value: BinaryInteger>: View {
    @Binding var value: Value
    var width: CGFloat = 68

    var body: some View {
        TextField("", value: $value, format: IntegerFormatStyle<Value>())
            .frame(width: width)
            .multilineTextAlignment(.trailing)
    }
}

struct DecimalField: View {
    @Binding var value: Double
    var width: CGFloat = 68

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

/// Remember the section at the top of each program's viewport (macOS 13 compatible).
struct ConfigScrollPositions: PreferenceKey {
    static let defaultValue: [String: CGFloat] = [:]

    static func reduce(value: inout [String: CGFloat], nextValue: () -> [String: CGFloat]) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

extension View {
    func configScrollAnchor(_ name: String) -> some View {
        id(name).background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: ConfigScrollPositions.self,
                    value: [name: geometry.frame(in: .named("configFormScroll")).minY]
                )
            }
        }
    }
}
