import SwiftUI

/// Burrow — "Night Light". The notch is a burrow the agents' pets live in.
///
/// Every colour, type size, radius and spring the burrow surfaces use lives
/// here, so the look is decided in one place (design/v04/burrow.html is the
/// reference prototype).
enum Burrow {
    // MARK: Colour

    /// Warm paper white for primary text and the default button.
    static let ink = Color(red: 0.953, green: 0.933, blue: 0.902)          // #F3EEE6
    /// Secondary text: project names, times, hints.
    static let dim = Color(red: 0.608, green: 0.584, blue: 0.553)          // #9B958D
    /// Hairlines between groups.
    static let line = Color.white.opacity(0.09)
    /// Row and button hover.
    static let hover = Color.white.opacity(0.06)
    /// Inset wells: command boxes, option rows.
    static let well = Color.white.opacity(0.05)
    static let wellEdge = Color.white.opacity(0.06)
    /// Text on the filled (primary) button.
    static let onInk = Color(red: 0.071, green: 0.067, blue: 0.063)        // #121110
    /// "Needs you" — a lamp left on.
    static let amber = Color(red: 0.961, green: 0.718, blue: 0.392)        // #F5B764
    /// Clawd's own orange, the same as its sprite (PetSprites `.clawd`).
    static let clawd = Color(red: 0.871, green: 0.533, blue: 0.427)        // #DE886D
    /// A turn that failed.
    static let ember = Color(red: 0.937, green: 0.455, blue: 0.408)        // #EF7468
    /// A turn that finished and you have not looked at yet.
    static let spark = Color(red: 1.0, green: 0.953, blue: 0.863)          // #FFF3DC
    /// Something is working.
    static let moss = Color(red: 0.561, green: 0.812, blue: 0.537)         // #8FCF89

    // MARK: Type (SF Pro Rounded — the native cousin of the prototype's Nunito)

    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    enum Size {
        static let caption: CGFloat = 10.5
        static let small: CGFloat = 11.5
        static let body: CGFloat = 12
        static let name: CGFloat = 13.5
        static let title: CGFloat = 15
    }

    // MARK: Shape

    static let cardRadius: CGFloat = 14
    static let wellRadius: CGFloat = 12
    /// The open den's outer corner. Rows inside use cardRadius, so the
    /// margin between them stays even (concentric corners).
    static let denRadius: CGFloat = 26
    static let denWidth: CGFloat = 380
    /// Cards are as wide as the den (design/v20: only as big as the
    /// information needs).
    static let cardWidth: CGFloat = 380

    // MARK: Pets in the burrow

    /// 16 sprite pixels at 1.5pt each.
    static let petSize: CGFloat = 24
    static let petCell: CGFloat = 1.5

    // MARK: Motion

    /// A pet popping its head up or ducking back down.
    static let peek = Animation.spring(response: 0.38, dampingFraction: 0.62)
    /// Rows and cards settling in.
    static let settle = Animation.spring(response: 0.42, dampingFraction: 0.86)
}

/// Capsule button in the burrow's voice. `primary` is the one filled button
/// on a card — the slot a macOS dialog keeps for its default.
struct BurrowButton: View {
    let label: String
    var hint: String? = nil
    var primary = false
    /// Lets through something that can't be undone: ember words, no fill.
    var destructive = false
    /// A side action ("收起"): no outline.
    var quiet = false
    var help: String? = nil
    let action: () -> Void

    @State private var hovering = false

    private var ink: Color { primary ? Burrow.onInk : destructive ? Burrow.ember : quiet ? Burrow.dim : Burrow.ink }

    private var edge: Color {
        if primary || quiet { return .clear }
        if destructive { return Burrow.ember.opacity(hovering ? 0.7 : 0.45) }
        return Color.white.opacity(hovering ? 0.22 : 0.14)
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(label)
                .font(Burrow.font(12, primary ? .bold : destructive ? .semibold : .medium))
            if let hint {
                Text(hint)
                    .font(Burrow.mono(9.5))
                    .opacity(0.6)
            }
        }
        .foregroundStyle(hovering && quiet ? Burrow.ink : ink)
        .padding(.horizontal, 11)
        .frame(height: 26)
        .background(
            Capsule().fill(primary ? Burrow.ink.opacity(hovering ? 1 : 0.94) : (hovering ? Burrow.hover : .clear))
        )
        .overlay(Capsule().strokeBorder(edge, lineWidth: 1))
        .contentShape(Capsule())
        .onTapGesture(perform: action)
        .onHover { hovering = $0 }
        .help(help ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { action() }
    }
}

/// A quiet underlined text action ("这个会话里都允许").
struct BurrowLink: View {
    let label: String
    var hint: String? = nil
    var help: String? = nil
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label)
                    .font(Burrow.font(12))
                    .underline(true, pattern: .dot)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let hint {
                    Text(hint).font(Burrow.mono(10)).opacity(0.6)
                }
            }
            .foregroundStyle(hovering ? Burrow.ink : Burrow.dim)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help ?? "")
    }
}

/// Small round icon button for the den's header (sound, settings, quit).
struct BurrowIconButton: View {
    let systemName: String
    var tint: Color = Burrow.dim
    var help: String = ""
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(hovering ? Burrow.ink : tint)
                .frame(width: 24, height: 24)
                .background(Circle().fill(hovering ? Burrow.hover : .clear))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

// MARK: - Hero pets

/// Shared by the rim and the den so a pet can travel between them: the one
/// peeking out of the burrow is the same one sitting in its row once the den
/// opens (and back again when it closes).
private struct BurrowNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var burrowNamespace: Namespace.ID? {
        get { self[BurrowNamespaceKey.self] }
        set { self[BurrowNamespaceKey.self] = newValue }
    }
}

private struct BurrowHero: ViewModifier {
    let id: String
    @Environment(\.burrowNamespace) private var namespace

    func body(content: Content) -> some View {
        if let namespace {
            content.matchedGeometryEffect(id: "pet-\(id)", in: namespace)
        } else {
            content
        }
    }
}

extension View {
    /// Marks the pet of session `id` so it flies between rim and den.
    func burrowHero(_ id: String) -> some View { modifier(BurrowHero(id: id)) }
}
