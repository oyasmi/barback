import SwiftUI

/// The small controls the status panel is built from. They are deliberately hand-rolled
/// rather than `.bordered` buttons: a menu-bar panel is dense, and the stock control
/// metrics leave no room for four actions plus a status line on one row.

/// The row's primary verb — 启动 / 停止 / 运行 / 中止. Tinted by consequence, so the
/// destructive direction never looks like the constructive one — but only once it is
/// `isEmphasized` (the row is approached, or the action is urgent). At rest it is a neutral
/// capsule, so a healthy panel doesn't wear a red 停止 on every line (StatusStyle.PrimaryAction).
struct PillButton: View {
    let title: String
    let systemImage: String
    var tint: Color = .accentColor
    var isEnabled = true
    var isEmphasized = true
    var help = ""
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(ink)
            .frame(height: 21)
            .padding(.horizontal, 9)
            .background(Capsule().fill(ink.opacity(fillOpacity)))
            .overlay(Capsule().stroke(ink.opacity(strokeOpacity), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .animation(.easeOut(duration: 0.14), value: isEmphasized)
    }

    private var isTinted: Bool { isEnabled && (isEmphasized || isHovering) }

    private var ink: Color { isTinted ? tint : Color.secondary }

    private var fillOpacity: Double {
        guard isEnabled else { return 0.07 }
        guard isTinted else { return 0.08 }
        return isHovering ? 0.26 : 0.14
    }

    private var strokeOpacity: Double {
        guard isEnabled else { return 0.12 }
        return isTinted ? 0.22 : 0.16
    }
}

/// A secondary action: icon only, no chrome until hovered.
struct GlyphButton: View {
    let systemImage: String
    let help: String
    var tint: Color?
    var isEnabled = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(foreground)
                .frame(width: 22, height: 21)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.primary.opacity(isHovering && isEnabled ? 0.1 : 0))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .help(help)
        .accessibilityLabel(help)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
    }

    private var foreground: Color {
        guard isEnabled else { return .secondary.opacity(0.4) }
        if let tint { return tint }
        return isHovering ? .primary : .secondary
    }
}

/// A labelled action inside the expanded drawer, where there is room for words.
struct DrawerButton: View {
    let title: String
    let systemImage: String
    var tint: Color?
    var isEnabled = true
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .medium))
                Text(title)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .foregroundStyle(isEnabled ? (tint ?? .primary) : Color.secondary.opacity(0.5))
            .frame(maxWidth: .infinity)
            .frame(height: 22)
            .padding(.horizontal, 6)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(isHovering && isEnabled ? 0.09 : 0.045))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
    }
}

/// One count in the header summary. Dot + number + word: readable without colour.
///
/// Also a filter toggle: clicking 「⚠ 1 失败」 narrows the list to that one row, which is the
/// question someone opening the panel after a notification is actually asking. A zero count
/// has nothing to narrow to and doesn't respond.
struct SummaryChip: View {
    let count: Int
    let label: String
    let color: Color
    let symbol: String
    var showsLabel = true
    var isSelected = false
    /// Another chip's filter is on; this one steps back so the selected one reads as selected.
    var isDimmed = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(color)
                Text("\(count)")
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                if showsLabel {
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(fillOpacity)))
            .overlay(Capsule().stroke(color.opacity(isSelected ? 0.6 : 0), lineWidth: 1))
            .opacity(isDimmed ? 0.55 : 1)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .help(isSelected ? String(localized: "\(label) · 点按显示全部") : String(localized: "\(label) · 点按只看这一类"))
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.14), value: isHovering)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(count) 项\(label)")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : [.isButton])
    }

    private var fillOpacity: Double {
        if isSelected { return 0.22 }
        return isHovering && count > 0 ? 0.17 : 0.1
    }
}

/// A glyph that opens a menu — the footer's chevron of less common bulk actions.
///
/// On macOS a SwiftUI `Menu` is drawn by an AppKit pop-up button, which flattens any custom
/// label down to an image and a title; so this keeps to a bare symbol, sized to sit on the
/// same 22 × 21 grid as `GlyphButton`.
struct MenuGlyph<Content: View>: View {
    let systemImage: String
    let help: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Menu(content: content) {
            Image(systemName: systemImage)
                .font(.system(size: 11, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .frame(width: 22, height: 21)
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The state badge that sits beside a program's name.
///
/// `quiet` is for the states that need no attention (运行中 / 成功): they keep their colour on
/// the row's dot and accent bar, but their badge drops to plain secondary text so a screen of
/// healthy services doesn't spend the whole colour budget saying "fine" (StatusStyle.isQuiet).
struct StateBadge: View {
    let text: String
    let color: Color
    var quiet = false

    var body: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .medium))
            .monospacedDigit()
            .foregroundStyle(quiet ? Color.secondary : color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(quiet ? Color.primary.opacity(0.06) : color.opacity(0.13)))
            .fixedSize()
    }
}

/// A neutral tag: 已停用 / 分组名 / 一次性.
struct MetaTag: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .fixedSize()
    }
}

/// Countdown / progress hairline, used for the backoff timer.
struct HairlineProgress: View {
    let fraction: Double
    let color: Color

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(color.opacity(0.15))
                Capsule()
                    .fill(color.opacity(0.8))
                    .frame(width: max(0, min(1, fraction)) * geo.size.width)
            }
        }
        .frame(height: 3)
    }
}

/// Reports the laid-out height of the content, so the panel can cap itself and start
/// scrolling instead of growing off the screen.
struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension View {
    func measuringHeight() -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(key: ContentHeightKey.self, value: geo.size.height)
            }
        )
    }
}
