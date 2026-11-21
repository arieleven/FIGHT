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

/// A small unit switch that sits next to a number: tap it or swipe it up/down
/// to roll between two units (e.g. kg ⇄ lb). The value itself is stored in one
/// unit, so switching never changes the underlying number.
struct UnitChip: View {
    let metric: String
    let imperial: String
    @Binding var isImperial: Bool
    var accessibilityName = "Unit"

    @State private var direction: Edge = .bottom

    var body: some View {
        let label = isImperial ? imperial : metric
        HStack(spacing: 3) {
            Text(label)
                .font(.subheadline.weight(.bold))
                .id(label)
                .transition(.asymmetric(insertion: .move(edge: direction).combined(with: .opacity),
                                        removal: .move(edge: direction == .bottom ? .top : .bottom).combined(with: .opacity)))
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 52, minHeight: 32)
        .padding(.horizontal, 6)
        .background(Color(.tertiarySystemFill), in: Capsule())
        .clipShape(Capsule())
        .contentShape(Capsule())
        .onTapGesture { flip(up: true) }
        .gesture(
            DragGesture(minimumDistance: 8).onEnded { v in
                if abs(v.translation.height) > abs(v.translation.width) {
                    flip(up: v.translation.height < 0)
                }
            }
        )
        .sensoryFeedback(.selection, trigger: isImperial)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityName)
        .accessibilityValue(label)
        .accessibilityHint("Swipe up or down to change unit")
        .accessibilityAddTraits(.isButton)
        .accessibilityAdjustableAction { _ in flip(up: true) }
        .accessibilityAction { flip(up: true) }
    }

    private func flip(up: Bool) {
        direction = up ? .bottom : .top
        withAnimation(.snappy(duration: 0.25)) { isImperial.toggle() }
    }
}
