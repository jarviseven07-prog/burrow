import SwiftUI
import ServiceManagement
import CodeIslandCore

/// The den's back (design/v21, Jarvis picked C): Burrow's settings. The gear
/// in the den's header turns the den over; there is no settings window. Five
/// things are left to set — whether each agent is connected, the sound, opening
/// at login, the shortcuts — and the licence line MIT asks to keep.
struct BurrowDenBack: View {
    @AppStorage(SettingsKey.soundEnabled) private var soundEnabled = SettingsDefaults.soundEnabled
    @AppStorage(SettingsKey.soundVolume) private var soundVolume = SettingsDefaults.soundVolume
    @AppStorage(SettingsKey.soundSessionStart) private var soundStart = SettingsDefaults.soundSessionStart
    @AppStorage(SettingsKey.soundTaskComplete) private var soundDone = SettingsDefaults.soundTaskComplete
    @AppStorage(SettingsKey.soundTaskError) private var soundError = SettingsDefaults.soundTaskError
    @AppStorage(SettingsKey.soundApprovalNeeded) private var soundApproval = SettingsDefaults.soundApprovalNeeded
    /// The connected agent whose "connected" was clicked: it offers to
    /// reconnect or unplug instead.
    @State private var managing: String?
    /// What was last asked for, until the login item's real state (a slow
    /// system call, ~18 ms) arrives off the main thread.
    @State private var launchAtLogin = UserDefaults.standard.bool(forKey: SettingsManager.launchAtLoginWantedKey)
    @State private var connected: [String: Bool] = [:]
    @State private var recording: ShortcutAction?
    @State private var keyMonitor: Any?
    /// Bumped when a shortcut changes, so its keycaps are read again.
    @State private var shortcutsVersion = 0
    /// Fixed connection states, so a render test can show a pet unplugged;
    /// nil reads the installed hooks.
    private let shownConnections: [String: Bool]?

    init(shownConnections: [String: Bool]? = nil) {
        self.shownConnections = shownConnections
        _connected = State(initialValue: shownConnections ?? [:])
    }

    struct Agent: Hashable {
        let source: String
        let label: String
    }
    /// The agents Burrow is for, in the den's order.
    static let agents = [
        Agent(source: "claude", label: "Claude"), Agent(source: "codex", label: "Codex"),
        Agent(source: "opencode", label: "OpenCode"), Agent(source: "google-antigravity", label: "Antigravity"),
    ]
    static let shortcuts: [ShortcutAction] = [.togglePanel, .approve, .deny]

    var body: some View {
        let l10n = L10n.shared
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                ForEach(Self.agents, id: \.source) { agent in
                    agentColumn(agent.source, label: agent.label)
                        .frame(maxWidth: .infinity)
                }
            }
            .padding(.top, 4)
            .padding(.bottom, 10)

            Rectangle().fill(Burrow.line).frame(height: 1)

            VStack(spacing: 0) {
                row {
                    Text(l10n["burrow_back_sound"]).font(Burrow.font(12.5, .semibold)).foregroundStyle(Burrow.ink)
                    Button { soundEnabled.toggle() } label: {
                        Image(systemName: soundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(Burrow.dim)
                            .frame(width: 22, height: 22)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(l10n["burrow_back_mute_help"])
                    BurrowSlider(value: Binding(get: { Double(soundVolume) / 100 }, set: { soundVolume = Int(($0 * 100).rounded()) }))
                        .opacity(soundEnabled ? 1 : 0.35)
                }
                // Which moments make a sound.
                row {
                    HStack(spacing: 6) {
                        BurrowChip(text: l10n["burrow_back_sound_start"], isOn: $soundStart)
                        BurrowChip(text: l10n["burrow_back_sound_done"], isOn: $soundDone)
                        BurrowChip(text: l10n["burrow_back_sound_error"], isOn: $soundError)
                        BurrowChip(text: l10n["burrow_back_sound_approval"], isOn: $soundApproval)
                    }
                    Spacer(minLength: 0)
                }
                .opacity(soundEnabled ? 1 : 0.35)
                .disabled(!soundEnabled)
                row {
                    Text(l10n["burrow_back_login"]).font(Burrow.font(12.5, .semibold)).foregroundStyle(Burrow.ink)
                    Spacer(minLength: 0)
                    BurrowSwitch(isOn: Binding(get: { launchAtLogin }, set: { launchAtLogin = $0; SettingsManager.shared.launchAtLogin = $0 }))
                }
                row {
                    HStack(spacing: 10) {
                        ForEach(Self.shortcuts) { action in shortcut(action) }
                    }
                    Spacer(minLength: 0)
                }
                .id(shortcutsVersion)
            }
            .padding(.top, 2)

            Text("Burrow \(AppVersion.current) · \(l10n["about_based_on"])")
                .font(Burrow.font(10.5))
                .foregroundStyle(Burrow.dim.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.top, 8)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 12)
        .onAppear(perform: refresh)
        .task { launchAtLogin = await Task.detached { SMAppService.mainApp.status == .enabled }.value }
        .onDisappear(perform: stopRecording)
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) { content() }
            .frame(height: 32)
            .padding(.horizontal, 2)
    }

    // MARK: Agents

    @ViewBuilder private func agentColumn(_ source: String, label: String) -> some View {
        let on = connected[source] ?? true
        VStack(spacing: 3) {
            ZStack(alignment: .bottomTrailing) {
                MascotView(source: source, status: .idle, size: Burrow.petSize)
                    .frame(width: Burrow.petSize, height: Burrow.petSize)
                    .saturation(on ? 1 : 0.5)
                    .opacity(on ? 1 : 0.55)
                if !on {
                    BurrowUnplugged().offset(x: 14, y: -1)
                }
            }
            .frame(width: 30, height: 30)
            BurrowAgentName(source: source, label: label)
                .saturation(on ? 1 : 0)
                .opacity(on ? 1 : 0.6)
            if on, managing == source {
                HStack(spacing: 4) {
                    smallButton(L10n.shared["burrow_back_reconnect"], tint: Burrow.ink) { connect(source) }
                    smallButton(L10n.shared["burrow_back_disconnect"], tint: Burrow.ember) { disconnect(source) }
                }
                .frame(height: 18)
            } else if on {
                Button { withAnimation(Burrow.settle) { managing = source } } label: {
                    HStack(spacing: 4) {
                        Circle().fill(Burrow.moss).frame(width: 5, height: 5)
                        Text(L10n.shared["burrow_back_connected"])
                            .font(Burrow.font(10.5, .semibold))
                            .foregroundStyle(Burrow.moss)
                    }
                    .frame(height: 18)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(L10n.shared["burrow_back_manage_help"])
            } else {
                Button { connect(source) } label: {
                    Text(L10n.shared["burrow_back_connect"])
                        .font(Burrow.font(10.5, .bold))
                        .foregroundStyle(Burrow.onInk)
                        .padding(.horizontal, 9)
                        .frame(height: 18)
                        .background(Capsule().fill(Burrow.ink))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func refresh() {
        guard shownConnections == nil else { return }
        for agent in Self.agents {
            connected[agent.source] = ConfigInstaller.isInstalled(source: agent.source)
        }
    }

    /// Connecting is installing the agent's hooks; done again, it repairs them.
    private func connect(_ source: String) {
        ConfigInstaller.setEnabled(source: source, enabled: true)
        withAnimation(Burrow.settle) {
            managing = nil
            connected[source] = ConfigInstaller.isInstalled(source: source)
        }
    }

    /// Unplugging takes the agent's hooks out: Burrow stops seeing it.
    private func disconnect(_ source: String) {
        ConfigInstaller.setEnabled(source: source, enabled: false)
        withAnimation(Burrow.settle) {
            managing = nil
            connected[source] = ConfigInstaller.isInstalled(source: source)
        }
    }

    private func smallButton(_ text: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(text)
                .font(Burrow.font(10.5, .bold))
                .foregroundStyle(tint)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.18)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: Shortcuts

    @ViewBuilder private func shortcut(_ action: ShortcutAction) -> some View {
        let l10n = L10n.shared
        Button { recording == action ? stopRecording() : startRecording(action) } label: {
            HStack(spacing: 4) {
                Text(l10n["burrow_back_shortcut_\(action.rawValue)"])
                    .font(Burrow.font(11.5))
                    .foregroundStyle(Burrow.dim)
                if recording == action {
                    keycap(l10n["burrow_back_shortcut_press"], live: true)
                } else if action.isEnabled {
                    HStack(spacing: 2) {
                        ForEach(Array(action.binding.displayString.map(String.init).enumerated()), id: \.offset) { keycap($0.element) }
                    }
                } else {
                    keycap(l10n["burrow_back_shortcut_none"])
                }
            }
        }
        .buttonStyle(.plain)
        .help(l10n["burrow_back_shortcut_help"])
    }

    private func keycap(_ text: String, live: Bool = false) -> some View {
        Text(text)
            .font(Burrow.font(10.5, .semibold))
            .foregroundStyle(live ? Burrow.ink : (text.count > 1 ? Burrow.dim : Burrow.ink))
            .padding(.horizontal, 4)
            .frame(minWidth: 18, minHeight: 18)
            .background(RoundedRectangle(cornerRadius: 5).fill(Burrow.well))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(live ? Burrow.ink.opacity(0.6) : Burrow.wellEdge))
    }

    private func startRecording(_ action: ShortcutAction) {
        stopRecording()
        recording = action
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 { // Escape — cancel
                stopRecording()
                return nil
            }
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard mods.contains(.command) || mods.contains(.control) || mods.contains(.option) else { return nil }
            action.setBinding(keyCode: event.keyCode, modifiers: mods)
            if !action.isEnabled { action.setEnabled(true) }
            stopRecording()
            shortcutsVersion += 1
            (NSApp.delegate as? AppDelegate)?.setupGlobalShortcut()
            return nil
        }
    }

    private func stopRecording() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        recording = nil
    }
}

/// A small on/off word: filled warm white when on, an outline when off.
struct BurrowChip: View {
    let text: String
    @Binding var isOn: Bool

    var body: some View {
        Button { withAnimation(Burrow.settle) { isOn.toggle() } } label: {
            Text(text)
                .font(Burrow.font(11, .semibold))
                .foregroundStyle(isOn ? Burrow.onInk : Burrow.dim)
                .padding(.horizontal, 9)
                .frame(height: 20)
                .background(Capsule().fill(isOn ? Burrow.ink : Color.clear))
                .overlay(Capsule().strokeBorder(isOn ? Burrow.ink : Color.white.opacity(0.18)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// On/off in the burrow's voice: warm white when on, like a card's one filled
/// button — not amber, which in Burrow means "needs you".
struct BurrowSwitch: View {
    @Binding var isOn: Bool

    var body: some View {
        Button { withAnimation(Burrow.settle) { isOn.toggle() } } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? Burrow.ink : Burrow.well)
                    .overlay(Capsule().strokeBorder(isOn ? Burrow.ink : Burrow.wellEdge))
                Circle().fill(isOn ? Burrow.onInk : Burrow.dim)
                    .frame(width: 12, height: 12)
                    .padding(3)
            }
            .frame(width: 30, height: 18)
        }
        .buttonStyle(.plain)
    }
}

/// A thin line with a warm white knob; 0…1.
struct BurrowSlider: View {
    @Binding var value: Double

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let x = CGFloat(min(max(value, 0), 1)) * w
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.12)).frame(height: 2)
                Capsule().fill(Burrow.ink).frame(width: x, height: 2)
                Circle().fill(Burrow.ink).frame(width: 12, height: 12).offset(x: x - 6)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                value = Double(min(max(g.location.x / max(w, 1), 0), 1))
            })
        }
        .frame(height: 18)
    }
}

/// A plug pulled out, lying on the floor beside a pet that is not connected.
struct BurrowUnplugged: View {
    private static let rows = ["...bbbpp", "cccbbb..", "...bbbpp"]
    private static let colors: [Character: Color] = [
        "b": Color(red: 0.541, green: 0.518, blue: 0.486),
        "p": Color(red: 0.788, green: 0.765, blue: 0.729),
        "c": Color(red: 0.290, green: 0.275, blue: 0.259),
    ]

    var body: some View {
        Canvas { ctx, _ in
            let cell = Burrow.petCell
            for (j, row) in Self.rows.enumerated() {
                for (i, ch) in row.enumerated() {
                    guard let color = Self.colors[ch] else { continue }
                    ctx.fill(Path(CGRect(x: CGFloat(i) * cell, y: CGFloat(j) * cell, width: cell, height: cell)), with: .color(color))
                }
            }
        }
        .frame(width: 8 * Burrow.petCell, height: 3 * Burrow.petCell)
    }
}

/// Turning the den over: one continuous half turn. The face changes at the
/// edge-on moment, and the island's height follows the new face from there,
/// so nothing grows before the turn and no empty frame sits between faces
/// (the first version turned one face out, waited, then turned the other in).
enum BurrowFlip {
    static let animation = Animation.easeInOut(duration: 0.42)
}

struct BurrowFlipCard<Front: View, Back: View>: View, Animatable {
    /// 0 shows the front, 180 the back.
    var angle: Double
    let front: Front
    let back: Back

    var animatableData: Double {
        get { angle }
        set { angle = newValue }
    }

    var body: some View {
        // Both faces are there while the card turns: the hidden one is built
        // as the turn starts, not edge-on (building the back took ~50 ms, and
        // the turn froze there, then jumped).
        FlipFaces(showing: angle < 90 ? 0 : 1) {
            if angle < 180 {
                front.opacity(angle < 90 ? 1 : 0)
            }
            if angle > 0 {
                // Turned once more, so the back reads the right way round.
                back.rotation3DEffect(.degrees(180), axis: (x: 0, y: 1, z: 0))
                    .opacity(angle < 90 ? 0 : 1)
            }
        }
        .rotation3DEffect(.degrees(angle), axis: (x: 0, y: 1, z: 0), perspective: 0.4)
    }
}

/// Lays the faces over each other at the top; the card is the size of the
/// face showing, so a taller hidden back never grows the island.
private struct FlipFaces: Layout {
    /// The face showing, when both are there.
    var showing: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard !subviews.isEmpty else { return .zero }
        return subviews[min(showing, subviews.count - 1)].sizeThatFits(proposal)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for face in subviews {
            face.place(at: bounds.origin, anchor: .topLeading,
                       proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}
