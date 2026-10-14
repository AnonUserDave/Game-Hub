import SwiftUI

/// Hub design tokens. The library is a dark, wood-panelled den with lit
/// display shelves: each game's own accent lights its place on the shelf, and
/// amber marks keyboard/controller focus and the primary action. Display type
/// is Futura Condensed, which ships with macOS; everything else uses the
/// system face. Nothing in the hub animates while idle.
enum Hub {
    static let walnut = Color(hex: "16110D")
    static let den = Color(hex: "100C09")
    static let panel = Color(hex: "1E1712")
    static let raised = Color(hex: "2A201A")
    static let plank = Color(hex: "3D2E24")
    static let label = Color(hex: "F4EADB")
    static let dust = Color(hex: "A79784")
    static let amber = Color(hex: "FFB54A")
    static let onAmber = Color(hex: "21160B")
    static let rule = Color.white.opacity(0.07)

    static func display(_ size: CGFloat) -> Font { .custom("Futura-CondensedExtraBold", size: size) }
}

/// Filled amber button for the one primary action on screen.
struct HubPrimaryButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 14, weight: .semibold))
            .foregroundStyle(Hub.onAmber)
            .padding(.horizontal, compact ? 14 : 18).padding(.vertical, compact ? 7 : 10)
            .background(Hub.amber.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// Quiet bordered button for secondary actions.
struct HubSecondaryButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var isEnabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .foregroundStyle(Hub.label)
            .padding(.horizontal, compact ? 12 : 14).padding(.vertical, compact ? 6 : 8)
            .background(Hub.raised.opacity(configuration.isPressed ? 1 : 0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(Hub.rule))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

/// A keyboard key or controller button shown in the hints bar.
struct KeyCap: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(Hub.label.opacity(0.9))
            .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 17)
            .background(Hub.raised, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 4, style: .continuous).strokeBorder(.white.opacity(0.09)))
    }
}

/// Close control shared by the hub's sheets; Escape and controller B dismiss.
struct SheetCloseButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Hub.dust)
                .frame(width: 28, height: 28).background(Hub.raised, in: Circle())
        }
        .buttonStyle(.plain).keyboardShortcut(.cancelAction).help("Close").accessibilityLabel("Close")
    }
}
