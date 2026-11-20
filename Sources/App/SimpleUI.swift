import SwiftUI

/// A collapsible "More" section that keeps advanced content out of the way.
/// Each screen passes a unique key, and the open/closed state is remembered.
struct AdvancedSection<Content: View>: View {
    let title: String
    let subtitle: String?
    @AppStorage private var expanded: Bool
    private let content: Content

    init(_ title: String = "More", subtitle: String? = nil, key: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self._expanded = AppStorage(wrappedValue: false, "fight.advanced.\(key)")
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                withAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let subtitle, !expanded {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 0 : -90))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            .accessibilityHint(expanded ? "Hides extra options" : "Shows extra options")

            if expanded {
                content
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

/// The standard rounded card used across the app.
struct CardBackground: ViewModifier {
    var tint: Color? = nil
    func body(content: Content) -> some View {
        content
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background((tint ?? Color(.secondarySystemBackground)).opacity(tint == nil ? 1 : 0.12),
                        in: RoundedRectangle(cornerRadius: 20))
    }
}

extension View {
    func card(tint: Color? = nil) -> some View { modifier(CardBackground(tint: tint)) }
}
